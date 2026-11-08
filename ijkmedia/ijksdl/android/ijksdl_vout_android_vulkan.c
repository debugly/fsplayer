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
 * version 2.1 of the License, or (at your option) any later version.
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
#include <errno.h>
#include <jni.h>
#include <stdlib.h>
#include <sys/system_properties.h>
#include <android/native_window_jni.h>

#include "ijksdl/ijksdl_vout_internal.h"
#include "ijksdl/ijksdl_gpu.h"
#include "ijksdl/ffmpeg/ijksdl_vout_overlay_ffmpeg.h"
#include "ijkplayer/ff_ffplay_def.h"
#include "vulkan/fs_vulkan_renderer.h"
#include "vulkan/ijksdl_gpu_vulkan.h"
#include "gles3/fs_gles_renderer.h"

#if IS_TILEGRID_HEIC_ENABLED
#include "ijkplayer/ff_heic_tile.h"
#endif

struct SDL_Vout_Opaque {
    FSVulkanRenderer *renderer;
    FSGLESRenderer *gles;
    SDL_GPU *gpu;                 /* 字幕纹理/FBO，与对应后端共享 GPU 上下文 */
    ANativeWindow *native_window;
    int initialized;
    int requested_renderer;
    int gpu_exported;
    int scaling_mode, background_color[3], allow_hdr, blur_iterations;
    float rotation[3], color_adjust[3], blur_sigma;
    void *background_pixels;
    int background_width, background_height;

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
        if (opaque->gles) {
            fs_gles_renderer_detach_gpu(opaque->gles);
            fs_gles_renderer_destroy(opaque->gles);
            opaque->gles = NULL;
        } else if (opaque->gpu) {
            SDL_VulkanGPU_DetachDevice(opaque->gpu);
        }
        if (opaque->renderer) {
            fs_vulkan_renderer_destroy(opaque->renderer);
            opaque->renderer = NULL;
        }
        /* A successful prepare transfers shell ownership to ffplayer. Failed or
         * never-prepared construction must reclaim its own unexported shell. */
        if (opaque->gpu && !opaque->gpu_exported)
            SDL_GPUFreeP(&opaque->gpu);
        free(opaque->background_pixels);
        opaque->background_pixels = NULL;
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
    if (!opaque || (!opaque->renderer && !opaque->gles)) {
        ALOGE("vout_display_overlay_l: no renderer\n");
        return -1;
    }

    /*
     * 字幕叠加：字幕线程已经用 opaque->gpu（SDL_GPU）把这一帧的字幕画进纹理
     * 或 FBO，这里只是把纹理交给渲染器，由渲染器在视频之上做预乘 alpha 混合。
     * 引用由调用方（字幕层）持有，vout 不接管。
     */
    if (opaque->gles)
        fs_gles_renderer_set_sub_overlay(opaque->gles, sub_overlay);
    else
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
        if (opaque->gles)
            return fs_gles_renderer_display_sub_overlay(opaque->gles);
        fs_vulkan_renderer_display_sub_overlay(opaque->renderer);
        return 0;
    }

    if (disp_w <= 0) disp_w = frame->disp_w > 0 ? frame->disp_w : av_frame->width;
    if (disp_h <= 0) disp_h = frame->disp_h > 0 ? frame->disp_h : av_frame->height;
    int rotate = frame->auto_z_rotate_degrees;
    int sar_num = frame->sar.num;
    int sar_den = frame->sar.den;

    if (opaque->gles)
        return fs_gles_renderer_display(opaque->gles, av_frame,
                                        disp_w, disp_h, rotate, sar_num, sar_den);

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

/* No GPU resources are created until player options have been applied. */
SDL_Vout *SDL_VoutAndroid_CreateForAndroid(void)
{
    SDL_Vout *vout = SDL_Vout_CreateInternal(sizeof(SDL_Vout_Opaque));
    if (!vout)
        return NULL;
    SDL_Vout_Opaque *o = vout->opaque;
    o->allow_hdr = 1;
    o->blur_iterations = 3;
    o->blur_sigma = 30.0f;
    o->color_adjust[0] = o->color_adjust[1] = o->color_adjust[2] = 1.0f;
    vout->create_overlay = vout_create_overlay;
    vout->free_l = vout_free_l;
    vout->display_overlay = vout_display_overlay;
    return vout;
}

static void discard_backend(SDL_Vout_Opaque *o)
{
    if (o->gles) {
        fs_gles_renderer_detach_gpu(o->gles);
        fs_gles_renderer_destroy(o->gles);
        o->gles = NULL;
    } else if (o->gpu) {
        SDL_VulkanGPU_DetachDevice(o->gpu);
    }
    if (o->renderer) {
        fs_vulkan_renderer_destroy(o->renderer);
        o->renderer = NULL;
    }
    if (o->gpu && !o->gpu_exported)
        SDL_GPUFreeP(&o->gpu);
    o->gpu = NULL;
    o->initialized = 0;
}

static int initialize_backend(SDL_Vout_Opaque *o, int backend, int require_ahb)
{
    int result;
    if (backend == SDL_ANDROID_RENDERER_OPENGL) {
        o->gles = fs_gles_renderer_create();
        if (!o->gles)
            return -1;
        o->gpu = fs_gles_renderer_get_gpu(o->gles);
#define GLES_SET(name, ...) fs_gles_renderer_##name(o->gles, __VA_ARGS__)
        GLES_SET(set_scaling_mode, o->scaling_mode);
        GLES_SET(set_rotate_degrees, o->rotation[0], o->rotation[1], o->rotation[2]);
        GLES_SET(set_color_adjust, o->color_adjust[0], o->color_adjust[1], o->color_adjust[2]);
        GLES_SET(set_background_color, o->background_color[0], o->background_color[1], o->background_color[2]);
        GLES_SET(set_background_blur, o->blur_iterations, o->blur_sigma);
        GLES_SET(set_allow_hdr_display, o->allow_hdr);
        if (o->background_pixels)
            GLES_SET(set_background_image, o->background_pixels, o->background_width, o->background_height);
        result = GLES_SET(set_surface, o->native_window);
#undef GLES_SET
    } else {
#ifdef FS_NO_VULKAN
        return -1;
#endif
        o->renderer = fs_vulkan_renderer_create();
        if (!o->renderer)
            return -1;
        /* Auto must not settle for Vulkan software uploads when ES3 can expose
         * a MediaCodec SurfaceTexture path. Explicit Vulkan remains allowed. */
        if (require_ahb && !fs_vulkan_renderer_is_ahb_supported(o->renderer)) {
            discard_backend(o);
            return AVERROR(ENOSYS);
        }
        o->gpu = SDL_VulkanGPU_Create(fs_vulkan_renderer_context(o->renderer));
#define VULKAN_SET(name, ...) fs_vulkan_renderer_##name(o->renderer, __VA_ARGS__)
        VULKAN_SET(set_scaling_mode, o->scaling_mode);
        VULKAN_SET(set_rotate_degrees, o->rotation[0], o->rotation[1], o->rotation[2]);
        VULKAN_SET(set_color_adjust, o->color_adjust[0], o->color_adjust[1], o->color_adjust[2]);
        VULKAN_SET(set_background_color, o->background_color[0], o->background_color[1], o->background_color[2]);
        VULKAN_SET(set_background_blur, o->blur_iterations, o->blur_sigma);
        VULKAN_SET(set_allow_hdr_display, o->allow_hdr);
        if (o->background_pixels)
            VULKAN_SET(set_background_image, o->background_pixels, o->background_width, o->background_height);
        result = VULKAN_SET(set_surface, o->native_window);
#undef VULKAN_SET
    }
    if (result < 0) {
        discard_backend(o);
        return result;
    }
    o->initialized = 1;
    free(o->background_pixels);
    o->background_pixels = NULL;
    ALOGI("FSPlayer render backend: %s\n", o->gles ? "OpenGL ES 3" : "Vulkan");
    return 0;
}

int SDL_VoutAndroid_PrepareRenderer(SDL_Vout *vout, int backend)
{
    if (!vout || !vout->opaque || backend < SDL_ANDROID_RENDERER_AUTO ||
        backend > SDL_ANDROID_RENDERER_VULKAN)
        return -1;
    SDL_LockMutex(vout->mutex);
    SDL_Vout_Opaque *o = vout->opaque;
    int result = 0;
    int requested = backend;
    if (o->initialized) {
        /* Retain the context across native stop/reprepare; Java reset creates a new vout. */
        int actual = o->gles ? SDL_ANDROID_RENDERER_OPENGL : SDL_ANDROID_RENDERER_VULKAN;
        if (backend != SDL_ANDROID_RENDERER_AUTO && backend != actual &&
            backend != o->requested_renderer) {
            ALOGE("video-renderer cannot switch an initialized player; create a new instance\n");
            result = -1;
        }
        goto done;
    }
    char sdk[PROP_VALUE_MAX] = {0};
    __system_property_get("ro.build.version.sdk", sdk);
    if (backend == SDL_ANDROID_RENDERER_AUTO) {
        /* Diagnostic override affects auto only, never explicit per-player options. */
        char debug[PROP_VALUE_MAX] = {0};
        __system_property_get("debug.fsplayer.renderer", debug);
        if (!strcmp(debug, "gles3") || !strcmp(debug, "opengl"))
            backend = SDL_ANDROID_RENDERER_OPENGL;
        else if (!strcmp(debug, "vulkan"))
            backend = SDL_ANDROID_RENDERER_VULKAN;
    }
    if (backend == SDL_ANDROID_RENDERER_OPENGL) {
        result = initialize_backend(o, backend, 0);
    } else {
        int api = atoi(sdk);
        result = -1;
        if (api >= 24)
            result = initialize_backend(o, SDL_ANDROID_RENDERER_VULKAN,
                                        requested == SDL_ANDROID_RENDERER_AUTO);
        if (result < 0) {
            if (backend == SDL_ANDROID_RENDERER_VULKAN || api >= 24) {
                ALOGW("Vulkan unavailable: Android API=%d, reason=%s, error=%d; "
                      "fallback to OpenGL ES 3 (requested=%d)\n", api,
                      api < 24 ? "requires API24+" : result == AVERROR(ENOSYS)
                          ? "AHB unsupported in auto mode" : "renderer/surface initialization failed",
                      result, requested);
            }
            result = initialize_backend(o, SDL_ANDROID_RENDERER_OPENGL, 0);
        }
    }
    if (result < 0)
        ALOGE("video-renderer initialization failed, requested=%d\n", requested);
    else
        o->requested_renderer = requested;
done:
    SDL_UnlockMutex(vout->mutex);
    return result;
}

int SDL_VoutAndroid_GetRendererType(SDL_Vout *vout)
{
    if (!vout || !vout->opaque)
        return 0;
    SDL_LockMutex(vout->mutex);
    SDL_Vout_Opaque *o = vout->opaque;
    int type = o->initialized ? (o->gles ? SDL_ANDROID_RENDERER_OPENGL : SDL_ANDROID_RENDERER_VULKAN) : 0;
    SDL_UnlockMutex(vout->mutex);
    return type;
}

SDL_Vout *SDL_VoutAndroid_CreateForVulkan(void)
{
    SDL_Vout *vout = SDL_VoutAndroid_CreateForAndroid();
    if (vout && SDL_VoutAndroid_PrepareRenderer(vout, SDL_ANDROID_RENDERER_VULKAN) < 0) {
        vout_free_l(vout);
        return NULL;
    }
    return vout;
}

SDL_Vout *SDL_VoutAndroid_CreateForOpenGLES3(void)
{
    SDL_Vout *vout = SDL_VoutAndroid_CreateForAndroid();
    if (vout && SDL_VoutAndroid_PrepareRenderer(vout, SDL_ANDROID_RENDERER_OPENGL) < 0) {
        vout_free_l(vout);
        return NULL;
    }
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

    if (opaque->gles)
        fs_gles_renderer_set_surface(opaque->gles, opaque->native_window);
    else if (opaque->renderer)
        fs_vulkan_renderer_set_surface(opaque->renderer, opaque->native_window);

    SDL_UnlockMutex(vout->mutex);
}

int SDL_VoutAndroid_IsOpenGLES3(SDL_Vout *vout)
{
    return vout && vout->opaque && vout->opaque->gles != NULL;
}

int SDL_VoutAndroid_IsMediaCodecSupported(SDL_Vout *vout)
{
    if (!vout || !vout->opaque)
        return 0;

    if (vout->opaque->gles) {
        return fs_gles_renderer_is_mediacodec_supported(vout->opaque->gles);
    }

    return fs_vulkan_renderer_is_mediacodec_supported(vout->opaque->renderer);
}

void SDL_VoutAndroid_SetScalingMode(SDL_Vout *vout, int mode)
{
    if (!vout || !vout->opaque)
        return;
    SDL_LockMutex(vout->mutex);
    SDL_Vout_Opaque *o = vout->opaque;
    o->scaling_mode = mode;
    if (o->gles)
        fs_gles_renderer_set_scaling_mode(o->gles, mode);
    else if (o->renderer)
        fs_vulkan_renderer_set_scaling_mode(o->renderer, mode);
    SDL_UnlockMutex(vout->mutex);
}

void SDL_VoutAndroid_SetRotateDegrees(SDL_Vout *vout, float x, float y, float z)
{
    if (!vout || !vout->opaque)
        return;
    SDL_LockMutex(vout->mutex);
    SDL_Vout_Opaque *o = vout->opaque;
    o->rotation[0] = x; o->rotation[1] = y; o->rotation[2] = z;
    if (o->gles)
        fs_gles_renderer_set_rotate_degrees(o->gles, x, y, z);
    else if (o->renderer)
        fs_vulkan_renderer_set_rotate_degrees(o->renderer, x, y, z);
    SDL_UnlockMutex(vout->mutex);
}

/*
 * 注意：这里不拿 vout 的锁。快照要等渲染线程把下一帧画出来，而渲染线程显示时
 * 也要拿这把锁，持锁等待就死锁了；renderer 指针本身在 vout 生命周期内是稳定的。
 */
void SDL_VoutAndroid_SetBackgroundImage(SDL_Vout *vout, const void *pixels, int width, int height)
{
    if (!vout || !vout->opaque)
        return;
    SDL_LockMutex(vout->mutex);
    SDL_Vout_Opaque *o = vout->opaque;
    if (o->gles) {
        fs_gles_renderer_set_background_image(o->gles, pixels, width, height);
    } else if (o->renderer) {
        fs_vulkan_renderer_set_background_image(o->renderer, pixels, width, height);
    } else {
        void *copy = NULL;
        if (pixels) {
            if (width <= 0 || height <= 0 || width > 32768 || height > 32768 ||
                (size_t)width * height > SIZE_MAX / 4)
                goto done;
            size_t bytes = (size_t)width * height * 4;
            copy = malloc(bytes);
            if (!copy)
                goto done;
            memcpy(copy, pixels, bytes);
        }
        free(o->background_pixels);
        o->background_pixels = copy;
        o->background_width = pixels ? width : 0;
        o->background_height = pixels ? height : 0;
    }
done:
    SDL_UnlockMutex(vout->mutex);
}

void SDL_VoutAndroid_SetBackgroundBlur(SDL_Vout *vout, int iterations, float sigma)
{
    if (!vout || !vout->opaque)
        return;
    SDL_LockMutex(vout->mutex);
    SDL_Vout_Opaque *o = vout->opaque;
    o->blur_iterations = iterations; o->blur_sigma = sigma;
    if (o->gles)
        fs_gles_renderer_set_background_blur(o->gles, iterations, sigma);
    else if (o->renderer)
        fs_vulkan_renderer_set_background_blur(o->renderer, iterations, sigma);
    SDL_UnlockMutex(vout->mutex);
}

void SDL_VoutAndroid_SetColorAdjust(SDL_Vout *vout, float brightness, float saturation, float contrast)
{
    if (!vout || !vout->opaque)
        return;
    SDL_LockMutex(vout->mutex);
    SDL_Vout_Opaque *o = vout->opaque;
    o->color_adjust[0] = brightness; o->color_adjust[1] = saturation; o->color_adjust[2] = contrast;
    if (o->gles)
        fs_gles_renderer_set_color_adjust(o->gles, brightness, saturation, contrast);
    else if (o->renderer)
        fs_vulkan_renderer_set_color_adjust(o->renderer, brightness, saturation, contrast);
    SDL_UnlockMutex(vout->mutex);
}

void SDL_VoutAndroid_SetBackgroundColor(SDL_Vout *vout, int red, int green, int blue)
{
    if (!vout || !vout->opaque)
        return;
    SDL_LockMutex(vout->mutex);
    SDL_Vout_Opaque *o = vout->opaque;
    o->background_color[0] = red; o->background_color[1] = green; o->background_color[2] = blue;
    if (o->gles)
        fs_gles_renderer_set_background_color(o->gles, red, green, blue);
    else if (o->renderer)
        fs_vulkan_renderer_set_background_color(o->renderer, red, green, blue);
    SDL_UnlockMutex(vout->mutex);
}

void SDL_VoutAndroid_SetAllowHDRDirectDisplay(SDL_Vout *vout, int allow)
{
    if (!vout || !vout->opaque)
        return;
    SDL_LockMutex(vout->mutex);
    SDL_Vout_Opaque *o = vout->opaque;
    o->allow_hdr = allow;
    if (o->gles)
        fs_gles_renderer_set_allow_hdr_display(o->gles, allow);
    else if (o->renderer)
        fs_vulkan_renderer_set_allow_hdr_display(o->renderer, allow);
    SDL_UnlockMutex(vout->mutex);
}

int SDL_VoutAndroid_IsDirectDisplayHDRSupported(SDL_Vout *vout)
{
    if (!vout || !vout->opaque || (!vout->opaque->renderer && !vout->opaque->gles))
        return 0;

    if (vout->opaque->gles) {
        return fs_gles_renderer_is_hdr_display_active(vout->opaque->gles);
    }

    return fs_vulkan_renderer_is_hdr_display_active(vout->opaque->renderer);
}

int SDL_VoutAndroid_IsHDRContent(SDL_Vout *vout)
{
    if (!vout || !vout->opaque || (!vout->opaque->renderer && !vout->opaque->gles))
        return 0;

    if (vout->opaque->gles) {
        return fs_gles_renderer_is_hdr_content(vout->opaque->gles);
    }

    return fs_vulkan_renderer_is_hdr_content(vout->opaque->renderer);
}

int SDL_VoutAndroid_TakeSnapshot(SDL_Vout *vout, int type,
                                 int *out_w, int *out_h, void **out_pixels)
{
    if (!vout || !vout->opaque || (!vout->opaque->renderer && !vout->opaque->gles))
        return -1;

    if (vout->opaque->gles) {
        return fs_gles_renderer_take_snapshot(vout->opaque->gles, type,
                                            out_w, out_h, out_pixels);
    }

    return fs_vulkan_renderer_take_snapshot(vout->opaque->renderer, type,
                                            out_w, out_h, out_pixels);
}

jobject SDL_VoutAndroid_GetMediaCodecSurface(JNIEnv *env, SDL_Vout *vout)
{
    if (!vout || !vout->opaque)
        return NULL;

    if (vout->opaque->gles)
        return fs_gles_renderer_get_mediacodec_surface(env, vout->opaque->gles);

    return fs_vulkan_renderer_get_mediacodec_surface(env, vout->opaque->renderer);
}

SDL_GPU *SDL_VoutAndroid_GetGPU(SDL_Vout *vout)
{
    if (!vout || !vout->opaque)
        return NULL;

    /* 借用：所有权在 ffplayer，vout 只负责销毁前 detach（见 vout_free_l） */
    SDL_LockMutex(vout->mutex);
    SDL_Vout_Opaque *o = vout->opaque;
    SDL_GPU *gpu = o->initialized ? o->gpu : NULL;
    if (gpu)
        o->gpu_exported = 1;
    SDL_UnlockMutex(vout->mutex);
    return gpu;
}