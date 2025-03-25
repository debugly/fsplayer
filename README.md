<div align="center">
  <img alt="f s p la y er" src="./primary-wide.png">
  <h1>fsplayer</h1>
  <img src="https://github.com/debugly/fsplayer/actions/workflows/apple.yml/badge.svg">
</div>

[![Stargazers repo roster for @debugly/fsplayer](https://reporoster.com/stars/debugly/fsplayer)](https://github.com/debugly/fsplayer/stargazers)

## Feature Compare

fsplayer based on [ijkplayer](https://github.com/bilibili/ijkplayer)

| category                                                | ijkplayer                      | fsplayer                                                                                                                                                                                     |
| ------------------------------------------------------- | ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| FFmpeg                                                  | ff4.0--ijk0.8.8--20210426--001 | n6.1.1                                                                                                                                                                                       |
| decoders                                                |                                |                                                                                                                                                                                              |
| uavs3d decoder                                          | ❌                              | ✅                                                                                                                                                                                            |
| demuxers                                                |                                |                                                                                                                                                                                              |
| video-output                                            | OpenGLES2                      | Metal 2,OpenGL 3.3(macOS)                                                                                                                                                                    |
| audio-output                                            | AudioQueue, AudioUnit          | AudioQueue, AudioUnit                                                                                                                                                                        |
| subtitle                                                | ❌(parse to text,don't render)  | - text subtitle(srt/vtt/ass)<br/>- image subtitle(dvbsub/dvdsub/pgssub/idx+sub)<br/>- support intenal and external<br/>- text subtitle support force style<br/>- adjust position y and scale |
| accurate seek                                           | ❌(not good)                    | ✅                                                                                                                                                                                            |
| seek mpegts video,prevent display pixelation            | ❌                              | ✅                                                                                                                                                                                            |
| ts inherit m3u8 http control options                    | ❌                              | ✅                                                                                                                                                                                            |
| local movie after seek, start playing in a split second | ❌                              | ✅                                                                                                                                                                                            |
| extra audio delay                                       | ❌                              | ✅                                                                                                                                                                                            |
| extra subtitle delay                                    | ❌                              | ✅                                                                                                                                                                                            |
| 4k/HDR/HDR10/HDR10+                                     | ❌                              | ✅                                                                                                                                                                                            |
| bluray:// BDMV(Blu-ray Disc Movie)(iso镜像，蓝光原盘)          | ❌                              | ✅                                                                                                                                                                                            |
| bluray:// BDMV(文件夹)                                     | ❌                              | ✅                                                                                                                                                                                            |
| bluray:// 协议嵌套实现播放网络 BMDV                               | ❌                              | ✅                                                                                                                                                                                            |
| smb://                                                  | ❌                              | ✅                                                                                                                                                                                            |
| dvd://                                                  | ❌                              | ✅                                                                                                                                                                                            |
| hardware acceleration                                   | ✅ use video toolbox            | ✅ use ffmpeg built videotoolbox hwaccel                                                                                                                                                      |
| andorid platform                                        | ✅                              | ❌                                                                                                                                                                                            |
| ios platform                                            | ✅                              | ✅                                                                                                                                                                                            |
| macos platform                                          | ❌                              | ✅                                                                                                                                                                                            |
| tvos platform                                           | ❌                              | ✅                                                                                                                                                                                            |

项目一直在使用 ijkplayer 并且功能完全可以满足的情况下，不要使用 fsplayer，只需要使用我维护的 [ijkplayer](https://github.com/debugly/ijkplayer) 就行，主要是升级了编译工具链，能够正常在最新的安卓15和iOS18上正常运行。

如果之前使用的 ijkplayer，请参考 [迁移指南](./doc/migration.md) 使用全新的 fsplayer。

## My Build Environment

- macOS Sequoia(15.1)
- Xcode Version 16.2 (16C5032a)
- cocoapods 1.16.1

| Platform    | Archs                                  |
| ----------- | -------------------------------------- |
| iOS 11.0    | arm64、arm64_simulator、x86_64_simulator |
| macOS 10.11 | arm64、x86_64                           |
| tvOS 12.0   | arm64、arm64_simulator、x86_64_simulator |

## Latest Changes

- [CHANGELOG.md](CHANGELOG.md)

## Donate

- [Donate](./Donate.md)
- [捐赠](./Donate.md)

## Installation

- integration via Swift Package Manger:

```
https://github.com/debugly/FSPlayer-SPM.git
```

- integration via Cocoapods:

```
pod "FSPlayer", :podspec => 'https://github.com/debugly/fsplayer/releases/download/1.0.0/FSPlayer.spec.json'
```

## Development

if you need change source code, you can use git add submodule, then use cocoapod integrate fsplayer into your workspace by development pod like examples.

how to run examples:

```
git clone https://github.com/debugly/fsplayer.git fsplayer
cd fsplayer
git checkout -B latest 1.0.0
git submodule update --init

./FFToolChain/main.sh install -p macos -l 'ass ffmpeg'
./FFToolChain/main.sh install -p ios -l 'ass ffmpeg'
./FFToolChain/main.sh install -p tvos -l 'ass ffmpeg'

pod install --project-directory=./examples/macos
pod install --project-directory=./examples/ios
pod install --project-directory=./examples/tvos

# run iOS demo
open ./examples/ios/FSPlayerDemo.xcworkspace
# run macOS demo
open ./examples/macos/FSPlayerMacDemo.xcworkspace
# run tvOS demo
open ./examples/tvos/FSPlayerTVDemo.xcworkspace
```

if you want build your FSPlayer.framework, you need enter examples/{plat} folder, then exec `./build-framework.sh`

## Support

- Please do not send e-mail to me. Public technical discussion on github is preferred.
- 请尽量在 github 上公开讨论[技术问题](https://github.com/debugly/fsplayer/issues)，不要以邮件方式私下询问，恕不一一回复。

## License

```
Copyright (c) 2021 qianlongxu
Licensed under LGPLv3
```
