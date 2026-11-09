**简体中文** · [English](README.md)

<div align="center">

<img src="./doc/banner.jpg" width="320" alt="FSPlayer">

[Apple端使用文档](doc/getting-started-apple.md) · [安卓端使用文档](doc/getting-started-android.md) · [更新日志](CHANGELOG.md) · [反馈问题](https://github.com/debugly/fsplayer/issues)

</div>

## 为什么选择 FSPlayer

FSPlayer 在 [ijkplayer](https://github.com/bilibili/ijkplayer) 基础上做了很多优化，功能丰富强劲，原生支持ASS特效字幕绘制、4K、HDR、画中画等特性。重写硬件解码逻辑，封装了新一代渲染后端引擎。

LGPL 协议开源，更新活跃，永久免费使用。

## 功能特点


| 功能      | 支持内容                                                                            |
| ------- | ------------------------------------------------------------------------------- |
｜ FFmpeg ｜ 基于 FFmpeg 8.1.2，开启硬件加速，后续会持续升级。｜
｜渲染后端 ｜ Apple 平台使用 Metal，Android 优先使用 Vulkan，不可用时回退到 OpenGL ES 3｜
| 解码与渲染   | 支持 4K、HDR、AV1 和 AVS3，硬解及 HDR 输出取决于平台和设备。支持软硬解切换、视频滤镜、软解反交错和透明视频。                |
| 字幕与音轨   | 支持内嵌和外挂字幕，包括 SRT、WebVTT、ASS 及 PGS 等图形字幕。可调整字幕样式、字幕延迟和音轨延迟。                      |
| 本地与网络播放 | 支持本地文件、HTTP(S)、HLS 直播与点播，以及 RTSP、RTMP、SMB 等协议。可播放网络上的 Blu-ray ISO 镜像与 BDMV 文件夹。 |
| 播放控制    | 支持精准跳转、循环播放、倍速和多实例播放。可获取下载速度、缓冲进度及首帧解码和渲染耗时。                                    |
| 画面与输出   | 支持缩放、旋转、镜像、亮度和对比度调整，以及截帧、录制和实时 PCM 输出。部分接口因平台而异。                                |

## 应用场景

- **本地媒体库和 NAS 播放器**，播放 SMB 上的影片、Blu-ray ISO 和 BDMV，切换音轨并加载外挂字幕。
- **直播与点播应用**，播放 HLS 或 RTSP 流，可按业务需要设置 HTTP 请求头、超时时间。
- **自定义播放界面**，将画面接入宿主视图，按平台实现画中画、视频滤镜和截图。

## 快速开始

### 通过 Aura 体验 FSPlayer

Aura 是基于 FSPlayer 的示例播放器。提供 macOS 和 安卓端安装包，

- [Andorid 端 apk](https://github.com/debugly/fsplayer/releases?q=Aura+Android&expanded=true)
- [macOS 端 app](https://github.com/debugly/fsplayer/releases?q=Aura+macOS&expanded=true)
- [macOS 端通过 brew 安装](https://github.com/debugly/homebrew-aura)

### 接入示例

### Apple（Objective-C）

下面以 macOS 为例：

```objc
#import <FSPlayer/FSPlayer.h>

FSOptions *options = [FSOptions optionsByDefault];
self.player = [[FSPlayer alloc] initWithContent:url options:options];

NSView<FSVideoRenderingProtocol> *playerView = self.player.view;
playerView.frame = self.playerContainer.bounds;
playerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
[self.playerContainer addSubview:playerView];

self.player.shouldAutoplay = YES;
[self.player prepareToPlay];
```

### Android（Java）

在 `SurfaceView` 的 surface 就绪后，设置播放地址并异步准备：

```java
FSPlayer player = new FSPlayer();
player.setOption(FSPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 1);
player.setDisplay(surfaceView.getHolder());
player.setDataSource(context, uri);
player.setOnPreparedListener(mp -> mp.start());
player.prepareAsync();
```

- [iOS/macOS/tvOS端完整接入文档](doc/getting-started-apple.md)
- [安卓端完整接入文档](doc/getting-started-android.md)

### 平台与架构

| 平台      | 源码配置的最低版本                                                              | 架构                                |
| ------- | ---------------------------------------------------------------------- | --------------------------------- |
| iOS     | iOS 12，使用 Xcode 27 配置时为 iOS 15                                         | 真机 arm64，模拟器 arm64 / x86\_64      |
| macOS   | Intel 为 macOS 10.14，Apple Silicon 为 macOS 11，使用 Xcode 27 配置时为 macOS 12 | arm64 / x86\_64                   |
| tvOS    | tvOS 12，使用 Xcode 27 配置时为 tvOS 15                                       | 真机 arm64，模拟器 arm64 / x86\_64      |
| Android | Android 5.0（API 21）                                                    | 发布 AAR 包含 arm64-v8a / armeabi-v7a |

## FSPlayer-Pro

FSPlayer-Pro 以动态库形式提供 Dolby Vision P5、HLS 点播边播边缓存、无缝切换音轨与清晰度，以及网络 ISO / BDMV 的首帧和跳转加速。 [邮件联系](mailto:debugly@icloud.com)

## 反馈与许可

- [提交问题或功能建议](https://github.com/debugly/fsplayer/issues)
- [查看更新日志](CHANGELOG.md)
- [支持项目](doc/donate.md)

FSPlayer 使用 [LGPL-2.1-or-later](COPYING.LGPLv2.1) 发布。第三方组件保留各自的许可证和版权声明。 [分发声明](NOTICE)