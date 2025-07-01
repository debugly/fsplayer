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
