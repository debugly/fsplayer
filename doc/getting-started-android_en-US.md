[简体中文](getting-started-android.md) · **English**

# Getting started on Android

The FSPlayer Android SDK is distributed as an AAR and supports Android 5.0 (API 21) and later. Release AARs include `arm64-v8a` and `armeabi-v7a`. Build from source if you need a different ABI. [Android build instructions](CONTRIBUTING_en-US.md#android-aar-and-aura-apk)

## Add the SDK

Make sure your dependency repositories include `mavenCentral()`, then add FSPlayer to your app module's `build.gradle`. This example uses `1.1.2`. The rendering options below describe the current source tree. Check the release notes for API availability in the version you use. [GitHub Releases](https://github.com/debugly/fsplayer/releases)

```groovy
dependencies {
    implementation 'io.github.debugly:fsplayer:1.1.2'
}
```

You can also download `fsplayer-<version>.aar` from the release page, place it in your app module's `libs/` directory, and add it with `implementation files('libs/fsplayer-<version>.aar')`. AARs built from the current source include the consumer keep rules required by JNI. R8 applies those rules automatically in the consuming app.

To play media over the network, add the internet permission to your app's `AndroidManifest.xml`.

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

## Play a video

The example creates a player when the `SurfaceView` is ready and starts playback in the `onPrepared` callback. Add the code to your Activity and call `bindPlayer(surfaceView)` after creating the `SurfaceView`.

```java
import android.util.Log;
import android.view.SurfaceHolder;
import android.view.SurfaceView;

import com.debugly.fsplayer.player.FSPlayer;

import java.io.IOException;

private FSPlayer player;

private void bindPlayer(SurfaceView surfaceView) {
    surfaceView.getHolder().addCallback(new SurfaceHolder.Callback() {
        @Override
        public void surfaceCreated(SurfaceHolder holder) {
            releasePlayer();
            FSPlayer current = new FSPlayer();
            player = current;
            current.setDisplay(holder);
            current.setOption(FSPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 1);
            current.setOnPreparedListener(mp -> mp.start());
            current.setOnErrorListener((mp, what, extra) -> {
                Log.e("Playback", "Playback error " + what + "/" + extra);
                return true;
            });

            try {
                // Replace with your media URL.
                current.setDataSource("https://example.com/video.mp4");
                current.prepareAsync();
            } catch (IOException | IllegalStateException e) {
                Log.e("Playback", "Could not prepare media", e);
                releasePlayer();
            }
        }

        @Override
        public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {}

        @Override
        public void surfaceDestroyed(SurfaceHolder holder) {
            releasePlayer();
        }
    });
}

private void releasePlayer() {
    if (player != null) {
        player.release();
        player = null;
    }
}
```

- To play a `content://` URI returned by the system file picker, call `setDataSource(context, uri)` and make sure the app has read access to the URI.
- If you use a `TextureView`, call `setSurface(surface)` once you have a `Surface`. The app manages that surface's lifecycle.
- This example releases the player when the surface is destroyed. You can also call `releasePlayer()` when the Activity exits. To keep playback running after surface destruction, detach the display with `setDisplay(null)` or `setSurface(null)` and bind the new surface when it is ready.
- To reuse the player for another media source, call `reset()`, reapply the options, set the data source and display target, then call `prepareAsync()` again.

## Rendering and hardware decoding

Set the renderer before calling `prepareAsync()`. The default is `auto`.

```java
player.setOption(FSPlayer.OPT_CATEGORY_PLAYER, "video-renderer", "auto");
```

| Value | Behavior |
| --- | --- |
| `auto` | Tries Vulkan first on API 24 and later. Falls back to OpenGL ES 3 if Vulkan initialization fails or AHardwareBuffer (AHB) support is unavailable. Uses OpenGL ES 3 on API 21–23. |
| `opengl` | Uses OpenGL ES 3. |
| `vulkan` | Prefers Vulkan and falls back to OpenGL ES 3 if initialization fails. Vulkan may still render software-decoded frames on devices without AHB support. |

Set `mediacodec=1` to allow MediaCodec decoding. After preparation, check `getVideoDecoder() == FSPlayer.FFP_PROPV_DECODER_MEDIACODEC` to see whether MediaCodec is in use. To see the active rendering backend, create an `FSHudView` in your app, pass it to `attachHudView(hudView)`, and call `setShouldShowHudView(true)`. [Rendering and fallback](../ijkmedia/ijksdl/android/gles3/README.md)

Calling `setAllowHDRDirectDisplay(true)` permits direct HDR output. The current 8-bit Android render targets still tone-map HDR content to SDR.

## Common playback APIs

| Task | API |
| --- | --- |
| Start, pause, or stop | `start()`, `pause()`, `stop()` |
| Seek or read playback time | `seekTo(ms)`, `getCurrentPosition()`, and `getDuration()` use milliseconds. |
| Loop, change playback speed, or adjust volume | `setLooping(true)`, `setSpeed(1.5f)`, `setVolume(0.5f, 0.5f)` |
| Check buffering | Use `setOnBufferingUpdateListener` for percentage updates or `getPlayableDuration()` for the position you can play up to, in milliseconds. |
| Read download speed | `getTcpSpeed()` returns bytes per second. |
| Advance one frame | Call `stepToNextFrame()` while paused. |
| Select an audio or subtitle track | List tracks with `getTrackInfo()`, then call `selectTrack(index)` or `deselectTrack(index)`. |

## Subtitles and synchronization

After preparation, call `loadThenActiveSubtitle(path)` to load and activate an external subtitle, or `addOnlyExternalSubtitle(path)` to add it without activating it. The latter returns `0` when it adds the subtitle and `1` when the subtitle was already added. Set the style with `setSubtitlePreference(preference)`, or pass `null` to restore the defaults.

Use `setAudioExtraDelay(seconds)` and `setSubtitleExtraDelay(seconds)` to adjust audio and subtitle timing. Both values are in seconds.

## Picture controls, backgrounds, and screenshots

```java
// Fit while preserving the aspect ratio. Also available are
// FS_SCALING_MODE_ASPECT_FILL and FS_SCALING_MODE_FILL.
player.setScalingMode(FSPlayer.FS_SCALING_MODE_ASPECT_FIT);
player.setRotateDegrees(0.0f, 0.0f, 90.0f);

// Brightness, saturation, and contrast. 1.0f keeps the original value.
player.setColorPreference(1.0f, 1.0f, 1.0f);
player.setBackgroundColor(24, 32, 48);
```

The background color fills the space outside the video. RGB components range from 0 to 255. Call `setBackgroundImage(bitmap)` to fill that space with a Gaussian-blurred image supplied by your app. Pass `null` to clear the image. Adjust the blur with `setBackgroundBlurIterations(3)` and `setBackgroundBlurSigma(30.0f)`.

Call `getSnapshot()` on a worker thread to capture the current picture. This method waits for the rendering thread and returns `null` if it cannot capture a frame. The MediaCodec zero-copy path may be unable to capture the last frame while playback is paused.

## Sample app and source builds

The Aura Android sample shows the playback UI, surface lifecycle, renderer selection, and picture-in-picture integration. The host Activity manages picture-in-picture through Android's system APIs. [Aura Android sample](../examples/android) · [Build instructions](CONTRIBUTING_en-US.md#android-aar-and-aura-apk)
