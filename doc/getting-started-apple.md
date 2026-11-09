**简体中文** · [English](getting-started-apple_en-US.md)

## 在 iOS、macOS 和 tvOS 上接入 FSPlayer

选择一种集成方式。示例中的版本号可以替换为所需的已发布版本。

### Swift Package Manager 集成

在现有 Swift Package 的 `Package.swift` 中添加依赖，并关联到使用 FSPlayer 的 target（将 `MyLibrary` 替换为实际 target 名称）：

```swift
// 合并到 Package(...) 的 dependencies 中
.package(
    url: "https://github.com/debugly/fsplayer-spm.git",
    exact: "1.1.3-beta-3"
)

// 合并到 Package(...) 的 targets 中
.target(
    name: "MyLibrary",
    dependencies: [
        .product(name: "FSPlayer", package: "fsplayer-spm")
    ]
)
```

如果使用 Xcode App 工程，可通过 **File → Add Package Dependencies…** 添加同一仓库地址，再将 `FSPlayer` 产品关联到应用 target。

### CocoaPods 集成

```
pod "FSPlayer", :podspec => 'https://github.com/debugly/fsplayer/releases/download/1.1.2/FSPlayer.spec.json'
```

### 直接集成 xcframework

下载并解压 `FSPlayer.zip`，将其中的 `FSPlayer.xcframework` 添加到应用 target。 [GitHub Releases](https://github.com/debugly/fsplayer/releases)

### Git 子模块集成

如果需要修改源码，可将 FSPlayer 添加为 Git 子模块，并在子模块目录中按平台安装依赖、运行 `./generate-proj.sh`。将生成的 `FSPlayer.xcodeproj` 加入应用工程或 workspace，再在应用 target 的 **General → Frameworks, Libraries, and Embedded Content** 中添加对应平台 target 生成的 `FSPlayer.framework`。 [开发环境与依赖安装](../CONTRIBUTING.md)

## 常用功能

### 日志级别

```objc
#import <FSPlayer/FSPlayer.h>
[FSPlayer setLogLevel:FS_LOG_DEBUG];
```

### 播放

```objc
#import <FSPlayer/FSPlayerKit.h>

FSOptions *options = [FSOptions optionsByDefault];
NSString *mediaURL = @"https://example.com/video.mov"; // 替换为实际播放地址
self.player = [[FSPlayer alloc] initWithContent:mediaURL options:options];

UIView<FSVideoOutputProtocol> *playerView = self.player.view;
playerView.frame = self.playerContainer.bounds;
#if TARGET_OS_OSX
playerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
#else
playerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
#endif
[self.playerContainer addSubview:playerView];

self.player.shouldAutoplay = YES;
[self.player prepareToPlay];
```

页面退出且不再使用播放器时，调用 `shutdown` 释放播放资源。

### 常用的选项

根据场景选择所需的选项，在创建播放器前设置。

```objc
// 不限制输入缓冲区大小，按需用于实时流。
[options setPlayerOptionIntValue:1 forKey:@"infbuf"];
//缓冲队列空是否需要加载一些数据后才能播放，0即为有数据就播放
[options setPlayerOptionIntValue:1 forKey:@"packet-buffering"];
//视频帧处理不过来的时候丢弃一些帧达到同步的效果
[options setPlayerOptionIntValue:1 forKey:@"framedrop"];
//视频帧缓存数量上限
[options setPlayerOptionIntValue:6 forKey:@"video-pictq-size"];
// 音频和视频包队列达到该阈值后，可暂停预读。
[options setPlayerOptionIntValue:50000      forKey:@"min-frames"];
// 0 表示无限循环，1 表示只播放一次。
[options setPlayerOptionIntValue:0 forKey:@"loop"];
// MPEG-TS 跳转时仅为关键帧建立索引，减少跳转后的花屏。
[options setFormatOptionIntValue:1 forKey:@"seek_flag_keyframe"];
//设置探测数据上限，默认是 5000000，但是一些超高码率的视频会探测失败，或者探测信息不全
[options setFormatOptionValue:@"10000000" forKey:@"probesize"];
// 设置 ICY 元数据更新间隔，单位为毫秒。
[options setPlayerOptionValue:@"3500" forKey:@"icy-update-period"];
// 启用 CVPixelBufferPool，复用软解帧转换所需的像素缓冲区。
[options setPlayerOptionIntValue:1 forKey:@"enable-cvpixelbufferpool"];
//使用硬件加速解码视频帧，降低 CPU 消耗
[options setPlayerOptionIntValue:1 forKey:@"videotoolbox_hwaccel"];
//复制硬解解码数据
[options setPlayerOptionIntValue:1 forKey:@"copy_hw_frame"];
//开启精准 seek，避免进度回退
[options setPlayerOptionIntValue:1 forKey:@"enable-accurate-seek"];
//精准 seek 超时时长，单位ms
[options setPlayerOptionIntValue:1500 forKey:@"accurate-seek-timeout"];
//调试时有用，展示相关指标
options.showHudView = self.shouldShowHudView;
// 为 HTTP seek 请求设置备用认证方式，1 表示 Basic。
[options setFormatOptionValue:@"1" forKey:@"auth_type2"];
// 使用 FSPlayer 的 ijkhls 协议时，让分片请求额外继承 ijkapplication 选项。
[options setFormatOptionValue:@"ijkapplication" forKey:@"seg_inherit_options"];
//设置cookie
[options setFormatOptionValue:@"test=cookie" forKey:@"cookies"];
//设置user_agent
[options setFormatOptionValue:@"your_agent" forKey:@"user_agent"];
// 声明客户端可接受 gzip 或 deflate 响应，由服务器决定是否压缩。
[options setFormatOptionValue:@"Accept-Encoding: gzip, deflate" forKey:@"headers"];
//设置代理
[options setFormatOptionValue:@"http://127.0.0.1:8888" forKey:@"http_proxy"];
```

### 暂停/播放/停止

```objc
// 按需调用其中一个方法。
[self.player play];
[self.player pause];
[self.player stop];
```

### 快进快退

将 `currentPlaybackTime` 设为目标播放时间，单位为秒。

### 倍速播放

设置 `playbackRate`，例如 `1.5f` 表示 1.5 倍速。

### 调节音量

设置 `playbackVolume`，例如 `0.5f` 表示一半音量。

### 字幕

添加外挂字幕，最多可挂载512个

```objc
//挂载并激活字幕；本地网络均可
- (BOOL)loadThenActiveSubtitle:(NSURL*)url;
//仅挂载不激活字幕；本地网络均可
- (BOOL)loadSubtitleOnly:(NSURL*)url;
//批量挂载不激活字幕；本地网络均可
- (BOOL)loadSubtitlesOnly:(NSArray<NSURL*>*)urlArr;
```

相同路径的字幕重复挂载会失败；没有激活的字幕，可通过 `- (void)exchangeSelectedStream:(int)streamIdx;` 方法激活。

关闭字幕和关闭音视频流方式一样：

```objc
// FS_VAL_TYPE__VIDEO, FS_VAL_TYPE__AUDIO, FS_VAL_TYPE__SUBTITLE
- (void)closeCurrentStream:(NSString *)streamType;
```

通过 `subtitlePreference` 设置字体、文字颜色、描边颜色和背景颜色等。

内嵌的音视频字幕流在 prepared 之后，会通过 FSPlayerIsPreparedToPlayNotification 通知，然后从 self.player.monitor.mediaMeta 里获取到流信息。

当手动挂载字幕流或者关闭流之后，会通过 FSPlayerSelectedStreamDidChangeNotification 通知，然后重新获取 mediaMeta 字典拿到最新流信息。

### 设置画面填充模式

在默认渲染视图上设置 `scalingMode`。可选择等比适配 `FSScalingModeAspectFit`、等比填满 `FSScalingModeAspectFill` 或拉伸填满 `FSScalingModeFill`。

使用画面控制接口时，导入 `<FSPlayer/FSVideoRenderingProtocol.h>`。自定义渲染视图需实现相应的接口。

### 逐帧播放

```objc
[self.player stepToNextFrame];
```

### 音频延迟/字幕延迟

设置 `currentAudioExtraDelay` 或 `currentSubtitleExtraDelay` 分别调整音频或字幕延迟，单位均为秒。

### 获取视频时长

- `duration` 返回媒体总时长，单位为秒。
- `playableDuration` 返回当前可播放到的时间点，单位为秒。
- `bufferingProgress` 返回缓冲进度，按百分比表示。

### 获取加载速度

调用 `currentDownloadSpeed` 获取下载速度，单位为字节每秒。

### 截屏

截取当前显示画面。使用默认渲染视图时，`snapshot:` 可在 iOS、macOS 和 tvOS 上使用，返回 `CGImageRef`。没有可截取的画面时返回 `NULL`。

```objc
id<FSVideoRenderingProtocol> renderingView = (id<FSVideoRenderingProtocol>)self.player.view;
CGImageRef image = [renderingView snapshot:FSSnapshotTypeScreen];
```

### 旋转画面

分别使用 `xRotateDegrees`、`yRotateDegrees` 和 `zRotateDegrees` 设置三个轴的旋转角度，单位为度。

```objc
id<FSVideoRenderingProtocol> renderingView = (id<FSVideoRenderingProtocol>)self.player.view;
renderingView.zRotateDegrees = 90.0f;
```

### 修改画面色彩

```objc
FSColorConvertPreference preference;
preference.brightness = 1.0;
preference.saturation = 1.0;
preference.contrast = 1.0;
id<FSVideoRenderingProtocol> renderingView = (id<FSVideoRenderingProtocol>)self.player.view;
renderingView.colorPreference = preference;
```

### 设定画面比例

```objc
FSDARPreference preference;
preference.ratio = 16.0/9;
id<FSVideoRenderingProtocol> renderingView = (id<FSVideoRenderingProtocol>)self.player.view;
renderingView.darPreference = preference;
```

### HDR 直出

默认渲染视图允许 HDR 直出。只有视频是 HDR 且当前屏幕具备 EDR 显示能力时，播放器才会启用 HDR 输出。将 `allowHDRDirectDisplay` 设为 `NO` 可以强制将 HDR 内容映射到 SDR。

该属性适用于 macOS 和 iOS 16 及以上，tvOS 不提供此接口。

```objc
id<FSVideoRenderingProtocol> renderingView = (id<FSVideoRenderingProtocol>)self.player.view;

#if TARGET_OS_OSX
renderingView.allowHDRDirectDisplay = NO;
#elif TARGET_OS_IOS
if (@available(iOS 16.0, *)) {
    renderingView.allowHDRDirectDisplay = NO;
}
#endif
```

### 透明视频与透明背景

对带 Alpha 通道的视频，可以打开 `autoTransparentBackgroundColor`。播放器检测到带 Alpha 的帧时，会自动把渲染视图的底色切换为透明。普通视频仍使用已设置的背景。该选项默认关闭。

```objc
id<FSVideoRenderingProtocol> renderingView = (id<FSVideoRenderingProtocol>)self.player.view;
[renderingView setBackgroundColor:0 g:0 b:0];
renderingView.autoTransparentBackgroundColor = YES;
```

如果希望一直透出下层视图，可直接设置透明背景。无视频区域和视频本身的透明区域都能透出下层内容。

```objc
[renderingView setBackgroundColor:0 g:0 b:0 transparent:YES];
```

这些设置只控制渲染视图。要透过父视图或 macOS 窗口，还需由宿主应用设置对应容器或窗口的透明状态。已设置的 `backgroundImage` 仍会绘制在需要填充的区域。想在应用侧判断当前帧是否带 Alpha，可在 `videoRenderingDidDisplay:attach:` 回调中读取 `attach.hasAlpha`。

### 设置背景色和模糊背景图

纯色背景默认是黑色。RGB 分量的范围为 `0–255`，三参数版本会设置不透明背景。

```objc
id<FSVideoRenderingProtocol> renderingView = (id<FSVideoRenderingProtocol>)self.player.view;
[renderingView setBackgroundColor:24 g:32 b:48];
```

如果希望用图片填充画面留边，可设置 `backgroundImage`。播放器会对传入的图片做高斯模糊，并在需要填充留边时绘制。图片由应用提供。迭代次数默认为 3，`backgroundBlurSigma` 默认为 30，值越大越模糊。

```objc
renderingView.backgroundBlurIterations = 3;
renderingView.backgroundBlurSigma = 30.0f;
#if TARGET_OS_OSX
renderingView.backgroundImage = [NSImage imageNamed:@"player-background"];
#else
renderingView.backgroundImage = [UIImage imageNamed:@"player-background"];
#endif
```

将 `backgroundImage` 设为 `nil` 可清除图片，恢复纯色或透明背景。若使用自定义渲染视图，请确认它实现了所需的可选背景接口。
