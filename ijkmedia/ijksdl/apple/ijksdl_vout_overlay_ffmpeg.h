/*****************************************************************************
 * ijksdl_vout_overlay_ffmpeg.h
 *****************************************************************************
 *
 * Copyright (c) 2013 Bilibili
 * Copyright (c) 2013 Zhang Rui <bbcallen@gmail.com>
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
 * License along with FSPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#ifndef FSSDL__FFMPEG__IJKSDL_VOUT_OVERLAY_FFMPEG_H
#define FSSDL__FFMPEG__IJKSDL_VOUT_OVERLAY_FFMPEG_H

#include "ijksdl/ijksdl_stdinc.h"
#include "ijksdl/ijksdl_vout.h"
#include "ijksdl_inc_ffmpeg.h"

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

SDL_VoutOverlay *SDL_VoutFFmpeg_CreateOverlay(int width, int height, int src_format, SDL_Vout *vout);
CVPixelBufferRef SDL_VoutFFmpeg_GetCVPixelBufferRef(SDL_VoutOverlay *overlay);

#endif
