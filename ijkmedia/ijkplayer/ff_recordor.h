/*
* ff_recordor.h
*
* Copyright (c) 2025 debugly <qianlongxu@gmail.com>
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

/* record video*/

#ifndef ff_recordor_h
#define ff_recordor_h

#include <stdio.h>
struct FFPlayer;
struct AVPacket;
struct AVFormatContext;

int ff_create_recordor(void **out_ffr, const char *file_name, const struct AVFormatContext *ifmt_ctx, int audio_stream, int video_stream);
int ff_start_recordor(void *ffr);
int ff_write_recordor(void *ffr, struct AVPacket *packet);
int ff_stop_recordor(void *ffr);
void ff_destroy_recordor(void **ffr);

#endif /* ff_recordor_h */
