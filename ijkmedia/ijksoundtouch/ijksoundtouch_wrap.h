/*
 * ijksoundtouch_wrap.h
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
 */

#ifndef IJKSOUNDTOUCHWRAP_H
#define IJKSOUNDTOUCHWRAP_H

#include <stdint.h>

void* ijk_soundtouch_create();
int ijk_soundtouch_translate(void *handle, short* data, float speed, float pitch, int len, int bytes_per_sample, int n_channel, int n_sampleRate);
void ijk_soundtouch_destroy(void *handle);

#endif /* IJKSOUNDTOUCHWRAP_H */
