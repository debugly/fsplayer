//
//  ijksdl_rectangle.h
//  FSMediaPlayerKit
//
//  Created by Reach Matt on 2024/3/27.
//

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
