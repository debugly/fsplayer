/*
 * Copyright (c) 2016 Bilibili
 * Copyright (c) 2016 Zhang Rui <bbcallen@gmail.com>
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

//https://github.com/lemenkov/libyuv/blob/6900494d90ae095d44405cd4cc3f346971fa69c9/source/row_common.cc#L2

#ifndef _COLOR_MATRIX_HEADER_
#define _COLOR_MATRIX_HEADER_
typedef enum : int {
    YUV_2_RGB_Color_Matrix_None,
    YUV_2_RGB_Color_Matrix_BT601,
    YUV_2_RGB_Color_Matrix_BT709,
    YUV_2_RGB_Color_Matrix_BT2020
} YUV_2_RGB_Color_Matrix;

typedef enum : int {
    FS_Color_Transfer_Function_LINEAR,
    FS_Color_Transfer_Function_PQ,
    FS_Color_Transfer_Function_HLG,
} FS_Color_Transfer_Function;

//Full Range YUV to RGB reference
const GLfloat *FS_GLES2_getColorMatrix_bt2020(void);
const GLfloat *FS_GLES2_getColorMatrix_bt709(void);
const GLfloat *FS_GLES2_getColorMatrix_bt601(void);
const GLfloat *FS_GLES2_getColorMatrix(YUV_2_RGB_Color_Matrix type);
#endif
