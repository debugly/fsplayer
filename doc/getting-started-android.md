**简体中文** · [English](getting-started-android_en-US.md)

# Android 快速入门

FSPlayer Android SDK 以 AAR 分发，最低支持 Android 5.0（API 21）。正式发布的 AAR 包含 `arm64-v8a` 和 `armeabi-v7a`。如果要用其他 ABI，请从源码构建。 [Android 构建说明](../CONTRIBUTING.md)

## 接入 SDK

确保依赖仓库包含 `mavenCentral()`，然后在应用模块的 `build.gradle` 中添加依赖。这里以 `1.1.2` 为例。后文的渲染选项以当前源码为准，请根据所用版本的发布说明确认接口是否可用。 [GitHub Releases](https://github.com/debugly/fsplayer/releases)

```groovy
dependencies {
    implementation 'io.github.debugly:fsplayer:1.1.2'
}
```

也可以从发布页下载 `fsplayer-<版本>.aar`，放入应用模块的 `libs/`，然后使用 `implementation files('libs/fsplayer-<版本>.aar')`。当前源码构建的 AAR 包含 JNI 所需的 consumer keep 规则，接入方启用 R8 时会自动应用。

播放网络媒体时，在应用的 `AndroidManifest.xml` 中声明网络权限：

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

## 播放视频

以下示例在 `SurfaceView` 就绪后创建播放器，在 `onPrepared` 回调中开始播放。将代码放入 Activity，创建好 `SurfaceView` 后调用 `bindPlayer(surfaceView)`。

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
                // 换成实际播放地址。
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

- 播放系统文件选择器返回的 `content://` URI 时，使用 `setDataSource(context, uri)`，并确保应用有权读取该 URI。
- 如果使用 `TextureView`，可在获得 `Surface` 后调用 `setSurface(surface)`，由应用管理该 `Surface` 的生命周期。
- 上面的示例随画面销毁释放播放器。宿主退出时也可调用 `releasePlayer()` 兜底。如果业务要在画面销毁后保留播放，用 `setDisplay(null)` 或 `setSurface(null)` 解绑，等新画面就绪后重新绑定。
- 复用实例切换媒体时，调用 `reset()` 后重新设置选项、数据源和显示目标，再调用 `prepareAsync()`。

## 渲染和硬解

在 `prepareAsync()` 之前设置渲染模式。默认使用 `auto`：

```java
player.setOption(FSPlayer.OPT_CATEGORY_PLAYER, "video-renderer", "auto");
```

| 值 | 行为 |
| --- | --- |
| `auto` | API 24 及以上优先尝试 Vulkan。Vulkan 初始化失败或缺少 AHardwareBuffer（AHB）时回退到 OpenGL ES 3。API 21–23 使用 OpenGL ES 3。 |
| `opengl` | 直接使用 OpenGL ES 3。 |
| `vulkan` | 显式优先使用 Vulkan，初始化失败时回退到 OpenGL ES 3。缺少 AHB 时，Vulkan 仍可能播放软解画面。 |

设置 `mediacodec=1` 表示允许 MediaCodec 解码。准备完成后，可用 `getVideoDecoder() == FSPlayer.FFP_PROPV_DECODER_MEDIACODEC` 检查当前是否使用 MediaCodec。渲染后端和解码器可以分别查看。将应用创建的 `FSHudView` 传给 `attachHudView(hudView)`，再调用 `setShouldShowHudView(true)`，即可在调试视图中查看实际渲染后端。 [渲染与回退说明](../ijkmedia/ijksdl/android/gles3/README.md)

`setAllowHDRDirectDisplay(true)` 表示允许 HDR 直出。当前 Android 的 8 位渲染目标仍会将 HDR 内容映射到 SDR。

## 常用播放接口

| 操作 | 接口 |
| --- | --- |
| 播放、暂停、停止 | `start()`、`pause()`、`stop()` |
| 跳转和查询时间 | `seekTo(ms)`、`getCurrentPosition()`、`getDuration()`，单位均为毫秒 |
| 循环、倍速和音量 | `setLooping(true)`、`setSpeed(1.5f)`、`setVolume(0.5f, 0.5f)` |
| 缓冲 | 用 `setOnBufferingUpdateListener` 接收进度百分比，或用 `getPlayableDuration()` 查询可播放到的位置（毫秒） |
| 下载速度 | `getTcpSpeed()`，单位为字节每秒 |
| 逐帧播放 | 暂停时调用 `stepToNextFrame()` |
| 选择音轨或字幕轨 | 用 `getTrackInfo()` 获取轨道列表，再用 `selectTrack(index)` 或 `deselectTrack(index)` 切换 |

## 字幕和音画同步

准备完成后，可用 `loadThenActiveSubtitle(path)` 加载并激活外挂字幕，也可用 `addOnlyExternalSubtitle(path)` 仅添加字幕。后者返回 `0` 表示添加成功，`1` 表示已添加过。用 `setSubtitlePreference(preference)` 设置字幕样式，传 `null` 可恢复默认样式。

通过 `setAudioExtraDelay(seconds)` 和 `setSubtitleExtraDelay(seconds)` 分别调整音频和字幕延迟，单位均为秒。

## 画面、背景和截图

```java
// 等比适配，可换成 FS_SCALING_MODE_ASPECT_FILL 或 FS_SCALING_MODE_FILL。
player.setScalingMode(FSPlayer.FS_SCALING_MODE_ASPECT_FIT);
player.setRotateDegrees(0.0f, 0.0f, 90.0f);

// 依次为亮度、饱和度和对比度，1.0f 为原值。
player.setColorPreference(1.0f, 1.0f, 1.0f);
player.setBackgroundColor(24, 32, 48);
```

背景色用于画面留边，RGB 分量范围为 0–255。可调用 `setBackgroundImage(bitmap)` 用应用提供的图片生成高斯模糊背景，传入 `null` 可清除。模糊参数可用 `setBackgroundBlurIterations(3)` 和 `setBackgroundBlurSigma(30.0f)` 调整。

在工作线程调用 `getSnapshot()` 可截取当前显示画面。此方法会等待渲染线程，取帧失败时返回 `null`。MediaCodec 零拷贝路径在暂停时可能无法取到最后一帧。

## 示例和源码构建

[Aura Android 示例](../examples/android) 包含播放界面、Surface 生命周期、渲染器切换和画中画接入。画中画由宿主 Activity 通过 Android 系统接口管理。 [构建步骤](../CONTRIBUTING.md#android-aar-与-aura-apk)
