/*****************************************************************************
 * ijksdl_rectangle.h
 *****************************************************************************
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

#ifndef ijksdl_rectangle_h
#define ijksdl_rectangle_h

#include <stdio.h>

// 定义矩形结构体
typedef struct SDL_Rectangle{
    int x, y; // 左上角坐标
    int w, h; //
    int stride;
} SDL_Rectangle;

int isZeroRectangle(SDL_Rectangle rect);
// 计算两个矩形的并集
SDL_Rectangle SDL_union_rectangle(SDL_Rectangle rect1, SDL_Rectangle rect2);

#define SDL_Zero_Rectangle (SDL_Rectangle){0,0,0,0}

#endif /* ijksdl_rectangle_h */
