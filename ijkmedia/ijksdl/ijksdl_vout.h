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
    SDL_Class               *opaque_class;
    SDL_VoutOverlay_Opaque  *opaque;

    void    (*free_l)(SDL_VoutOverlay *overlay);
    int     (*lock)(SDL_VoutOverlay *overlay);
    int     (*unlock)(SDL_VoutOverlay *overlay);
    void    (*unref)(SDL_VoutOverlay *overlay);

    int     (*func_fill_frame)(SDL_VoutOverlay *overlay, const AVFrame *frame);
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
#endif
