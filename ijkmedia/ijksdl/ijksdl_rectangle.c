/*****************************************************************************
 * ijksdl_rectangle.c
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
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include "ijksdl_rectangle.h"
#include <assert.h>

int isZeroRectangle(SDL_Rectangle rect)
{
    if (rect.w == 0 && rect.h == 0) {
        return 1;
    }
    return 0;
}

SDL_Rectangle SDL_union_rectangle(SDL_Rectangle rect1, SDL_Rectangle rect2) {
    
    if (isZeroRectangle(rect1)) {
        if (isZeroRectangle(rect2)) {
            return (SDL_Rectangle){0,0,0,0};
        } else {
            return rect2;
        }
    } else if (isZeroRectangle(rect2)) {
        return rect1;
    }
    
    SDL_Rectangle result;
    
    // 计算新矩形的左上角坐标（取两个矩形中最小的 x 和 y 坐标）
    result.x = (rect1.x < rect2.x) ? rect1.x : rect2.x;
    result.y = (rect1.y < rect2.y) ? rect1.y : rect2.y;

    // 计算新矩形的右下角坐标（取两个矩形中最大的 x 和 y 坐标）
    int x1 = rect1.x + rect1.w;
    int y1 = rect1.y + rect1.h;
    
    int x2 = rect2.x + rect2.w;
    int y2 = rect2.y + rect2.h;
    
    result.w = ((x1 > x2) ? x1 : x2) - result.x;
    result.h = ((y1 > y2) ? y1 : y2) - result.y;

    assert(rect2.stride/rect2.w == rect1.stride/rect1.w);
    
    result.stride = result.w * rect2.stride/rect2.w;
    return result;
}
