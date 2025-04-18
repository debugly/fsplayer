/*
 *  ff_subtitle_def.c
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

#include "ff_subtitle_def.h"
#include <memory.h>
#include <stdlib.h>

static FFSubtitleBuffer *_ff_subtitle_buffer_alloc(SDL_Rectangle rect, int component)
{
    if (rect.stride == 0) {
        rect.stride = rect.w * component;
    } else {
        rect.stride *= component;
    }
    
    FFSubtitleBuffer *img = malloc(sizeof(FFSubtitleBuffer));
    bzero(img, sizeof(FFSubtitleBuffer));
    img->rect = rect;
    size_t size = rect.h * rect.stride;
    img->data = calloc(1, size);
    memset(img->data, 0, size);
    img->refCount = 1;
    return img;
}

FFSubtitleBuffer *ff_subtitle_buffer_alloc_rgba32(SDL_Rectangle rect)
{
    return _ff_subtitle_buffer_alloc(rect, 4);
}

FFSubtitleBuffer *ff_subtitle_buffer_alloc_r8(SDL_Rectangle rect)
{
    return _ff_subtitle_buffer_alloc(rect, 1);
}

FFSubtitleBuffer * ff_subtitle_buffer_retain(FFSubtitleBuffer *sb)
{
    if (sb) {
        __atomic_add_fetch(&sb->refCount, 1, __ATOMIC_RELEASE);
    }
    return sb;
}

void ff_subtitle_buffer_release(FFSubtitleBuffer **sbp)
{
    if (sbp) {
        FFSubtitleBuffer *sb = *sbp;
        if (sb) {
            if (__atomic_add_fetch(&sb->refCount, -1, __ATOMIC_RELEASE) == 0) {
                free(sb->data);
                free(sb);
            }
            *sbp = NULL;
        }
    }
}

int isFFSubtitleBufferArrayDiff(FFSubtitleBufferPacket *a1, FFSubtitleBufferPacket *a2)
{
    if (a1 == a2) {
        return 0;
    }
    
    if (!a1 || !a2) {
        return 1;
    }
    
    if (a1->len != a2->len) {
        return 1;
    }
    
    int len = a1->len > a2->len ? a1->len : a2->len;
    for (int i = 0; i < len; i++) {
        FFSubtitleBuffer *h1 = a1->e[i];
        FFSubtitleBuffer *h2 = a2->e[i];
        if (h1 != h2) {
            return 1;
        } else if (h1 == NULL) {
            return 0;
        } else {
            continue;
        }
    }
    return 0;
}

void FreeSubtitleBufferArray(FFSubtitleBufferPacket *a)
{
    if (a) {
        while (a->len > 0) {
            ff_subtitle_buffer_release(&a->e[--a->len]);
        }
    }
}

void ResetSubtitleBufferArray(FFSubtitleBufferPacket *dst, FFSubtitleBufferPacket *src)
{
    if (!dst) {
        return;
    }
    FreeSubtitleBufferArray(dst);
    
    if (!src) {
        return;
    }
    
    int i = 0;
    while (dst->len <= SUB_REF_MAX_LEN && i < src->len) {
        dst->e[dst->len++] = ff_subtitle_buffer_retain(src->e[i++]);
    }
    dst->scale = src->scale;
    dst->bottom_margin = src->bottom_margin;
    dst->width = src->width;
    dst->height = src->height;
    dst->isAss = src->isAss;
}
