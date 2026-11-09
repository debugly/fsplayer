[简体中文](getting-started-apple.md) · **English**

## Getting started on iOS, macOS, and tvOS

Choose one integration method. You can replace the example versions with the published version you want to use.

### Swift Package Manager

Add FSPlayer to the dependencies in your existing Swift package's `Package.swift`, then add the FSPlayer product to the target that uses it. Replace `MyLibrary` with your target name.

```swift
// Add to the dependencies array in Package(...).
.package(
    url: "https://github.com/debugly/fsplayer-spm.git",
    exact: "1.1.3-beta-3"
)

// Add to the targets array in Package(...).
.target(
    name: "MyLibrary",
    dependencies: [
        .product(name: "FSPlayer", package: "fsplayer-spm")
    ]
)
```

For an Xcode app project, choose **File → Add Package Dependencies…**, enter the same repository URL, and add the `FSPlayer` product to your app target.

### CocoaPods

```ruby
pod "FSPlayer", :podspec => 'https://github.com/debugly/fsplayer/releases/download/1.1.2/FSPlayer.spec.json'
```

### Add the XCFramework directly

Download `FSPlayer.zip`, extract it, and drag `FSPlayer.xcframework` into your Xcode project. [GitHub Releases](https://github.com/debugly/fsplayer/releases)

### Git submodule

If you need to modify the source, add FSPlayer as a Git submodule. Install the dependencies for your platform and run `./generate-proj.sh` from the submodule directory. Add the generated `FSPlayer.xcodeproj` to your project or workspace. In your app target, open **General → Frameworks, Libraries, and Embedded Content** and add the `FSPlayer.framework` built by the target for your platform. [Development setup](CONTRIBUTING_en-US.md)

## Common tasks

### Set the log level

```objc
[FSPlayer setLogLevel:FS_LOG_DEBUG];
```

### Play media

```objc
#import <FSPlayer/FSPlayer.h>

FSOptions *options = [FSOptions optionsByDefault];
NSString *mediaURL = @"https://example.com/video.mov"; // Replace with your media URL.
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

Call `shutdown` to release playback resources when leaving the screen and you no longer need the player.

### Common options

Set the options you need before creating the player.

```objc
// Remove the input buffer size limit for a live stream when needed.
[options setPlayerOptionIntValue:1 forKey:@"infbuf"];
// Rebuffer when the packet queue empties. Set to 0 to resume as soon as data arrives.
[options setPlayerOptionIntValue:1 forKey:@"packet-buffering"];
// Drop video frames when rendering falls behind to keep playback in sync.
[options setPlayerOptionIntValue:1 forKey:@"framedrop"];
// Limit the number of frames in the video picture queue.
[options setPlayerOptionIntValue:6 forKey:@"video-pictq-size"];
// Allow pre-reading to pause once the audio and video packet queues reach this threshold.
[options setPlayerOptionIntValue:50000 forKey:@"min-frames"];
// Set to 0 for infinite looping or 1 to play once.
[options setPlayerOptionIntValue:0 forKey:@"loop"];
// Index only keyframes for MPEG-TS seeking to reduce visual artifacts after a seek.
[options setFormatOptionIntValue:1 forKey:@"seek_flag_keyframe"];
// Increase the probe size from the default of 5,000,000 bytes for very high-bitrate media.
[options setFormatOptionValue:@"10000000" forKey:@"probesize"];
// Set the ICY metadata update interval in milliseconds.
[options setPlayerOptionValue:@"3500" forKey:@"icy-update-period"];
// Reuse pixel buffers when converting software-decoded frames.
[options setPlayerOptionIntValue:1 forKey:@"enable-cvpixelbufferpool"];
// Use hardware video decoding to reduce CPU load.
[options setPlayerOptionIntValue:1 forKey:@"videotoolbox_hwaccel"];
// Copy hardware-decoded frames.
[options setPlayerOptionIntValue:1 forKey:@"copy_hw_frame"];
// Enable accurate seeking to avoid jumping back to an earlier position.
[options setPlayerOptionIntValue:1 forKey:@"enable-accurate-seek"];
// Set the accurate-seek timeout in milliseconds.
[options setPlayerOptionIntValue:1500 forKey:@"accurate-seek-timeout"];
// Show playback metrics for debugging.
options.showHudView = self.shouldShowHudView;
// Set a fallback authentication method for HTTP seek requests. 1 selects Basic.
[options setFormatOptionValue:@"1" forKey:@"auth_type2"];
// Pass the ijkapplication option to segment requests when using FSPlayer’s ijkhls protocol.
[options setFormatOptionValue:@"ijkapplication" forKey:@"seg_inherit_options"];
// Set a cookie.
[options setFormatOptionValue:@"test=cookie" forKey:@"cookies"];
// Set the user agent.
[options setFormatOptionValue:@"your_agent" forKey:@"user_agent"];
// Advertise gzip and deflate support. The server decides whether to compress the response.
[options setFormatOptionValue:@"Accept-Encoding: gzip, deflate" forKey:@"headers"];
// Set the HTTP proxy.
[options setFormatOptionValue:@"http://127.0.0.1:8888" forKey:@"http_proxy"];
```

### Play, pause, or stop

Call the method that matches the action you want.

```objc
[self.player play];
[self.player pause];
[self.player stop];
```

### Seek forward or backward

Set `currentPlaybackTime` to the target position in seconds.

### Change the playback rate

Set `playbackRate` to the desired rate. For example, `1.5f` plays at 1.5× speed.

### Adjust the volume

Set `playbackVolume` to the desired level. For example, `0.5f` sets half volume.

### Subtitles

You can load up to 512 external subtitle tracks. The URLs can point to local or remote files.

```objc
// Load and activate a subtitle track.
- (BOOL)loadThenActiveSubtitle:(NSURL *)url;
// Load a subtitle track without activating it.
- (BOOL)loadSubtitleOnly:(NSURL *)url;
// Load multiple subtitle tracks without activating them.
- (BOOL)loadSubtitlesOnly:(NSArray<NSURL *> *)urlArr;
```

Loading the same subtitle path twice fails. To activate a loaded track, call `exchangeSelectedStream:` with its stream index.

Use the same method to close a subtitle, audio, or video stream.

```objc
// Use FS_VAL_TYPE__VIDEO, FS_VAL_TYPE__AUDIO, or FS_VAL_TYPE__SUBTITLE.
- (void)closeCurrentStream:(NSString *)streamType;
```

Set `subtitlePreference` to customize the font, text color, outline color, and background color.

Once the player posts `FSPlayerIsPreparedToPlayNotification`, read the embedded video, audio, and subtitle streams from `self.player.monitor.mediaMeta`. After you load an external subtitle or close a stream, the player posts `FSPlayerSelectedStreamDidChangeNotification`. Read `mediaMeta` again to get the updated stream information.

### Set the scaling mode

Set `scalingMode` on the default rendering view. Use `FSScalingModeAspectFit` to fit, `FSScalingModeAspectFill` to fill while preserving the aspect ratio, or `FSScalingModeFill` to stretch.

Import `<FSPlayer/FSVideoRenderingProtocol.h>` to use the rendering controls. A custom rendering view must implement the controls you use.

### Advance one frame

```objc
[self.player stepToNextFrame];
```

### Adjust audio and subtitle delays

Set `currentAudioExtraDelay` or `currentSubtitleExtraDelay`. Both values are in seconds.

### Read duration and buffering progress

- `duration` returns the media duration in seconds.
- `playableDuration` returns the position you can currently play up to, in seconds.
- `bufferingProgress` returns buffering progress as a percentage.

### Read the download speed

Use `currentDownloadSpeed` to get the download speed in bytes per second.

### Take a screenshot

On iOS, macOS, and tvOS, the default rendering view’s `snapshot:` method returns the current picture as a `CGImageRef`. It returns `NULL` when there is no picture to capture.

```objc
id<FSVideoRenderingProtocol> renderingView = (id<FSVideoRenderingProtocol>)self.player.view;
CGImageRef image = [renderingView snapshot:FSSnapshotTypeScreen];
```

### Rotate the picture

Use `xRotateDegrees`, `yRotateDegrees`, and `zRotateDegrees` to rotate around each axis. The values are in degrees.

```objc
id<FSVideoRenderingProtocol> renderingView = (id<FSVideoRenderingProtocol>)self.player.view;
renderingView.zRotateDegrees = 90.0f;
```

### Adjust picture colors

```objc
FSColorConvertPreference preference;
preference.brightness = 1.0;
preference.saturation = 1.0;
preference.contrast = 1.0;
id<FSVideoRenderingProtocol> renderingView = (id<FSVideoRenderingProtocol>)self.player.view;
renderingView.colorPreference = preference;
```

### Set the display aspect ratio

```objc
FSDARPreference preference;
preference.ratio = 16.0/9;
id<FSVideoRenderingProtocol> renderingView = (id<FSVideoRenderingProtocol>)self.player.view;
renderingView.darPreference = preference;
```

### Direct HDR output

The default rendering view allows direct HDR output. The player enables it when the video is HDR and the current screen supports EDR. Set `allowHDRDirectDisplay` to `NO` to force HDR-to-SDR tone mapping.

This property is available on macOS and iOS 16 or later. It is unavailable on tvOS.

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

### Transparent video and backgrounds

Enable `autoTransparentBackgroundColor` to make the rendering view's background transparent when the current frame has an alpha channel. Other frames use the configured background. This option is off by default.

```objc
id<FSVideoRenderingProtocol> renderingView = (id<FSVideoRenderingProtocol>)self.player.view;
[renderingView setBackgroundColor:0 g:0 b:0];
renderingView.autoTransparentBackgroundColor = YES;
```

To always show the content underneath the rendering view, set its background to transparent. The underlying content can show through areas outside the video and through transparent pixels in the video itself.

```objc
[renderingView setBackgroundColor:0 g:0 b:0 transparent:YES];
```

These settings apply to the rendering view. The host app controls the transparency of parent views and macOS windows. A configured `backgroundImage` still draws where the video leaves empty space. To check whether the current frame has alpha, read `attach.hasAlpha` in the `videoRenderingDidDisplay:attach:` callback.

### Background color and blurred background image

The default background color is black. RGB components range from 0 to 255. The three-argument method sets an opaque background.

```objc
id<FSVideoRenderingProtocol> renderingView = (id<FSVideoRenderingProtocol>)self.player.view;
[renderingView setBackgroundColor:24 g:32 b:48];
```

Set `backgroundImage` to fill the space around the video with a blurred version of an image supplied by your app. The Gaussian blur defaults to three iterations with a sigma of 30. A higher sigma increases the blur.

```objc
renderingView.backgroundBlurIterations = 3;
renderingView.backgroundBlurSigma = 30.0f;
#if TARGET_OS_OSX
renderingView.backgroundImage = [NSImage imageNamed:@"player-background"];
#else
renderingView.backgroundImage = [UIImage imageNamed:@"player-background"];
#endif
```

Set `backgroundImage` to `nil` to clear the image and restore the solid or transparent background. If you supply a custom rendering view, check that it implements the optional background controls you use.
