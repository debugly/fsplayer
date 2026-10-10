## 迁移指南

1、重新安装 FSPlayer，支持 pod、spm 方式
2、打开工程，按照如下列表全部替换即可：

| 老的(ijkplayer)                                   | 新的（FSPlayer）                   |
| ----------------------------------------------- | ------------------------------ |
| #import <IJKMediaPlayerKit/IJKMediaPlayerKit.h> | #import <FSPlayer/FSPlayer.h>  |
| IJKFFMoviePlayerController                      | FSPlayer                       |
| IJKInternalRenderView                           | FSVideoRenderView              |
| IJKFFOptions                                    | FSOptions                      |
| IJKFFMonitor                                    | FSMonitor                      |
| kk_IJKM_KEY_STREAMS                             | FS_KEY_STREAMS                 |
| k_IJKM_KEY_TYPE                                 | FS_KEY_STREAM_TYPE             |
| k_IJKM                                          | FS                             |
| k_IJK                                           | FS                             |
| IJKSDLColorConversionPreference                 | FSColorConvertPreference       |
| IJKSDLSubtitlePreference                        | FSSubtitlePreference           |
| IJKSDLSnapshotType                              | FSSnapshotType                 |
| IJKSDLSnapshot_                                 | FSSnapshotType                 |
| IJKSDLRotate                                    | FSRotate                       |
| IJKSDLDAR                                       | FSDAR                          |
| IJKMPMovieNoCodec                               | FSPlayerNoCodec                |
| IJKMPMovieNatural                               | FSPlayerNatural                |
| IJKMoviePlayer                                  | FSPlayer                       |
| IJKMPMediaPlayback                              | FSPlayer                       |
| IJKMPMoviePlayerPlayback                        | FSPlayer                       |
| IJKMPMoviePlaybackState                         | FSPlayerPlaybackState          |
| IJKMPMoviePlayer                                | FSPlayer                       |
| IJKMoviePlayer                                  | FSPlayer                       |
| IJKMPMovieLoadState                             | FSPlayerLoadState              |
| IJKMPMovie                                      | FS                             |
| IJK                                             | FS                             |
| str_to_uint32_color                             | fs_str_to_uint32_color         |
| ijk_subtitle_default_preference                 | fs_subtitle_default_preference |
| isIJKSDLSubtitlePreferenceEqual                 | FSSubtitlePreferenceIsEqual    |

### Android

Java 层的包名和类名同时改到了 `com.debugly.fsplayer.*`，import 必须整体替换：

| 老的(tv.danmaku.ijk.media)                 | 新的（com.debugly.fsplayer）              |
| ---------------------------------------- | ---------------------------------- |
| tv.danmaku.ijk.media.player.IjkMediaPlayer      | com.debugly.fsplayer.player.FSPlayer      |
| tv.danmaku.ijk.media.player.IjkMediaMeta        | com.debugly.fsplayer.player.FSMeta        |
| tv.danmaku.ijk.media.player.misc.IjkMediaFormat | com.debugly.fsplayer.player.misc.FSFormat |
| tv.danmaku.ijk.media.player.IjkMediaCodecInfo  | com.debugly.fsplayer.player.FSCodecInfo  |
| IjkMediaMeta.IjkStreamMeta                        | FSMeta.FSStreamMeta                        |
| tv.danmaku.ijk.media.player.misc.IjkTrackInfo      | com.debugly.fsplayer.player.misc.FSTrackInfo |
| tv.danmaku.ijk.media.player.IjkTimedText       | com.debugly.fsplayer.player.FSTimedText   |
| tv.danmaku.ijk.media.player.IjkLibLoader       | com.debugly.fsplayer.player.FSLibLoader   |
| tv.danmaku.ijk.media.player.exceptions.IjkMediaException | com.debugly.fsplayer.player.exceptions.FSException |

原生库也从 `libijkplayer.so` 改名成了 `libfsplayer.so`，自建
`FSLibLoader` 实现并自行 `System.loadLibrary` 的调用方需要跟着改加载名
（默认路径 `FSPlayer.loadLibrariesOnce()` 已经改成加载 `fsplayer`）。

注意：这次改名没有改 C 层。`struct IjkMediaPlayer` 和所有 C 函数名保持原样，
只有 JNI 绑定用的类名字符串随 Java 类名一起更新，所以下游不需要碰 native。

demo app 自己不属于 AAR 的一部分，它的命名空间单独跟着 applicationId 走：
`com.debugly.fsplayer.demo` → `com.debugly.aura`（`applicationId` 一直是
`com.debugly.aura`，这次只是让 Java 包与之对齐）。照着 demo 抄代码的调用方
需要把 `tv.danmaku.ijk.media.example.*` 一起换成 `com.debugly.aura.*`。
