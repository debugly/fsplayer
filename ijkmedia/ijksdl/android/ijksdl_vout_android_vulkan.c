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
#include "ijksdl/ijksdl_gpu.h"
#include "ijksdl/ffmpeg/ijksdl_vout_overlay_ffmpeg.h"
#include "ijkplayer/ff_ffplay_def.h"
#include "vulkan/fs_vulkan_renderer.h"
#include "vulkan/ijksdl_gpu_vulkan.h"

struct SDL_Vout_Opaque {
    FSVulkanRenderer *renderer;
    SDL_GPU *gpu;                 /* 字幕用的纹理/FBO 层（跑在同一个 Vulkan device 上）*/
    ANativeWindow *native_window;
};

/* display 直接消费 Frame->frame，overlay 只提供锁和生命周期 */
static SDL_VoutOverlay *vout_create_overlay(int width, int height, int src_format, SDL_Vout *vout)
{
    return SDL_VoutFFmpeg_CreateOverlay(width, height, src_format, vout);
}

static void vout_free_l(SDL_Vout *vout)
{
    if (!vout)
        return;

    SDL_Vout_Opaque *opaque = vout->opaque;
    if (opaque) {
        /*
         * GPU（字幕纹理层）的壳归 ffplayer 所有（ffp_destroy 里 SDL_GPUFreeP），
         * 但它的 Vulkan 资源必须赶在 renderer/device 之前释放。
         */
        if (opaque->gpu) {
            SDL_VulkanGPU_DetachDevice(opaque->gpu);
        }
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
    SDL_Vout_Opaque *opaque = vout->opaque;
    if (!opaque || !opaque->renderer) {
        ALOGE("vout_display_overlay_l: no vulkan renderer\n");
        return -1;
    }

    /*
     * 字幕叠加：字幕线程已经用 opaque->gpu（SDL_GPU）把这一帧的字幕画进纹理
     * 或 FBO，这里只是把纹理交给渲染器，由渲染器在视频之上做预乘 alpha 混合。
     * 引用由调用方（字幕层）持有，vout 不接管。
     */
    fs_vulkan_renderer_set_sub_overlay(opaque->renderer, sub_overlay);

    AVFrame *av_frame = (frame && frame->frame) ? frame->frame : NULL;
    if (!av_frame) {
        /* 没有视频帧（如只放音频）：只刷一帧字幕，不报错 */
        ALOGV("vout_display_overlay_l: subtitle only\n");
        fs_vulkan_renderer_display_sub_overlay(opaque->renderer);
        return 0;
    }

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

    /*
     * 字幕用的 SDL_GPU：和渲染器共用同一个 Vulkan device/queue，
     * 这样字幕纹理不用跨设备拷贝。失败也不致命（只影响字幕）。
     */
    opaque->gpu = SDL_VulkanGPU_Create(fs_vulkan_renderer_context(opaque->renderer));
    if (!opaque->gpu) {
        ALOGW("SDL_VoutAndroid_CreateForVulkan: subtitle gpu unavailable\n");
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

void SDL_VoutAndroid_SetScalingMode(SDL_Vout *vout, int mode)
{
    if (!vout || !vout->opaque || !vout->opaque->renderer)
        return;

    fs_vulkan_renderer_set_scaling_mode(vout->opaque->renderer, mode);
}

/*
 * 注意：这里不拿 vout 的锁。快照要等渲染线程把下一帧画出来，而渲染线程显示时
 * 也要拿这把锁，持锁等待就死锁了；renderer 指针本身在 vout 生命周期内是稳定的。
 */
void SDL_VoutAndroid_SetBackgroundImage(SDL_Vout *vout, const void *pixels, int width, int height)
{
    if (!vout || !vout->opaque || !vout->opaque->renderer)
        return;

    fs_vulkan_renderer_set_background_image(vout->opaque->renderer, pixels, width, height);
}

void SDL_VoutAndroid_SetBackgroundBlur(SDL_Vout *vout, int iterations, float sigma)
{
    if (!vout || !vout->opaque || !vout->opaque->renderer)
        return;

    fs_vulkan_renderer_set_background_blur(vout->opaque->renderer, iterations, sigma);
}

int SDL_VoutAndroid_TakeSnapshot(SDL_Vout *vout, int type,
                                 int *out_w, int *out_h, void **out_pixels)
{
    if (!vout || !vout->opaque || !vout->opaque->renderer)
        return -1;

    return fs_vulkan_renderer_take_snapshot(vout->opaque->renderer, type,
                                            out_w, out_h, out_pixels);
}

jobject SDL_VoutAndroid_GetMediaCodecSurface(JNIEnv *env, SDL_Vout *vout)
{
    if (!vout || !vout->opaque)
        return NULL;

    return fs_vulkan_renderer_get_mediacodec_surface(env, vout->opaque->renderer);
}

SDL_GPU *SDL_VoutAndroid_GetGPU(SDL_Vout *vout)
{
    if (!vout || !vout->opaque)
        return NULL;

    /* 借用：所有权在 ffplayer，vout 只负责销毁前 detach（见 vout_free_l） */
    return vout->opaque->gpu;
}