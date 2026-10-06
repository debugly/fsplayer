package com.debugly.fsplayer.demo;

import android.app.Activity;
import android.graphics.Bitmap;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.widget.Toast;

import java.io.File;
import java.io.FileOutputStream;

import tv.danmaku.ijk.media.player.IMediaPlayer;
import tv.danmaku.ijk.media.player.IjkMediaPlayer;

public class MainActivity extends Activity implements SurfaceHolder.Callback {

    private IjkMediaPlayer mPlayer;
    private SurfaceView mSurfaceView;
    private String mSubtitlePath;
    private int mSnapshotType = -1;
    private int mSnapshotDelayMs = 4000;
    private String mBackgroundPath;
    private int mBlurIterations = IjkMediaPlayer.FS_BACKGROUND_BLUR_ITERATIONS;
    private float mBrightness;
    private float mSaturation;
    private float mContrast;
    private int mBgColor;
    private float mBlurSigma = IjkMediaPlayer.FS_BACKGROUND_BLUR_SIGMA;

    // H264 + AAC MP4，软解可播放（W3C 长期托管）
    // 可用 intent extra "url" 覆盖（本地文件或网络地址）
    // 可用 intent extra "subtitle" 挂一个外挂字幕（SRT/ASS）
    // 可用 intent extra "scaleMode" 指定缩放模式 0 等比完整显示(默认) 1 等比铺满 2 拉伸
    // 可用 intent extra "snapshotType" 在起播若干秒后截一张快照到 files/snapshot-<type>.png
    //   0 原始尺寸 1 屏幕所见(默认) 2 原始尺寸+字幕 3 原始尺寸+字幕+效果
    // 可用 intent extra "snapshotDelayMs" 改截屏延时（默认 4000）
    // 可用 intent extra "pauseAfterMs" 指定起播后多少毫秒暂停（用来验证暂停时也能截屏）
    // 可用 intent extra "background" 指定一张图（设备路径），用它的高斯模糊填充黑边
    // 可用 intent extra "blurIterations" / "blurSigma"（float）调模糊参数（默认 3 / 30）
    // 可用 intent extra "brightness" / "saturation" / "contrast"（float）调色彩（默认 1.0 / 1.0 / 1.0）
    // 可用 intent extra "bgColor"（int，0xRRGGBB 的十进制）设黑边背景色（默认黑）
    private static final String TEST_URL =
            "https://media.w3.org/2010/05/sintel/trailer.mp4";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        mSurfaceView = new SurfaceView(this);
        mSurfaceView.getHolder().addCallback(this);
        setContentView(mSurfaceView);

        mSubtitlePath = getIntent() != null ? getIntent().getStringExtra("subtitle") : null;
        mSnapshotType = getIntent() != null ? getIntent().getIntExtra("snapshotType", -1) : -1;
        mSnapshotDelayMs = getIntent() != null ? getIntent().getIntExtra("snapshotDelayMs", 4000) : 4000;
        int pauseAfterMs = getIntent() != null ? getIntent().getIntExtra("pauseAfterMs", -1) : -1;
        mBackgroundPath = getIntent() != null ? getIntent().getStringExtra("background") : null;
        mBlurIterations = getIntent() != null
                ? getIntent().getIntExtra("blurIterations", IjkMediaPlayer.FS_BACKGROUND_BLUR_ITERATIONS)
                : IjkMediaPlayer.FS_BACKGROUND_BLUR_ITERATIONS;
        mBlurSigma = getIntent() != null
                ? getIntent().getFloatExtra("blurSigma", IjkMediaPlayer.FS_BACKGROUND_BLUR_SIGMA)
                : IjkMediaPlayer.FS_BACKGROUND_BLUR_SIGMA;
        mBrightness = getIntent() != null
                ? getIntent().getFloatExtra("brightness", IjkMediaPlayer.FS_COLOR_DEFAULT)
                : IjkMediaPlayer.FS_COLOR_DEFAULT;
        mSaturation = getIntent() != null
                ? getIntent().getFloatExtra("saturation", IjkMediaPlayer.FS_COLOR_DEFAULT)
                : IjkMediaPlayer.FS_COLOR_DEFAULT;
        mContrast = getIntent() != null
                ? getIntent().getFloatExtra("contrast", IjkMediaPlayer.FS_COLOR_DEFAULT)
                : IjkMediaPlayer.FS_COLOR_DEFAULT;
        mBgColor = getIntent() != null ? getIntent().getIntExtra("bgColor", 0) : 0;

        mPlayer = new IjkMediaPlayer();
        // MediaCodec 硬解 + Vulkan 外部显存零拷贝（设备不支持时自动回退软解）
        // 可用 intent extra "mediacodec" 传 0 强制走软解（排查硬解通路用）
        int useMediaCodec = getIntent() != null ? getIntent().getIntExtra("mediacodec", 1) : 1;
        if (useMediaCodec != 0) {
            mPlayer.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 1);
        }
        // 画面缩放模式（和 iOS 的 player.scalingMode 对齐）
        int scaleMode = getIntent() != null
                ? getIntent().getIntExtra("scaleMode", IjkMediaPlayer.FS_SCALING_MODE_ASPECT_FIT)
                : IjkMediaPlayer.FS_SCALING_MODE_ASPECT_FIT;
        mPlayer.setScalingMode(scaleMode);
        mPlayer.setOnPreparedListener(new IMediaPlayer.OnPreparedListener() {
            @Override
            public void onPrepared(IMediaPlayer mp) {
                mp.start();
                // 外挂字幕要在流打开之后挂（native 侧需要 is 已经建立）
                Toast.makeText(MainActivity.this,
                        "scaleMode=" + mPlayer.getScalingMode(), Toast.LENGTH_SHORT).show();
                if (mSubtitlePath != null && !mSubtitlePath.isEmpty()) {
                    boolean ok = mPlayer.loadThenActiveSubtitle(mSubtitlePath);
                    Toast.makeText(MainActivity.this,
                            "loadThenActiveSubtitle(" + mSubtitlePath + ") = " + ok,
                            Toast.LENGTH_LONG).show();
                }
                if (mBackgroundPath != null && !mBackgroundPath.isEmpty()) {
                    Bitmap bg = android.graphics.BitmapFactory.decodeFile(mBackgroundPath);
                    if (bg == null) {
                        toast("背景图解码失败: " + mBackgroundPath);
                    } else {
                        mPlayer.setBackgroundBlurIterations(mBlurIterations);
                        mPlayer.setBackgroundBlurSigma(mBlurSigma);
                        mPlayer.setBackgroundImage(bg);
                        toast("背景 " + bg.getWidth() + "x" + bg.getHeight()
                                + " iterations=" + mPlayer.getBackgroundBlurIterations()
                                + " sigma=" + mPlayer.getBackgroundBlurSigma());
                    }
                }
                mPlayer.setBackgroundColor(mBgColor);
                mPlayer.setColorPreference(mBrightness, mSaturation, mContrast);
                if (mBgColor != 0 || mBrightness != 1.0f || mSaturation != 1.0f || mContrast != 1.0f) {
                    toast("color b=" + mPlayer.getColorBrightness()
                            + " s=" + mPlayer.getColorSaturation()
                            + " c=" + mPlayer.getColorContrast()
                            + " bg=" + Integer.toHexString(mPlayer.getBackgroundColor()));
                }
                if (pauseAfterMs >= 0) {
                    new Handler(Looper.getMainLooper()).postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            mPlayer.pause();
                        }
                    }, pauseAfterMs);
                }
                if (mSnapshotType >= 0) {
                    new Handler(Looper.getMainLooper()).postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            // 取快照会阻塞等渲染线程，别放在主线程上
                            new Thread(new Runnable() {
                                @Override
                                public void run() {
                                    saveSnapshot(mSnapshotType);
                                }
                            }).start();
                        }
                    }, mSnapshotDelayMs);
                }
            }
        });
        mPlayer.setOnErrorListener(new IMediaPlayer.OnErrorListener() {
            @Override
            public boolean onError(IMediaPlayer mp, int what, int extra) {
                Toast.makeText(MainActivity.this,
                        "播放出错 what=" + what + " extra=" + extra, Toast.LENGTH_LONG).show();
                return false;
            }
        });
    }

    private void saveSnapshot(int type) {
        final Bitmap bitmap = mPlayer.getSnapshot(type);
        if (bitmap == null) {
            toast("snapshot(" + type + ") 失败");
            return;
        }
        File out = new File(getFilesDir(), "snapshot-" + type + ".png");
        try {
            FileOutputStream fos = new FileOutputStream(out);
            try {
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, fos);
            } finally {
                fos.close();
            }
        } catch (Exception e) {
            toast("写快照失败: " + e.getMessage());
            return;
        }
        toast("snapshot " + bitmap.getWidth() + "x" + bitmap.getHeight() + " -> " + out.getPath());
    }

    private void toast(final String message) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                Toast.makeText(MainActivity.this, message, Toast.LENGTH_LONG).show();
            }
        });
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        try {
            String url = getIntent() != null ? getIntent().getStringExtra("url") : null;
            if (url == null || url.isEmpty())
                url = TEST_URL;
            mPlayer.setSurface(holder.getSurface());
            mPlayer.setDataSource(url);
            mPlayer.prepareAsync();
        } catch (Exception e) {
            Toast.makeText(this, "setDataSource 失败: " + e.getMessage(), Toast.LENGTH_LONG).show();
        }
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        mPlayer.setSurface(null);
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (mPlayer != null) {
            mPlayer.release();
            mPlayer = null;
        }
    }
}
