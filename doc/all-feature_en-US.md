[简体中文](all-feature.md) · **English**

## Features

- [x] FFmpeg 8.1.2
- [x] Pass options through to FFmpeg
- [x] Query the download speed
- [x] Query the preload progress
- [x] Read basic media information such as audio sample rate, channel count, and duration, or video width, height, frame rate, and duration
- [x] Get first-frame decode and render timings
- [x] Support for protocols including `file`, `http`, `https`, `udp`, `rtmp`, `rtp`, `rtsp`, `bluray`, `smb`, and `ftp`
- [x] Configure HTTP timeouts, retries on failure, User-Agent, Cookie, Referer, Origin, and other options. HLS playlists (`.m3u8`) can pass these settings through to their transport stream segment requests
- [x] HLS live and on-demand playback
- [x] AV1 and uavs3 decoders
- [x] Display embedded cover art during audio playback
- [x] Image playback
- [x] Accurate seeking
- [x] Select software or hardware decoding
- [x] Run multiple player instances
- [x] Seek and resume playback after reaching the end of the file (EOF)
- [x] Faster playback resumption after seeking with the `file` protocol
- [x] Playback of encrypted audio and video
- [x] Subtitle support
  - [x] Text subtitles (SRT, VTT, ASS)
  - [x] Bitmap subtitles (DVBSub, DVDSub, PGS, IDX/SUB)
  - [x] Embedded and external subtitles
  - [x] Adjustable subtitle delay
  - [x] ASS subtitle effects
  - [x] Custom text subtitle styling
- [x] Loop playback
- [x] Switch audio tracks
- [x] Adjust audio track delay
- [x] Capture screenshots at any time (JPEG, PNG, TIFF)
- [x] Set the video display aspect ratio
- [x] Set video rotation (0°, 90°, 180°, or 270°)
- [x] Flip video horizontally or vertically
- [x] Configure video mirroring mode
- [x] Set the video background color (black by default)
- [x] Adjust video saturation, brightness, and contrast
- [x] Render video to multiple views simultaneously
- [x] Access PCM audio data in real time
- [x] Use a custom rendering view
- [x] Support for 4K, HDR, HDR10, HDR10+, and Dolby Vision, with Dolby Vision Profile 5 in the Pro version
- [x] Automatically identify ISO image contents (Blu-ray, DVD, or standard video files)
- [x] Seek forward in MPEG-TS video without visual artifacts
- [x] Play ISO images and BDMV folders over network protocols
- [x] Select a specific channel for stereo audio playback
- [x] Retrieve the currently displayed video frame
- [x] Record video and save playable recordings to the photo library on iOS
- [x] Play animated WebP images
- [x] Use a custom audio renderer
- [x] Receive buffering progress notifications
- [x] Release the player asynchronously, including when `shutdown` is omitted
- [x] Opt out of player-managed `AudioSession` state
- [x] Improved animations when the player view rotates
- [x] Play HEIC images stored as tiled grids
- [x] Gaussian blur backgrounds
- [x] Activate HDR display mode during HDR video playback
- [x] Continue watching and seeking after audio ends when the video track is longer
- [x] Switch between software and hardware decoding without restarting the player
- [x] Enable video filters, including deinterlacing with software decoding
- [x] Release the player synchronously (asynchronous by default)

## Recent additions

- [x] Transparent video and backgrounds, allowing underlying views to show through where no video is drawn
- [x] Automatically enable hardware decoding for AV1
- [x] Android support
