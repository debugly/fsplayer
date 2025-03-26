/*
 * ff_ffplaye_debug.h
 *
 * Copyright (c) 2015 Bilibili
 * Copyright (c) 2015 Zhang Rui <bbcallen@gmail.com>
 * Copyright (c) 2019 debugly <qianlongxu@gmail.com>
 *
 * This file is part of FSPlayer.
 *
 * FSPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * FSPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#ifndef FFPLAY__FF_FFPLAY_DEBUG_H
#define FFPLAY__FF_FFPLAY_DEBUG_H

#define FFP_XPS_PERIOD (3)

#define FFP_SHOW_VPS_DPS            (0)
#define FFP_SHOW_VFPS_FFPLAY        (FFP_SHOW_VPS_DPS)
#define FFP_SHOW_VDPS_AVCODEC       (FFP_SHOW_VPS_DPS)
#define FFP_SHOW_VDPS_VIDEOTOOLBOX  (FFP_SHOW_VPS_DPS)
#define FFP_SHOW_VDPS_MEDIACODEC    (FFP_SHOW_VPS_DPS)

// #define FFP_SHOW_AUDIO_DELAY
// #define FFP_SHOW_DEMUX_CACHE
// #define FFP_SHOW_BUF_POS
//#define FFP_SHOW_SYNC_CLOCK
// #define FFP_NOTIFY_BUF_TIME
// #define FFP_NOTIFY_BUF_BYTES

// #define FFP_SHOW_VTB_IN_DECODING
// #define FFP_VTB_DISABLE_OUTPUT

// #define FFP_SHOW_AMC_DROPS
// #define FFP_AMC_DISABLE_OUTPUT

// #define FFP_AVFILTER_PLAYBACK_RATE
//#define FFP_MONKEY_DEBUG
#ifdef FFP_MONKEY_DEBUG
#define monkey_log(fmt, ...) av_log(NULL, AV_LOG_INFO,fmt,__VA_ARGS__)
#else
#define monkey_log(fmt, ...)
#endif

#endif
