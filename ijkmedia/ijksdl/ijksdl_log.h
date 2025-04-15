/*****************************************************************************
 * ijksdl_log.h
 *****************************************************************************
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
 * License along with FSPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#ifndef FSSDL__IJKSDL_LOG_H
#define FSSDL__IJKSDL_LOG_H

#include <stdio.h>

#ifdef __ANDROID__

#include <android/log.h>
#include "ijksdl_extra_log.h"

#define FS_LOG_UNKNOWN     ANDROID_LOG_UNKNOWN
#define FS_LOG_DEFAULT     ANDROID_LOG_DEFAULT

#define FS_LOG_VERBOSE     ANDROID_LOG_VERBOSE
#define FS_LOG_DEBUG       ANDROID_LOG_DEBUG
#define FS_LOG_INFO        ANDROID_LOG_INFO
#define FS_LOG_WARN        ANDROID_LOG_WARN
#define FS_LOG_ERROR       ANDROID_LOG_ERROR
#define FS_LOG_FATAL       ANDROID_LOG_FATAL
#define FS_LOG_SILENT      ANDROID_LOG_SILENT

#ifdef EXTRA_LOG_PRINT
#define VLOG(level, TAG, ...)    ffp_log_extra_vprint(level, TAG, __VA_ARGS__)
#define ALOG(level, TAG, ...)    ffp_log_extra_print(level, TAG, __VA_ARGS__)
#else
#define VLOG(level, TAG, ...)    ((void)__android_log_vprint(level, TAG, __VA_ARGS__))
#define ALOG(level, TAG, ...)    ((void)__android_log_print(level, TAG, __VA_ARGS__))
#endif

#else

#define FS_LOG_UNKNOWN     0
#define FS_LOG_DEFAULT     1

#define FS_LOG_VERBOSE     2
#define FS_LOG_DEBUG       3
#define FS_LOG_INFO        4
#define FS_LOG_WARN        5
#define FS_LOG_ERROR       6
#define FS_LOG_FATAL       7
#define FS_LOG_SILENT      8

#ifdef __APPLE__

#include "ijksdl_extra_log.h"

#define VLOG(level, TAG, ...)    ffp_apple_log_extra_vprint(level, TAG, __VA_ARGS__)
#define ALOG(level, TAG, ...)    ffp_apple_log_extra_print(level, TAG, __VA_ARGS__)

#else

#define VLOG(level, TAG, ...)    ((void)vprintf(__VA_ARGS__))
#define ALOG(level, TAG, ...)    ((void)printf(__VA_ARGS__))

#endif

#endif

#define FS_LOG_TAG "FSPlayer"

#define VLOGV(...)  VLOG(FS_LOG_VERBOSE,   FS_LOG_TAG, __VA_ARGS__)
#define VLOGD(...)  VLOG(FS_LOG_DEBUG,     FS_LOG_TAG, __VA_ARGS__)
#define VLOGI(...)  VLOG(FS_LOG_INFO,      FS_LOG_TAG, __VA_ARGS__)
#define VLOGW(...)  VLOG(FS_LOG_WARN,      FS_LOG_TAG, __VA_ARGS__)
#define VLOGE(...)  VLOG(FS_LOG_ERROR,     FS_LOG_TAG, __VA_ARGS__)

#define ALOGV(...)  ALOG(FS_LOG_VERBOSE,   FS_LOG_TAG, __VA_ARGS__)
#define ALOGD(...)  ALOG(FS_LOG_DEBUG,     FS_LOG_TAG, __VA_ARGS__)
#define ALOGI(...)  ALOG(FS_LOG_INFO,      FS_LOG_TAG, __VA_ARGS__)
#define ALOGW(...)  ALOG(FS_LOG_WARN,      FS_LOG_TAG, __VA_ARGS__)
#define ALOGE(...)  ALOG(FS_LOG_ERROR,     FS_LOG_TAG, __VA_ARGS__)
#define LOG_ALWAYS_FATAL(...)   do { ALOGE(__VA_ARGS__); exit(1); } while (0)

#endif
