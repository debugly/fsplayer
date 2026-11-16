[简体中文](all-feature.md) · **English**

## Features

- LGPL v2.1 or later
- FFmpeg 8.1.2
- Pass options through to FFmpeg
- Query the download speed
- Query the preload progress
- Read basic media information such as audio sample rate, channel count, and duration, or video width, height, frame rate, and duration
- Get first-frame decode and render timings
- Support for protocols including `file`, `http`, `https`, `udp`, `rtmp`, `rtp`, `rtsp`, `bluray`, `smb`, and `ftp`
- Configure HTTP timeouts, retries on failure, User-Agent, Cookie, Referer, Origin, and other options. HLS playlists (`.m3u8`) can pass these settings through to their transport stream segment requests
- HLS live and on-demand playback
- AV1 and uavs3 decoders
- Display embedded cover art during audio playback
- Image playback
- Accurate seeking
- Select software or hardware decoding
- Run multiple player instances
- Seek and resume playback after reaching the end of the file (EOF)
- Faster playback resumption after seeking with the `file` protocol
- Playback of encrypted audio and video
- Subtitle support
  - Text subtitles (SRT, VTT, ASS)
  - Bitmap subtitles (DVBSub, DVDSub, PGS, IDX/SUB)
  - Embedded and external subtitles
  - Adjustable subtitle delay
  - ASS subtitle effects
  - Custom text subtitle styling
- Loop playback
- Switch audio tracks
- Adjust audio track delay
- Capture screenshots at any time (JPEG, PNG, TIFF)
- Set the video display aspect ratio
- Set video rotation (0°, 90°, 180°, or 270°)
- Flip video horizontally or vertically
- Configure video mirroring mode
- Set the video background color (black by default)
- Adjust video saturation, brightness, and contrast
- Render video to multiple views simultaneously
- Access PCM audio data in real time
- Use a custom rendering view
- Support for 4K, HDR, HDR10, HDR10+, and Dolby Vision, with Dolby Vision Profile 5 in the Pro version
- Automatically identify ISO image contents (Blu-ray, DVD, or standard video files)
- Seek forward in MPEG-TS video without visual artifacts
- Play ISO images and BDMV folders over network protocols
- Select a specific channel for stereo audio playback
- Retrieve the currently displayed video frame
- Record video and save playable recordings to the photo library on iOS
- Play animated WebP images
- Use a custom audio renderer
- Receive buffering progress notifications
- Release the player asynchronously, including when `shutdown` is omitted
- Opt out of player-managed `AudioSession` state
- Improved animations when the player view rotates
- Play HEIC images stored as tiled grids
- Gaussian blur backgrounds
- Activate HDR display mode during HDR video playback
- Continue watching and seeking after audio ends when the video track is longer
- Switch between software and hardware decoding without restarting the player
- Enable video filters, including deinterlacing with software decoding
- Release the player synchronously (asynchronous by default)

## Recent additions

- Transparent video and backgrounds, allowing underlying views to show through where no video is drawn
- Automatically enable hardware decoding for AV1
- Android support 5.0
- Android add OpenGL ES3 renderer
