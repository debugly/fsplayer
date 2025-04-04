/*****************************************************************************
 * ijksdl_gpu.h
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


#ifndef ijksdl_gpu_h
#define ijksdl_gpu_h

#include "ijksdl_rectangle.h"

typedef enum : int {
    SDL_TEXTURE_FMT_BRGA = 1,   //for normal texture, is a rectangle texture.
    SDL_TEXTURE_FMT_A8          //just for palettized RGB (PIX_FMT_PAL8), is a texture2D.
} SDL_TEXTURE_FMT;

typedef struct SDL_TextureOverlay SDL_TextureOverlay;
typedef struct SDL_TextureOverlay {
    void *opaque;
    int w;
    int h;
    SDL_TEXTURE_FMT fmt;
    float scale;
    SDL_Rectangle dirtyRect;
    int changed;
    int refCount;
    uint32_t palette[256];//for SDL_TEXTURE_FMT_A8 fmt
    void (*replaceRegion)(SDL_TextureOverlay *overlay, SDL_Rectangle r, void *pixels);
    void*(*getTexture)(SDL_TextureOverlay *overlay);
    void (*clearDirtyRect)(SDL_TextureOverlay *overlay);
    void (*dealloc)(SDL_TextureOverlay *overlay);
} SDL_TextureOverlay;

SDL_TextureOverlay * SDL_TextureOverlay_Retain(SDL_TextureOverlay *t);
void SDL_TextureOverlay_Release(SDL_TextureOverlay **tp);

typedef struct SDL_GPU SDL_GPU;

typedef struct SDL_FBOOverlay SDL_FBOOverlay;
typedef struct SDL_FBOOverlay {
    void *opaque;
    int w;
    int h;
    void (*clear)(SDL_FBOOverlay *overlay);
    void (*beginDraw)(SDL_GPU *gpu, SDL_FBOOverlay *overlay, int ass);
    void (*drawTexture)(SDL_GPU *gpu, SDL_FBOOverlay *foverlay, SDL_TextureOverlay *toverlay, SDL_Rectangle frame);
    void (*endDraw)(SDL_GPU *gpu, SDL_FBOOverlay *overlay);
    SDL_TextureOverlay *(*getTexture)(SDL_FBOOverlay *overlay);
    void (*dealloc)(SDL_FBOOverlay *overlay);
} SDL_FBOOverlay;

void SDL_FBOOverlayFreeP(SDL_FBOOverlay **poverlay);

typedef struct SDL_GPU {
    void *opaque;
    SDL_TextureOverlay *(*createTexture)(SDL_GPU *gpu, int w, int h, SDL_TEXTURE_FMT fmt, const void *pixels);
    SDL_FBOOverlay *(*createFBO)(SDL_GPU *gpu, int w, int h);
    void (*dealloc)(SDL_GPU *gpu);
} SDL_GPU;

void SDL_GPUFreeP(SDL_GPU **pgpu);

typedef enum : int {
    IMG_FORMAT_RGBA,
    IMG_FORMAT_BGRA,
} IMG_FORMAT;

void SaveIMGToFile(uint8_t *data,int width,int height,IMG_FORMAT format, char *tag, int pts);


#endif /* ijksdl_gpu_h */
