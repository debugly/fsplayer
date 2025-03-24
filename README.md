<div align="center">
  <img alt="ijkplayer" src="./primary-wide.png">
  <h1>ijkplayer</h1>
  <img src="https://github.com/debugly/ijkplayer/actions/workflows/apple.yml/badge.svg">
</div>

[![Stargazers repo roster for @debugly/ijkplayer](https://reporoster.com/stars/debugly/ijkplayer)](https://github.com/debugly/ijkplayer/stargazers)

ijk media player based on [ffplay](http://ffmpeg.org)

| Platform    | Archs                                   |
| ----------- | ----------------------------------------|
| iOS 11.0    | arm64、arm64_simulator、x86_64_simulator |
| macOS 10.11 | arm64、x86_64                            | 
| tvOS 12.0   | arm64、arm64_simulator、x86_64_simulator |

## My Build Environment

- macOS Sequoia(15.1)
- Xcode Version 16.1 (15F31d)
- cocoapods 1.16.1

## Latest Changes

- [CHANGELOG.md](CHANGELOG.md)

## Features

- Common
  - using FFmpeg 6.1.2
  - enabled ffmpeg all decoders and demuxers binary size is bigger [FFToolChain/ffconfig/module-full.sh](FFToolChain/ffconfig/module-full.sh)
  - workaround for some buggy online video
- iOS/macOS/tvOS
  - video-output: Metal 2/OpenGL 3.3
  - audio-output: AudioQueue, AudioUnit
  - hardware acceleration: auto choose VideoToolbox by default
  - subtitle:
    - text subtitle(srt/vtt/ass)/image subtitle(dvbsub/dvdsub/pgssub/idx+sub)
    - support intenal and external
    - text subtitle support force style
    - adjust position y and scale
  - 4k/HDR/HDR10/HDR10+/Dolby Vision Compatible
  - support Network or Local Blu-ray Disc/BDMV
  - set audio or subtitle extra delay
  - support dash demuxer

## Donate

- Donate to [debugly/ijkplayer](./Donate.md)
- 捐赠 [debugly/ijkplayer](./Donate.md)

## Installation

- integration via Swift Package Manger:

```
https://github.com/debugly/FSMediaPlayer-SPM.git
```

- integration via Cocoapods:

```
pod "FSMediaPlayerKit", :podspec => 'https://github.com/debugly/ijkplayer/releases/download/k0.12.0/FSMediaPlayerKit.spec.json'
```

## Development

if you need change source code, you can use git add submodule, then use cocoapod integrate ijk into your workspace by development pod like examples.

how to run examples:

```
git clone https://github.com/debugly/ijkplayer.git ijkplayer
cd ijkplayer
git checkout -B latest k0.12.0
git submodule update --init

./FFToolChain/main.sh install -p macos -l 'ass ffmpeg'
./FFToolChain/main.sh install -p ios -l 'ass ffmpeg'
./FFToolChain/main.sh install -p tvos -l 'ass ffmpeg'

pod install --project-directory=./examples/macos
pod install --project-directory=./examples/ios
pod install --project-directory=./examples/tvos

# run iOS demo
open ./examples/ios/FSMediaDemo.xcworkspace
# run macOS demo
open ./examples/macos/FSMediaMacDemo.xcworkspace
# run tvOS demo
open ./examples/tvos/FSMediaTVDemo.xcworkspace
```

if you want build your FSMediaPlayerKit.framework, you need enter examples/{plat} folder, then exec `./build-framework.sh`

## Support (支持)

- Please do not send e-mail to me. Public technical discussion on github is preferred.
- 请尽量在 github 上公开讨论[技术问题](https://github.com/debugly/ijkplayer/issues)，不要以邮件方式私下询问，恕不一一回复。

## License

```
Copyright (c) 2017 Bilibili
Licensed under LGPLv2.1 or later
Copyright (c) 2022 Sohu
Licensed under LGPLv2.1 or later
```

ijkplayer required features are based on or derives from projects below:

- LGPL
  - [FFmpeg](http://git.videolan.org/?p=ffmpeg.git)
  - [libVLC](http://git.videolan.org/?p=vlc.git)
  - [kxmovie](https://github.com/kolyvan/kxmovie)
  - [soundtouch](http://www.surina.net/soundtouch/sourcecode.html)
- zlib license
  - [SDL](http://www.libsdl.org)
- BSD-style license
  - [libyuv](https://code.google.com/p/libyuv/)
- ISC license
  - [libyuv/source/x86inc.asm](https://code.google.com/p/libyuv/source/browse/trunk/source/x86inc.asm)

android/ijkplayer-exo is based on or derives from projects below:

- Apache License 2.0
  - [ExoPlayer](https://github.com/google/ExoPlayer)

android/example is based on or derives from projects below:

- GPL
  - [android-ndk-profiler](https://github.com/richq/android-ndk-profiler) (not included by default)

ios/FSMediaDemo is based on or derives from projects below:

- Unknown license
  - [iOS7-BarcodeScanner](https://github.com/jpwiddy/iOS7-BarcodeScanner)

ijkplayer's build scripts are based on or derives from projects below:

- [gas-preprocessor](http://git.libav.org/?p=gas-preprocessor.git)
- [VideoLAN](http://git.videolan.org)
- [yixia/FFmpeg-Android](https://github.com/yixia/FFmpeg-Android)
- [kewlbear/FFmpeg-iOS-build-script](https://github.com/kewlbear/FFmpeg-iOS-build-script) 

## Commercial Use

ijkplayer is licensed under LGPLv2.1 or later, so itself is free for commercial use under LGPLv2.1 or later

But ijkplayer is also based on other different projects under various licenses, which I have no idea whether they are compatible to each other or to your product.

[IANAL](https://en.wikipedia.org/wiki/IANAL), you should always ask your lawyer for these stuffs before use it in your product.

## Icon

Primay icon was made by my friend 小星.
