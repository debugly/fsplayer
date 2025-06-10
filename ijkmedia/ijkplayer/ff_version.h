/*
 * ff_version.h
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

#ifndef ff_version_h
#define ff_version_h

#include "libavformat/version_major.h"

#define IS_FFMPEG_7             (LIBAVFORMAT_VERSION_MAJOR >= 61)
#define IS_LESS_THAN_FFMPEG_7   (LIBAVFORMAT_VERSION_MAJOR < 61)
#define IS_FFMPEG_6             (LIBAVFORMAT_VERSION_MAJOR >= 60)
#define IS_FFMPEG_5             (LIBAVFORMAT_VERSION_MAJOR >= 59)
#define IS_FFMPEG_4             (LIBAVFORMAT_VERSION_MAJOR >= 58)

#endif /* ff_version_h */
