/*****************************************************************************
 * ijksdl_vout_overlay_ffmpeg.c
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

#include "ijksdl_vout_overlay_ffmpeg.h"
#include "../ijksdl_vout_internal.h"
#include "ijk_vout_common.h"
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/buffer.h>
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

static SDL_Class g_vout_overlay_ffmpeg_class = {
    .name = "FSVoutOverlay",
};

static void func_free_l(SDL_VoutOverlay *overlay)
{
    SDLTRACE("SDL_Overlay(ffmpeg): overlay_free_l(%p)\n", overlay);
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

static int func_fill_avframe_to_cvpixelbuffer(SDL_VoutOverlay *overlay, const AVFrame *frame)
{
    if (!overlay || !frame)
        return -100;

    /* For VideoToolbox frames the CVPixelBuffer lives in data[3]; guard against
       frames that arrive with the right format but an empty buffer slot. */
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        CVPixelBufferRef pixel_buffer = (CVPixelBufferRef)frame->data[3];
        if (!pixel_buffer) {
            ALOGE("func_fill_avframe_to_cvpixelbuffer: VTB frame with NULL pixel_buffer\n");
            return -1;
        }
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

    // Single-frame path: retain the raw decoded frame (with color / Dolby Vision side
    // data) and let the renderer derive what it needs. FSMetalView converts it to a
    // CVPixelBuffer on the render thread (pool-reused); FSPlaceboView uploads it directly.
    // For VideoToolbox frames the CVPixelBuffer lives in frame->data[3]; retaining the
    // frame keeps it alive. The overlay no longer produces a CVPixelBuffer here; it is
    // published on overlay->av_frame for the dispatch layer.
    if (!overlay->av_frame) {
        overlay->av_frame = av_frame_alloc();
        if (!overlay->av_frame) return -100;
    }
    av_frame_unref(overlay->av_frame);
    if (av_frame_ref(overlay->av_frame, frame) < 0) return -100;
    return 0;
}

SDL_VoutOverlay *SDL_VoutFFmpeg_CreateOverlay(int width, int height,int src_format, SDL_Vout *display)
{
    enum AVPixelFormat const format = src_format;
    if(format == AV_PIX_FMT_NONE) {
        return NULL;
    }
    
    SDL_VoutOverlay *overlay = SDL_VoutOverlay_CreateInternal(sizeof(SDL_VoutOverlay_Opaque));
    if (!overlay) {
        ALOGE("VoutFFmpeg allocation failed");
        return NULL;
    }

    const AVPixFmtDescriptor *pd = av_pix_fmt_desc_get(format);
    SDLTRACE("Create FFmpeg Overlay(w=%d, h=%d, fmt=%s, dp=%p)\n",
             width, height, pd ? pd->name : "hw/opaque", display);
    
    SDL_VoutOverlay_Opaque *opaque = overlay->opaque;
    opaque->mutex         = SDL_CreateMutex();
    overlay->opaque_class = &g_vout_overlay_ffmpeg_class;
    overlay->free_l             = func_free_l;
    overlay->lock               = func_lock;
    overlay->unlock             = func_unlock;
    overlay->func_fill_frame    = func_fill_avframe_to_cvpixelbuffer;
#if IS_TILEGRID_HEIC_ENABLED
    overlay->func_is_tile_pending = func_is_tile_pending;
    overlay->func_get_tile_count  = func_get_tile_count;
    overlay->func_get_tile_avframes = func_get_tile_avframes;
    overlay->func_get_tile_canvas = func_get_tile_canvas;
#endif

    return overlay;
}
