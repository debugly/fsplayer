/*****************************************************************************
 * ijksdl_extra_log.h
 *****************************************************************************
 *
 * Copyright (c) 2017 Bilibili
 * copyright (c) 2017 Raymond Zheng <raymondzheng1412@gmail.com>
 *
 * This file is part of ijkPlayer.
 *
 * ijkPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * ijkPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#ifndef FSSDL__IJKSDL_EXTRA_LOG_H
#define FSSDL__IJKSDL_EXTRA_LOG_H

#ifdef __ANDROID__
#include <android/log.h>

void ffp_log_extra_print(int level, const char *tag, const char *fmt, ...);
void ffp_log_extra_vprint(int level, const char *tag, const char *fmt, va_list ap);

#elif defined __APPLE__

void ffp_apple_log_extra_print(int level, const char *tag, const char *fmt, ...);
void ffp_apple_log_extra_vprint(int level, const char *tag, const char *fmt, va_list ap);

#endif

#endif  // FSSDL__IJKSDL_EXTRA_LOG_H
