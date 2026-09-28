/*****************************************************************************
 * ijksdl_vout_overlay_videotoolbox.m
 *****************************************************************************
 *
 * Copyright (c) 2014 ZhouQuan <zhouqicy@gmail.com>
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

#include "ijksdl_vout_overlay_ffmpeg_hw.h"
#include "ijksdl_stdinc.h"
#include "ijksdl_mutex.h"
#include "ijksdl_vout_internal.h"
#include "ijksdl_video.h"
#include "ijk_heic_tile_overlay.h"
#include "ijkplayer/ff_heic_tile.h"
#include "ff_version.h"

struct SDL_VoutOverlay_Opaque {
    SDL_mutex *mutex;
#if IS_TILEGRID_HEIC_ENABLED
    FSTileAccumulator tile_acc;   // HEIC tile grid 累积状态（共享实现）
#endif
};

#if IS_TILEGRID_HEIC_ENABLED

static int func_is_tile_pending(SDL_VoutOverlay *overlay)
{
    if (!overlay) return 0;
    return fs_tile_acc_is_pending(&overlay->opaque->tile_acc);
}

static int func_get_tile_count(SDL_VoutOverlay *overlay)
{
    if (!overlay) return 0;
    return fs_tile_acc_count(&overlay->opaque->tile_acc);
}

static int func_get_tile_avframes(SDL_VoutOverlay *overlay,
                                  AVFrame **out_frames,
                                  int *out_x, int *out_y,
                                  int *out_w, int *out_h,
                                  int max_count)
{
    if (!overlay) return 0;
    return fs_tile_acc_get_avframes(&overlay->opaque->tile_acc,
                                    out_frames, out_x, out_y, out_w, out_h, max_count);
}

static void func_get_tile_canvas(SDL_VoutOverlay *overlay,
                                 int *out_w, int *out_h)
{
    if (!overlay) return;
    fs_tile_acc_get_canvas(&overlay->opaque->tile_acc, out_w, out_h);
}

#endif

static void func_free_l(SDL_VoutOverlay *overlay)
{
    if (!overlay)
        return;
    SDL_VoutOverlay_Opaque *opaque = overlay->opaque;
    if (!opaque)
        return;
    /* overlay->av_frame is released by the generic SDL_VoutFreeYUVOverlay/UnrefYUVOverlay. */
#if IS_TILEGRID_HEIC_ENABLED
    fs_tile_acc_free(&opaque->tile_acc);
#endif
    if (opaque->mutex)
        SDL_DestroyMutex(opaque->mutex);
    
    SDL_VoutOverlay_FreeInternal(overlay);
}

static int func_lock(SDL_VoutOverlay *overlay)
{
    SDL_VoutOverlay_Opaque *opaque = overlay->opaque;
    return SDL_LockMutex(opaque->mutex);
}

static int func_unlock(SDL_VoutOverlay *overlay)
{
    SDL_VoutOverlay_Opaque *opaque = overlay->opaque;
    return SDL_UnlockMutex(opaque->mutex);
}

static int func_fill_frame(SDL_VoutOverlay *overlay, const AVFrame *frame)
{
    CVPixelBufferRef pixel_buffer = NULL;
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        pixel_buffer = (CVPixelBufferRef)frame->data[3];
    } else {
        return -100;
    }
    
    if (NULL == pixel_buffer) {
        return -1;
    }
    
    SDL_VoutOverlay_Opaque *opaque = overlay->opaque;
#if IS_TILEGRID_HEIC_ENABLED
    /* ---------- HEIC tile grid 分支 ----------
       共享累积器：返回 1 表示已作为 tile 消费；<0 为硬错误；0 回落到单帧路径。 */
    int tr = fs_tile_acc_fill(overlay, &opaque->tile_acc, frame);
    if (tr != 0) {
        return tr < 0 ? tr : 0;
    }
#endif
    
    /* Keep a ref to the whole frame so the renderer can read its native planes and
     side data (e.g. Dolby Vision RPU). For VideoToolbox the CVPixelBuffer lives in
     frame->data[3], so retaining the frame keeps the pixel buffer alive too — the
     renderer (FSMetalView / FSPlaceboView) pulls it from the frame directly.
     Cheap: av_frame_ref is ref-counted. Published on the overlay for the dispatch layer. */
    if (overlay->av_frame) {
        av_frame_unref(overlay->av_frame);
    } else {
        overlay->av_frame = av_frame_alloc();
    }
    if (overlay->av_frame) {
        av_frame_ref(overlay->av_frame, frame);
    }

    return 0;
}

static SDL_Class g_vout_overlay_videotoolbox_class = {
    .name = "VideoToolboxVoutOverlay",
};

SDL_VoutOverlay *SDL_VoutFFmpeg_HW_CreateOverlay(int width, int height, SDL_Vout *display)
{
    SDLTRACE("SDL_FFmpeg_HW_CreateOverlay(w=%d, h=%d, fmt=_VTB, dp=%p)\n",
             width, height, display);
    SDL_VoutOverlay *overlay = SDL_VoutOverlay_CreateInternal(sizeof(SDL_VoutOverlay_Opaque));
    if (!overlay) {
        ALOGE("overlay allocation failed");
        return NULL;
    }
    SDL_VoutOverlay_Opaque *opaque = overlay->opaque;
    overlay->opaque_class = &g_vout_overlay_videotoolbox_class;
    overlay->free_l             = func_free_l;
    overlay->lock               = func_lock;
    overlay->unlock             = func_unlock;
    overlay->func_fill_frame    = func_fill_frame;
#if IS_TILEGRID_HEIC_ENABLED
    overlay->func_is_tile_pending = func_is_tile_pending;
    overlay->func_get_tile_count  = func_get_tile_count;
    overlay->func_get_tile_avframes = func_get_tile_avframes;
    overlay->func_get_tile_canvas = func_get_tile_canvas;
#endif
    opaque->mutex = SDL_CreateMutex();
    return overlay;
}
