/*
 * ijksdl_image_convert_sws.c
 *
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
 */

#include "ijksdl_image_convert.h"

/*
 * 安卓最小可播放：不使用 libyuv（abi_all/image_convert.c 依赖 libyuv）。
 * 直接返回非 0，让 SDL_VoutConvertFrame fallback 到 swscale 做像素格式转换。
 * 软解 YUV420P -> YUV420P 时 dst==src，根本不会走到这里。
 */
int ijk_image_convert(int width, int height,
    enum AVPixelFormat dst_format, uint8_t **dst_data, int *dst_linesize,
    enum AVPixelFormat src_format, const uint8_t **src_data, const int *src_linesize)
{
    (void)width;
    (void)height;
    (void)dst_format;
    (void)dst_data;
    (void)dst_linesize;
    (void)src_format;
    (void)src_data;
    (void)src_linesize;
    return -1;
}
