/*
 *  ff_subtitle_ex.h
 *
 * Copyright (c) 2022 debugly <qianlongxu@gmail.com>
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


#ifndef ff_subtitle_ex_h
#define ff_subtitle_ex_h

#include <stdio.h>

typedef struct FFExSubtitle FFExSubtitle;
typedef struct PacketQueue PacketQueue;
typedef struct AVStream AVStream;
typedef struct AVDictionary AVDictionary;

int exSub_open_input(FFExSubtitle **subp, PacketQueue * pktq, const char *file_name, float startTime, AVDictionary *opts);
void exSub_start_read(FFExSubtitle *sub);
void exSub_close_input(FFExSubtitle **sub);
AVStream * exSub_get_stream(FFExSubtitle *sub);
int exSub_get_stream_id(FFExSubtitle *sub);
//when return zero means succ;
int exSub_seek_to(FFExSubtitle *sub, float sec);

#endif /* ff_subtitle_ex_h */
