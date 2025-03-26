/*****************************************************************************
 * ijksdl_fourcc.h
 *****************************************************************************
 *
 * Copyright (c) 2013 Bilibili
 * Copyright (c) 2013 Zhang Rui <bbcallen@gmail.com>
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
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#ifndef FSSDL__IJKSDL_FOURCC_H
#define FSSDL__IJKSDL_FOURCC_H

#include "ijksdl_stdinc.h"
#include "ijksdl_endian.h"

#if SDL_BYTEORDER == SDL_LIL_ENDIAN
#   define SDL_FOURCC(a, b, c, d) \
        (((uint32_t)a) | (((uint32_t)b) << 8) | (((uint32_t)c) << 16) | (((uint32_t)d) << 24))
#   define SDL_TWOCC(a, b) \
        ((uint16_t)(a) | ((uint16_t)(b) << 8))
#else
#   define SDL_FOURCC(a, b, c, d) \
        (((uint32_t)d) | (((uint32_t)c) << 8) | (((uint32_t)b) << 16) | (((uint32_t)a) << 24))
#   define SDL_TWOCC( a, b ) \
        ((uint16_t)(b) | ((uint16_t)(a) << 8))
#endif

/*-
 *  http://www.webartz.com/fourcc/indexyuv.htm
 *  http://www.neuro.sfc.keio.ac.jp/~aly/polygon/info/color-space-faq.html
 *  http://www.fourcc.org/yuv.php
 */

// YUV formats
#define SDL_FCC_YV12        SDL_FOURCC('Y', 'V', '1', '2')  /**< bpp=12, Planar mode: Y + V + U  (3 planes) */
#define SDL_FCC_IYUV        SDL_FOURCC('I', 'Y', 'U', 'V')  /**< bpp=12, Planar mode: Y + U + V  (3 planes) */
#define SDL_FCC_I420        SDL_FOURCC('I', '4', '2', '0')  /**< bpp=12, Planar mode: Y + U + V  (3 planes) color range [16,235]*/
#define SDL_FCC_J420        SDL_FOURCC('J', '4', '2', '0')  /**< bpp=12, Planar mode: Y + U + V  (3 planes) color range [0,255] */
//#define SDL_FCC_I444P10LE   SDL_FOURCC('I', '4', 'A', 'L')

#define SDL_FCC_YUV2        SDL_FOURCC('Y', 'U', 'V', '2')  /**< bpp=16, Packed mode: Y0+U0+Y1+V0 (1 plane) */
#define SDL_FCC_UYVY        SDL_FOURCC('U', 'Y', 'V', 'Y')  /**< bpp=16, Packed mode: U0+Y0+V0+Y1 (1 plane) */
#define SDL_FCC_YVYU        SDL_FOURCC('Y', 'V', 'Y', 'U')  /**< bpp=16, Packed mode: Y0+V0+Y1+U0 (1 plane) */

#define SDL_FCC_NV12        SDL_FOURCC('N', 'V', '1', '2')
#define SDL_FCC_UYVY        SDL_FOURCC('U', 'Y', 'V', 'Y')

// newer
#define SDL_FCC_P010        SDL_FOURCC('P', '0', '1', '0')    /**< bpp=30, like NV12, YUV 4:2:0,10bit */
#define SDL_FCC_P216        SDL_FOURCC('P', '2', '1', '6')    /**< bpp=32, like NV12, YUV 4:2:2,16bit*/
#define SDL_FCC_P416        SDL_FOURCC('P', '4', '1', '6')    /**< bpp=48, like NV12, YUV 4:4:4,16bit*/
#define SDL_FCC_AYUV64      SDL_FOURCC('A', 'Y', '6', '4')    /**< bpp=64,  AYUV 4:4:4,16bit (1 Cr & Cb sample per 1x1 Y & A samples), little-endian with alpha 16bit*/

// RGB formats
#define SDL_FCC_BGR0        SDL_FOURCC('B', 'G', 'R', 0)      /**< bpp=32, BGRXBGRX */
#define SDL_FCC_BGRA        SDL_FOURCC('B', 'G', 'R', 'A')    /**< bpp=32, BGRABGRA */
#define SDL_FCC_ARGB        SDL_FOURCC('A', 'R', 'G', 'B')    /**< bpp=32, ARGBARGB */
#define SDL_FCC_0RGB        SDL_FOURCC('0', 'R', 'G', 'B')    /**< bpp=32, XRGBXRGB */
#define SDL_FCC_RV16        SDL_FOURCC('R', 'V', '1', '6')    /**< bpp=16, RGB565 */
#define SDL_FCC_RV24        SDL_FOURCC('R', 'V', '2', '4')    /**< bpp=24, RGB888 */
#define SDL_FCC_RV32        SDL_FOURCC('R', 'V', '3', '2')    /**< bpp=32, RGBX8888 */

// opaque formats
#define SDL_FCC__AMC        SDL_FOURCC('_', 'A', 'M', 'C')    /**< Android MediaCodec */
#define SDL_FCC__VTB        SDL_FOURCC('V', 'T', 'B', 0xFF)   /**< Apple VideoToolbox */
#define SDL_FCC__FFVTB      SDL_FOURCC('F', 'F', 'V', 'T')    /**< USE FFmpeg decode video,But use Apple VideoToolbox Buffer, So video render same as VTB */
#define SDL_FCC__GLES2      SDL_FOURCC('_', 'E', 'S', '2')    /**< let Vout choose format */

// undefine
#define SDL_FCC_UNDF    SDL_FOURCC('U', 'N', 'D', 'F')    /**< undefined */

enum {
    FS_AV_PIX_FMT__START = 10000,
    FS_AV_PIX_FMT__ANDROID_MEDIACODEC,
};

#endif
