/*****************************************************************************
 * ijksdl_vout.h
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
 * License along with FSPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#ifndef FSSDL__IJKSDL_VOUT_H
#define FSSDL__IJKSDL_VOUT_H

#include "ijksdl_stdinc.h"
#include "ijksdl_class.h"
#include "ijksdl_mutex.h"
#include "ijksdl_video.h"
#include "ijksdl/ffmpeg/ijksdl_inc_ffmpeg.h"
#include "ijksdl_fourcc.h"

#ifdef __APPLE__
#include <CoreVideo/CVPixelBuffer.h>
#endif

typedef struct SDL_VoutOverlay_Opaque SDL_VoutOverlay_Opaque;
typedef struct SDL_VoutOverlay SDL_VoutOverlay;
struct SDL_VoutOverlay {
    int w; /**< Read-only, avframe's width */
    int h; /**< Read-only, avframe's height */
    Uint32 format; /**< Read-only,on Apple plat is SDL_FCC__VTB or  SDL_FCC__FFVTB; other plat SDL_FCC_I420 */
#ifndef __APPLE__
    Uint8 **pixels; /**< Read-write */
    int planes; /**< Read-only */
#endif
    Uint16 *pitches; /**< in bytes, Read-only */
    
    int is_private;
    float fps;
    int sar_num;
    int sar_den;
    //for auto rotate video
    int auto_z_rotate_degrees;
    int has_alpha;

    /* HEIC tile grid 支持：
     * 当 overlay 处于 tile-grid 模式时 is_tile_grid=1,
     * tile_canvas_w/h 为整张 canvas 的尺寸。
     * 普通单帧播放 is_tile_grid=0, 其余字段忽略。
     */
    int is_tile_grid;
    int tile_canvas_w;
    int tile_canvas_h;

    SDL_Class               *opaque_class;
    SDL_VoutOverlay_Opaque  *opaque;

    void    (*free_l)(SDL_VoutOverlay *overlay);
    int     (*lock)(SDL_VoutOverlay *overlay);
    int     (*unlock)(SDL_VoutOverlay *overlay);
    void    (*unref)(SDL_VoutOverlay *overlay);

    int     (*func_fill_frame)(SDL_VoutOverlay *overlay, const AVFrame *frame);

    /* HEIC tile grid 查询接口（可选实现，NULL 表示不支持）
     *  func_is_tile_pending:  返回 1 表示当前还在累积 tile，上游不应把此帧 push 到渲染队列
     *  func_get_tile_count:   返回已收集到的 tile 数（一般等于 nb_tiles）
     *  func_get_tile_buffers: 取出所有 tile 的 CVPixelBufferRef 及其在 canvas 上的 x/y/w/h
     */
    int     (*func_is_tile_pending)(SDL_VoutOverlay *overlay);
    int     (*func_get_tile_count)(SDL_VoutOverlay *overlay);
#ifdef __APPLE__
    int     (*func_get_tile_buffers)(SDL_VoutOverlay *overlay,
                                     CVPixelBufferRef *out_buffers,
                                     int *out_x, int *out_y,
                                     int *out_w, int *out_h,
                                     int max_count);
#endif
};

typedef struct SDL_Vout_Opaque SDL_Vout_Opaque;
typedef struct SDL_Vout SDL_Vout;
typedef struct SDL_TextureOverlay SDL_TextureOverlay;

struct SDL_Vout {
    SDL_mutex *mutex;
    SDL_Class       *opaque_class;
    SDL_Vout_Opaque *opaque;
    SDL_VoutOverlay *(*create_overlay)(int width, int height, int frame_format, SDL_Vout *vout);
    void (*free_l)(SDL_Vout *vout);
    int (*display_overlay)(SDL_Vout *vout, SDL_VoutOverlay *overlay, SDL_TextureOverlay *sub_overlay);
    Uint32 overlay_format;
    int z_rotate_degrees;
    //convert image
    void *image_converter;
    int cvpixelbufferpool;
};

void SDL_VoutFree(SDL_Vout *vout);
void SDL_VoutFreeP(SDL_Vout **pvout);
int  SDL_VoutDisplayYUVOverlay(SDL_Vout *vout, SDL_VoutOverlay *overlay, SDL_TextureOverlay *sub_overlay);
//convert a frame use vout. not free outFrame,when free vout the outFrame will free. if convert failed return greater then 0.
int  SDL_VoutConvertFrame(SDL_Vout *vout,int dst_format, const AVFrame *inFrame, const AVFrame **outFrame);

SDL_VoutOverlay *SDL_Vout_CreateOverlay(int width, int height, int src_format, SDL_Vout *vout);

int     SDL_VoutLockYUVOverlay(SDL_VoutOverlay *overlay);
int     SDL_VoutUnlockYUVOverlay(SDL_VoutOverlay *overlay);
void    SDL_VoutFreeYUVOverlay(SDL_VoutOverlay *overlay);
void    SDL_VoutUnrefYUVOverlay(SDL_VoutOverlay *overlay);
int     SDL_VoutFillFrameYUVOverlay(SDL_VoutOverlay *overlay, const AVFrame *frame);

/* HEIC tile grid: 查询 overlay 是否还在累积 tile（未攒齐不要 push） */
int     SDL_VoutOverlay_IsTilePending(SDL_VoutOverlay *overlay);
/* HEIC tile grid: 已收集的 tile 数 */
int     SDL_VoutOverlay_GetTileCount(SDL_VoutOverlay *overlay);
#ifdef __APPLE__
/* HEIC tile grid: 批量取 tile CVPixelBufferRef 及位置（调用方负责 CVPixelBufferRetain/Release） */
int     SDL_VoutOverlay_GetTileCVPixelBuffers(SDL_VoutOverlay *overlay,
                                              CVPixelBufferRef *out_buffers,
                                              int *out_x, int *out_y,
                                              int *out_w, int *out_h,
                                              int max_count);
#endif
#endif
