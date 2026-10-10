# FSPlayer

[Stargazers repo roster for @debugly/fsplayer](https://github.com/debugly/fsplayer/stargazers)

**FSPlayer is the actively-maintained successor to [ijkplayer](https://github.com/bilibili/ijkplayer).** It keeps the proven `ijkplayer` architecture while replacing its aging foundation with a modern one: FFmpeg 8, Metal / Vulkan rendering, hardware-decode hot-switching, and first-class support for HDR, Dolby Vision, Blu-ray/ISO, and rich subtitle effects.

> 🇨🇳 中文文档见 [README.md](./README_zh-CN.md)

## Why FSPlayer over ijkplayer

ijkplayer has been effectively unmaintained for years — its last release (`k0.8.8`) is from 2018. It ships FFmpeg 4.0 (2021). Renders through OpenGL ES 2.0, and its own README lists native subtitle rendering and avfilter support as explicitly *not on plan*.

FSPlayer keeps the same architecture you know, and moves the stack forward:


|                                      | ijkplayer                                     | FSPlayer                                          |
| ------------------------------------ | --------------------------------------------- | ------------------------------------------------- |
| **Maintenance**                      | Stalled — last release 2018, last commit 2021 | Active — updated monthly                          |
| **FFmpeg**                           | 4.0                                    | **8.1.2**                                         |
| **Platforms**                        | Android, iOS                                  | Android, iOS, macOS, tvOS,                        |
| **Video output**                     | OpenGL ES 2.0                                 | **Metal** (iOS/macOS/tvOS) · **Vulkan** (Android) |
| **4K / HDR / HDR10+ / Dolby Vision** | ✗                                             | **✓**                                             |
| **Native subtitle rendering**        | ✗ (explicitly not on plan)                    | **✓** — ASS effects, text + bitmap subs           |
| **Blu-ray / ISO / BDMV**             | ✗                                             | **✓** — incl. over network                        |
| **avfilter / video filters**         | ✗ (explicitly not on plan)                    | **✓** — e.g. software deinterlacing               |
| **HW-decode hot switch**             | ✗                                             | **✓** — no player restart needed                  |
| **Distribution**                     | jcenter (dead) / manual                       | **SPM + CocoaPods · Maven Central** (Android)     |
| **License**                          | LGPLv2.1+                                     | LGPLv2.1+                                         |


Already on ijkplayer? Migration is straightforward — see the [migration guide](./doc/migration.md).

## FSPlayer All Features

- [x] FFmpeg 8.1.2
- [x] Pass-through of FFmpeg options
- [x] Download speed &amp; preload progress reporting
- [x] Media info (audio sample rate / channels / duration; video width / height / fps / duration)
- [x] First-frame decode &amp; render timing
- [x] Protocols: file, http, https, udp, rtmp, rtp, rtsp, bluray, smb, ftp, …
- [x] HTTP tuning: timeout, retry, User-Agent, Cookie, Referer, Origin (and pass-through to TS requests for m3u8)
- [x] HLS live &amp; VOD
- [x] AV1 and uavs3 decoders
- [x] Embedded cover art for audio playback
- [x] Image playback (incl. animated WebP)
- [x] Accurate seeking
- [x] Hardware / software decoding, switchable without restart
- [x] Multiple concurrent instances
- [x] Re-seek after EOF
- [x] Fast start for `file` protocol seeks
- [x] Encrypted A/V playback (e.g. AES-128 HLS)
- [x] Powerful subtitles
  - [x] Text subtitles (srt / vtt / ass)
  - [x] Bitmap subtitles (dvbsub / dvdsub / pgssub / idx+sub)
  - [x] Embedded and external
  - [x] Subtitle delay
  - [x] ASS effects
  - [x] Text subtitle styling
- [x] Loop playback
- [x] Audio track switching &amp; track delay
- [x] Snapshot (jpg, png, tiff)
- [x] Display aspect ratio, rotation (0/90/180/270), horizontal &amp; vertical mirror
- [x] Video background color (default black)
- [x] Saturation / brightness / contrast
- [x] Render one frame to multiple views
- [x] Real-time PCM access
- [x] Custom render view &amp; custom audio renderer
- [x] 4K / HDR / HDR10 / HDR10+ / Dolby Vision (Pro adds Dolby Vision P5)
- [x] Smart ISO detection (bluray / DVD / regular video)
- [x] No pixelation on MPEG-TS fast-forward
- [x] Network playback of ISO images and BDMV folders
- [x] Force a channel on stereo audio
- [x] Access the currently displayed video frame
- [x] Video recording (iOS saves to Photos)
- [x] Buffer progress notifications
- [x] Async destroy (safe even without calling `shutdown`)
- [x] Optional player-controlled AudioSession
- [x] Smoother view rotation animation
- [x] Tile-grid HEIC playback
- [x] Gaussian blur background

Latest additions

- [x] HDR display brightens the HDR screen
- [x] Playable &amp; seekable when audio ends before video
- [x] Video filters with software deinterlacing
- [x] Synchronous destroy (async by default)

Under investigation

- [ ] AV1 hardware decode (stable on most, some files still crash)
- [ ] Live playback / timeshift
- [ ] Variable playback rate with pitch correction
- [ ] Transparent video
- [ ] Picture-in-picture

## Build environment

- macOS Tahoe (26.5)
- Xcode 26.6 (17F113)
- Android NDK 27.3


| Minimum platform     | Architectures                               |
| -------------------- | ------------------------------------------- |
| iOS 12.0             | arm64, arm64\_simulator, x86\_64\_simulator |
| macOS 10.14          | arm64, x86\_64                              |
| tvOS 12.0            | arm64, arm64\_simulator, x86\_64\_simulator |
| Android 7.0 (API 24) | arm64-v8a, armeabi-v7a                       |


## Changelog

- [CHANGELOG.md](CHANGELOG.md)

## Integration

FSPlayer is free and released under [LGPLv2.1+](./COPYING.LGPLv2.1). If it's useful to you, [buy the author a coffee](./Donate.md).

- Swift Package Manager: [FSPlayer-SPM](https://github.com/debugly/FSPlayer-SPM.git)
- CocoaPods:

```
pod "FSPlayer", :podspec => 'https://github.com/debugly/fsplayer/releases/download/1.1.1/FSPlayer.spec.json'
```

- Android (Gradle, Maven Central):

```groovy
dependencies {
    implementation 'io.github.debugly:fsplayer:1.1.1'
}
```

### Usage

**Apple**

```objc
FSOptions *options = [FSOptions optionsByDefault];
self.player = [[FSPlayer alloc] initWithContent:url options:options];

NSView <FSVideoRenderingProtocol>* playerView = self.player.view;
playerView.frame = self.playerContainer.bounds;
playerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
[self.playerContainer addSubview:playerView positioned:NSWindowBelow relativeTo:self.playerCtrlPanel];

self.player.shouldAutoplay = YES;
[self.player prepareToPlay];
```

**Android**

The Android build is an AAR. `FSPlayer` implements `IMediaPlayer` directly (the
ijkplayer-style `setDataSource` / `prepareAsync` / `start` lifecycle), so hand it a
`SurfaceHolder` and it renders there.

```java
FSPlayer player = new FSPlayer();
// hardware / software decoding, same option semantics as ijkplayer
player.setOption(FSPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 1);
player.setDisplay(surfaceView.getHolder());   // or setSurface(surface)

player.setDataSource(context, uri);
player.setOnPreparedListener(mp -> mp.start());
player.prepareAsync();
```

Call `release()` when done. To switch media source on a live instance use `reset()`,
which tears down and recreates the native player. To check whether hardware or
software decoding is in use, look at `getVideoDecoder()`
(`FFP_PROPV_DECODER_MEDIACODEC` means hardware).

Full [documentation](https://fsplayer.debugly.cn/manuals/getting-started.html).

## Building from source

The source is fully open; build the framework (Apple) or AAR (Android) yourself:

```bash
# iOS
./FFToolChain/main.sh install -p ios -l 'ass ffmpeg'
./examples/ios/build-framework.sh
# macOS
./FFToolChain/main.sh install -p macos -l 'ass ffmpeg'
./examples/macos/build-framework.sh
# tvOS
./FFToolChain/main.sh install -p tvos -l 'ass ffmpeg'
./examples/tvos/build-framework.sh
# Android
./FFToolChain/main.sh install -p android -l 'ass ffmpeg'
cd android && ./gradlew :fsplayer:assembleRelease
```

## FSPlayer-Pro

A drop-in dynamic library on top of FSPlayer with extra capabilities:

- Dolby Vision P5
- HLS VOD play-while-cache (seeking back to cached content costs no traffic and starts faster)
- Seamless audio-track switching (no reload / no brief silence or black frame)
- Seamless quality switching
- Multi-x faster first-frame and seek start for network ISO / BDMV playback

Contact: [debugly@icloud.com](mailto:debugly@icloud.com)