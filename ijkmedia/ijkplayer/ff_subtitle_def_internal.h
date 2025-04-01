/*
 *  ff_subtitle_def_internal.h
 *
 * Copyright (c) 2024 debugly <qianlongxu@gmail.com>
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


#ifndef ff_subtitle_def_internal_hpp
#define ff_subtitle_def_internal_hpp

#include "ff_subtitle_def.h"
//忽略向上移动的字幕范围 [0-0.75]
#define SUBTITLE_MOVE_WATERMARK 0.75

FFSubtitleBuffer *ff_subtitle_buffer_alloc_rgba32(SDL_Rectangle rect);
FFSubtitleBuffer *ff_subtitle_buffer_alloc_r8(SDL_Rectangle rect);

#endif /* ff_subtitle_def_internal_hpp */
