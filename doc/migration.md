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
