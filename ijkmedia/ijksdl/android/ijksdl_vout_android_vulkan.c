/*****************************************************************************
 * ijksdl_vout_android_vulkan.c
 *****************************************************************************
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
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FSPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include "ijksdl_vout_android_vulkan.h"

#include <assert.h>
#include <jni.h>
#include <android/native_window_jni.h>

#include "ijksdl/ijksdl_vout_internal.h"
#include "ijkplayer/ff_ffplay_def.h"
#include "vulkan/fs_vulkan_renderer.h"

struct SDL_Vout_Opaque {
    FSVulkanRenderer *renderer;
    ANativeWindow *native_window;
};

static void vout_overlay_free_l(SDL_VoutOverlay *overlay)
{
    SDL_VoutOverlay_FreeInternal(overlay);
}

/* 空壳 overlay 的 no-op 回调：display 直接消费 Frame->frame，不经过 overlay 的 pixels */
static int overlay_noop_lock(SDL_VoutOverlay *overlay)
{
    (void)overlay;
    return 0;
}

static int overlay_noop_unlock(SDL_VoutOverlay *overlay)
{
    (void)overlay;
    return 0;
}

static int overlay_noop_fill_frame(SDL_VoutOverlay *overlay, const AVFrame *frame)
{
    (void)overlay;
    (void)frame;
    return 0;
}

static SDL_VoutOverlay *vout_create_overlay(int width, int height, int src_format, SDL_Vout *vout)
{
    (void)width; (void)height; (void)src_format; (void)vout;
    /* 最小可播放：display 路径直接消费 Frame->frame，overlay 仅作为 vp->bmp 的非空标记 */
    SDL_VoutOverlay *overlay = SDL_VoutOverlay_CreateInternal(0);
    if (overlay) {
        overlay->free_l = vout_overlay_free_l;
        overlay->lock = overlay_noop_lock;
        overlay->unlock = overlay_noop_unlock;
        overlay->func_fill_frame = overlay_noop_fill_frame;
    }
    return overlay;
}

static void vout_free_l(SDL_Vout *vout)
{
    if (!vout)
        return;

    SDL_Vout_Opaque *opaque = vout->opaque;
    if (opaque) {
        if (opaque->renderer) {
            fs_vulkan_renderer_destroy(opaque->renderer);
            opaque->renderer = NULL;
        }
        if (opaque->native_window) {
            ANativeWindow_release(opaque->native_window);
            opaque->native_window = NULL;
        }
    }

    SDL_Vout_FreeInternal(vout);
}

static int vout_display_overlay_l(SDL_Vout *vout, const Frame *frame, SDL_TextureOverlay *sub_overlay)
{
    (void)sub_overlay;

    SDL_Vout_Opaque *opaque = vout->opaque;
    if (!opaque || !opaque->renderer) {
        ALOGE("vout_display_overlay_l: no vulkan renderer\n");
        return -1;
    }

    if (!frame || !frame->frame) {
        ALOGE("vout_display_overlay_l: no video frame\n");
        return -1;
    }

    AVFrame *av_frame = frame->frame;
    int disp_w = frame->disp_w > 0 ? frame->disp_w : av_frame->width;
    int disp_h = frame->disp_h > 0 ? frame->disp_h : av_frame->height;
    int rotate = frame->auto_z_rotate_degrees;
    int sar_num = frame->sar.num;
    int sar_den = frame->sar.den;

    return fs_vulkan_renderer_display(opaque->renderer, av_frame,
                                      disp_w, disp_h, rotate, sar_num, sar_den);
}

static int vout_display_overlay(SDL_Vout *vout, const Frame *frame, SDL_TextureOverlay *sub_overlay)
{
    SDL_LockMutex(vout->mutex);
    int retval = vout_display_overlay_l(vout, frame, sub_overlay);
    SDL_UnlockMutex(vout->mutex);
    return retval;
}

SDL_Vout *SDL_VoutAndroid_CreateForVulkan(void)
{
    SDL_Vout *vout = SDL_Vout_CreateInternal(sizeof(SDL_Vout_Opaque));
    if (!vout)
        return NULL;

    SDL_Vout_Opaque *opaque = vout->opaque;
    opaque->renderer = fs_vulkan_renderer_create();
    if (!opaque->renderer) {
        ALOGE("SDL_VoutAndroid_CreateForVulkan: create renderer failed\n");
        SDL_Vout_FreeInternal(vout);
        return NULL;
    }

    vout->create_overlay = vout_create_overlay;
    vout->free_l = vout_free_l;
    vout->display_overlay = vout_display_overlay;

    return vout;
}

void SDL_VoutAndroid_SetAndroidSurface(JNIEnv *env, SDL_Vout *vout, jobject android_surface)
{
    if (!vout || !vout->opaque)
        return;

    SDL_LockMutex(vout->mutex);
    SDL_Vout_Opaque *opaque = vout->opaque;

    if (opaque->native_window) {
        ANativeWindow_release(opaque->native_window);
        opaque->native_window = NULL;
    }

    if (android_surface) {
        opaque->native_window = ANativeWindow_fromSurface(env, android_surface);
    }

    fs_vulkan_renderer_set_surface(opaque->renderer, opaque->native_window);

    SDL_UnlockMutex(vout->mutex);
}

int SDL_VoutAndroid_IsMediaCodecSupported(SDL_Vout *vout)
{
    if (!vout || !vout->opaque)
        return 0;

    return fs_vulkan_renderer_is_mediacodec_supported(vout->opaque->renderer);
}

jobject SDL_VoutAndroid_GetMediaCodecSurface(JNIEnv *env, SDL_Vout *vout)
{
    if (!vout || !vout->opaque)
        return NULL;

    return fs_vulkan_renderer_get_mediacodec_surface(env, vout->opaque->renderer);
}
