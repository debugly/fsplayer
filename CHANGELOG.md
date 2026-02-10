tag 1.0.4
--------------------------------
- rename ijk_ass_* to fs_ass_*
- user agent use **fsplayer** instead of ijkplayer by default
- update dar、scaling、rotate、color preference refresh picture automatically
- fix some mp4 can't smoothly play bug #64
- FSPlayer support async relese  by default #70
- improve rotate animation experience #76
- deprecate initWithContentURL and initWithMoreContent API #78

tag 1.0.3
--------------------------------
- support give up setup AudioSession on iOS platform #60
- support async destroy player when set player to nil even though not call shutdown
- improve playveiw animation
- add g726le and g726be decoders
- fix videotoolbox can't decode some h264 video bug
- rename subtitle option to subtitle_mix
- support custom audio rendering
- support get video-master diff
- add libwebp decoder
- add webp demuxer for animated webp images
- fix removeFromSuperview triggered reshape crash when use OpenGL backend
- fix the display of PNG images with transparency channels

tag 1.0.2
--------------------------------

- upgrade FFmpeg to 7.1.1
- upgrade openssl to 3.5.0
- add dvdnav dependency
- fix some hls/ts can’t use videotoolbox accel bug
- fix shutdown crash when use OpenGL backend
- fix snapshot not keep video rational bug when use metal backend 

tag 1.0.1
--------------------------------

- fix dash file error "unterminated entity reference" #7
- example abandon CocoaPods
- support choose audio channel(left,right,stereo)
- support fast record video
- fix metal maybe display pink frame bug

tag 1.0.0
--------------------------------

- use FFmpeg n6.1.1
- the bdmv detection time is saved and detection in read_thread
- fix opengl display first PIX_FMT_PAL8 subtitle bug
- fix ijkio eof bug
- max-buffer-size increate to 500MB
- fix ass subtitle bottom margin bug
