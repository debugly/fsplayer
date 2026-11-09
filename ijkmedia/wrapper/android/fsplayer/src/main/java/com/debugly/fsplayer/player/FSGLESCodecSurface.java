/* SPDX-License-Identifier: LGPL-2.1-or-later */
package com.debugly.fsplayer.player;

import android.graphics.SurfaceTexture;
import android.os.Handler;
import android.os.HandlerThread;
import android.view.Surface;

/** Internal JNI implementation. Not a player API; keep its JNI names in shrinkers. */
final class FSGLESCodecSurface {
    private final Object lock = new Object();
    private final HandlerThread callbacks;
    private final SurfaceTexture texture;
    private final Surface surface;
    private long available;
    private long consumed;
    private boolean closed;

    // Must be constructed with the owning GLES context current.
    FSGLESCodecSurface(int textureName) {
        HandlerThread thread = new HandlerThread("FSGLES-frame");
        thread.start();
        SurfaceTexture st = null;
        Surface output = null;
        try {
            st = new SurfaceTexture(textureName);
            st.setOnFrameAvailableListener(ignored -> {
                synchronized (lock) {
                    if (!closed) {
                        available++;
                        lock.notifyAll();
                    }
                }
            }, new Handler(thread.getLooper()));
            output = new Surface(st);
        } catch (RuntimeException | Error error) {
            if (output != null) output.release();
            if (st != null) st.release();
            thread.quitSafely();
            throw error;
        }
        callbacks = thread;
        texture = st;
        surface = output;
    }

    Surface getSurface() {
        return surface;
    }

    // Only the serialized native EGL owner calls this. Callback thread never touches GL.
    boolean latch(float[] matrix, int timeoutMs) {
        if (matrix == null || matrix.length != 16 || timeoutMs < 0) return false;
        final long deadline = System.nanoTime() + timeoutMs * 1000000L;
        synchronized (lock) {
            while (!closed && consumed == available) {
                long left = deadline - System.nanoTime();
                if (left <= 0) return false;
                try {
                    lock.wait(left / 1000000L, (int) (left % 1000000L));
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    return false;
                }
            }
            if (closed) return false;
            consumed = available;
        }
        texture.updateTexImage();
        texture.getTransformMatrix(matrix);
        return true;
    }

    // Called after decoder/render producers are stopped, with EGL serialized by native mutex.
    void release() {
        synchronized (lock) {
            if (closed) return;
            closed = true;
            lock.notifyAll();
        }
        try {
            texture.setOnFrameAvailableListener(null, null);
        } finally {
            try {
                surface.release();
            } finally {
                try {
                    texture.release();
                } finally {
                    callbacks.quitSafely();
                }
            }
        }
    }
}
