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

#if IS_TILEGRID_HEIC_ENABLED
#include "ijkplayer/ff_heic_tile.h"
#endif

struct SDL_Vout_Opaque {
    FSVulkanRenderer *renderer;
    SDL_GPU *gpu;                 /* 字幕用的纹理/FBO 层（跑在同一个 Vulkan device 上）*/
    ANativeWindow *native_window;

#if IS_TILEGRID_HEIC_ENABLED
    /* HEIC tile grid 合成画布（CPU 合成，只做一次，之后当普通单帧用） */
    AVFrame *tile_canvas;
    SDL_VoutOverlay *tile_src;   /* 画布来自哪个 overlay，换了就重合成 */
    const AVFrame *tile_first;   /* 首个 tile 帧，内容变了（指针变）就重合成 */
    int tile_count;
    int tile_w;
    int tile_h;
#endif
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
#if IS_TILEGRID_HEIC_ENABLED
        av_frame_free(&opaque->tile_canvas);
        opaque->tile_src   = NULL;
        opaque->tile_first = NULL;
#endif
    }

    SDL_Vout_FreeInternal(vout);
}

#if IS_TILEGRID_HEIC_ENABLED
static FSTileGridMetadata *tile_meta_of(const AVFrame *frame)
{
    if (!frame || !frame->opaque_ref || frame->opaque_ref->size < (int)sizeof(FSTileGridMetadata))
        return NULL;
    return (FSTileGridMetadata *)frame->opaque_ref->data;
}

/*
 * HEIC tile grid：把 overlay 里已经攒齐的 tile 合成成一张展示尺寸（ROI）的 yuv420p 画布。
 *
 * iOS 侧是把每个 tile 的 CVPixelBuffer 交给 FSMetalTileGridPipeline 合成；安卓这里没有
 * 等价管线，就在 CPU 上合成：用 vout 自己的转换器把 tile 转成 yuv420p（和单帧路径走同一套
 * sws/颜色参数，颜色才一致），再逐平面拷进画布，超出展示区域的部分裁掉。
 *
 * 合成只做一次并缓存（同一个 overlay、同样的 tile 数/尺寸/首帧就直接复用）；之后这张画布和
 * 普通单帧完全一样 —— 缩放/旋转/SAR/快照都作用在整张图上，不会逐 tile 旋转导致画面错乱。
 *
 * 坐标：tile 的 x/y 是 canvas（2048x2560 这种含 padding）坐标系，展示区域是 grid 的
 * width/height（2000x2500），起点是 horizontal/vertical offset —— 按 ROI 裁剪的结果
 * 与 ffmpeg 自己的 xstack 输出一致。
 *
 * 已知限制（实测，未绕过）：对 tile-grid 帧取快照会卡住渲染线程 —— 电视模拟器的软件
 * Vulkan 在把 2000x2500 的视频纹理画进离屏快照目标时进不去（普通 640x480/1280x720
 * 素材的快照正常）。播放本身不受影响：这里只是合成 + 显示，快照那条路是渲染器的既有逻辑。
 */
static const AVFrame *tile_grid_composite(SDL_Vout *vout, SDL_VoutOverlay *overlay,
                                        int roi_w, int roi_h)
{
    SDL_Vout_Opaque *opaque = vout->opaque;
    const int count = SDL_VoutOverlay_GetTileCount(overlay);
    if (count <= 0)
        return NULL;

    AVFrame **frames = (AVFrame **)calloc(count, sizeof(AVFrame *));
    int *xs = (int *)calloc(count, sizeof(int));
    int *ys = (int *)calloc(count, sizeof(int));
    int *ws = (int *)calloc(count, sizeof(int));
    int *hs = (int *)calloc(count, sizeof(int));
    const AVFrame *canvas = NULL;

    int got = 0;
    if (frames && xs && ys && ws && hs) {
        got = SDL_VoutOverlay_GetTileAVFrames(overlay, frames, xs, ys, ws, hs, count);
    }
    if (got <= 0)
        goto done;

    /* 展示区域在 canvas 内的起点（tile 的 x/y 是含 padding 的 canvas 坐标） */
    int roi_x = 0, roi_y = 0;
    FSTileGridMetadata *meta = tile_meta_of(frames[0]);
    if (meta) {
        roi_x = meta->roi_x;
        roi_y = meta->roi_y;
        if (roi_w <= 0 || roi_h <= 0) {
            roi_w = meta->w;      /* 调用方没给就用 grid 的展示尺寸 */
            roi_h = meta->h;
        }
    }
    if (roi_w <= 0 || roi_h <= 0)
        goto done;

    /* 缓存命中？ */
    if (opaque->tile_canvas && opaque->tile_src == overlay &&
        opaque->tile_count == got && opaque->tile_w == roi_w && opaque->tile_h == roi_h &&
        opaque->tile_first == frames[0]) {
        canvas = opaque->tile_canvas;
        goto done;
    }

    AVFrame *dst = opaque->tile_canvas;
    if (!dst || opaque->tile_w != roi_w || opaque->tile_h != roi_h) {
        av_frame_free(&opaque->tile_canvas);
        dst = av_frame_alloc();
        if (!dst)
            goto done;
        dst->format = AV_PIX_FMT_YUV420P;
        dst->width  = roi_w;
        dst->height = roi_h;
        if (av_frame_get_buffer(dst, 32) < 0) {
            av_frame_free(&dst);
            goto done;
        }
        opaque->tile_canvas = dst;
    }

    opaque->tile_src   = overlay;
    opaque->tile_count = got;
    opaque->tile_w     = roi_w;
    opaque->tile_h     = roi_h;
    opaque->tile_first = frames[0];

    if (av_frame_make_writable(dst) < 0)
        goto done;

    /* 没被 tile 盖住的地方填黑（limited range） */
    for (int p = 0; p < 3; p++) {
        const int plane_h = (p == 0) ? roi_h : roi_h >> 1;
        memset(dst->data[p], p == 0 ? 16 : 128, (size_t)dst->linesize[p] * plane_h);
    }

    for (int i = 0; i < got; i++) {
        const AVFrame *tile = frames[i];
        if (!tile)
            continue;

        const AVFrame *src = tile;
        if (tile->format != AV_PIX_FMT_YUV420P) {
            const AVFrame *converted = NULL;
            if (SDL_VoutConvertFrame(vout, AV_PIX_FMT_YUV420P, tile, &converted) != 0 || !converted)
                continue;
            src = converted;   /* vout 复用同一块缓冲，拷完这段就可以被下一个 tile 覆盖 */
        }

        int dx = xs[i] - roi_x;
        int dy = ys[i] - roi_y;
        int sx = 0, sy = 0;
        int cw = ws[i] > 0 ? ws[i] : src->width;
        int ch = hs[i] > 0 ? hs[i] : src->height;
        if (cw > src->width)  cw = src->width;
        if (ch > src->height) ch = src->height;
        if (dx < 0) { sx = -dx; cw += dx; dx = 0; }
        if (dy < 0) { sy = -dy; ch += dy; dy = 0; }
        if (dx + cw > roi_w) cw = roi_w - dx;
        if (dy + ch > roi_h) ch = roi_h - dy;
        if (cw <= 0 || ch <= 0)
            continue;

        /* yuv420p 的色度是 2x2 子采样，起点对齐到偶数，避免色度整体错位半像素 */
        sx &= ~1; sy &= ~1; dx &= ~1; dy &= ~1;
        if (dx + cw > roi_w) cw = roi_w - dx;
        if (dy + ch > roi_h) ch = roi_h - dy;
        if (cw <= 0 || ch <= 0)
            continue;

        for (int p = 0; p < 3; p++) {
            const int shift = p ? 1 : 0;
            const int pw = cw >> shift;
            const int ph = ch >> shift;
            if (pw <= 0 || ph <= 0)
                continue;
            av_image_copy_plane(dst->data[p] + (ptrdiff_t)(dy >> shift) * dst->linesize[p] + (dx >> shift),
                                dst->linesize[p],
                                src->data[p] + (ptrdiff_t)(sy >> shift) * src->linesize[p] + (sx >> shift),
                                src->linesize[p], pw, ph);
        }
    }

    canvas = dst;

done:
    free(frames);
    free(xs);
    free(ys);
    free(ws);
    free(hs);
    return canvas;
}
#endif /* IS_TILEGRID_HEIC_ENABLED */

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
    int disp_w = 0, disp_h = 0;

#if IS_TILEGRID_HEIC_ENABLED
    /* HEIC tile grid：每个 tile 是独立的一帧，先合成成整张图再当普通单帧显示；
       Frame->disp_w/h 就是 grid 的展示尺寸（和含 padding 的 canvas 不同）。 */
    SDL_VoutOverlay *overlay = frame ? frame->bmp : NULL;
    if (overlay && overlay->is_tile_grid) {
        if (SDL_VoutOverlay_IsTilePending(overlay)) {
            /* 还没攒齐，先不刷，避免把半张图显示出去（正常情况下上游也不会推） */
            return 0;
        }
        disp_w = frame->disp_w;
        disp_h = frame->disp_h;
        const AVFrame *composited = tile_grid_composite(vout, overlay, disp_w, disp_h);
        if (!composited) {
            ALOGE("vout_display_overlay_l: tile-grid composite failed\n");
            return -1;
        }
        av_frame = (AVFrame *)composited;
        ALOGV("vout_display_overlay_l: tile-grid composited %dx%d\n", disp_w, disp_h);
    }
#endif

    if (!av_frame) {
        /* 没有视频帧（如只放音频）：只刷一帧字幕，不报错 */
        ALOGV("vout_display_overlay_l: subtitle only\n");
        fs_vulkan_renderer_display_sub_overlay(opaque->renderer);
        return 0;
    }

    if (disp_w <= 0) disp_w = frame->disp_w > 0 ? frame->disp_w : av_frame->width;
    if (disp_h <= 0) disp_h = frame->disp_h > 0 ? frame->disp_h : av_frame->height;
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

void SDL_VoutAndroid_SetRotateDegrees(SDL_Vout *vout, float x, float y, float z)
{
    if (!vout || !vout->opaque || !vout->opaque->renderer)
        return;

    fs_vulkan_renderer_set_rotate_degrees(vout->opaque->renderer, x, y, z);
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

void SDL_VoutAndroid_SetColorAdjust(SDL_Vout *vout, float brightness, float saturation, float contrast)
{
    if (!vout || !vout->opaque || !vout->opaque->renderer)
        return;

    fs_vulkan_renderer_set_color_adjust(vout->opaque->renderer, brightness, saturation, contrast);
}

void SDL_VoutAndroid_SetBackgroundColor(SDL_Vout *vout, int red, int green, int blue)
{
    if (!vout || !vout->opaque || !vout->opaque->renderer)
        return;

    fs_vulkan_renderer_set_background_color(vout->opaque->renderer, red, green, blue);
}

void SDL_VoutAndroid_SetAllowHDRDirectDisplay(SDL_Vout *vout, int allow)
{
    if (!vout || !vout->opaque || !vout->opaque->renderer)
        return;

    fs_vulkan_renderer_set_allow_hdr_display(vout->opaque->renderer, allow);
}

int SDL_VoutAndroid_IsDirectDisplayHDRSupported(SDL_Vout *vout)
{
    if (!vout || !vout->opaque || !vout->opaque->renderer)
        return 0;

    return fs_vulkan_renderer_is_hdr_display_active(vout->opaque->renderer);
}

int SDL_VoutAndroid_IsHDRContent(SDL_Vout *vout)
{
    if (!vout || !vout->opaque || !vout->opaque->renderer)
        return 0;

    return fs_vulkan_renderer_is_hdr_content(vout->opaque->renderer);
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