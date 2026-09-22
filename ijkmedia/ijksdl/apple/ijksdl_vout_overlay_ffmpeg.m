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
#include "ijk_cvpixelbuffer.h"
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/buffer.h>
#include "ijkplayer/ff_heic_tile.h"
#include "ff_version.h"

struct FSTileSlot;
struct SDL_VoutOverlay_Opaque {
    SDL_mutex *mutex;
    Uint16 pitches[AV_NUM_DATA_POINTERS];

    // When set, this vout drives an AVFrame-passthrough renderer (FSPlaceboView). Used to
    // skip HEIC tile accumulation (only FSMetalView consumes tile CVPixelBuffers today).
    int render_avframe;
#if IS_TILEGRID_HEIC_ENABLED
    /* HEIC tile grid 模式 */
    int         tile_mode;       // 1 表示当前正在累积 tile
    int         tile_expected;   // 期望总数（grid->nb_tiles）
    int         tile_received;   // 已收到并存入槽位的 tile 数
    int         tile_ready;      // 1 表示已攒齐、可显示
    int         tile_canvas_w;
    int         tile_canvas_h;
    struct FSTileSlot *tiles;           // 长度 tile_expected
#endif
};

#if IS_TILEGRID_HEIC_ENABLED
typedef struct FSTileSlot {
    CVPixelBufferRef pb;   // 已拷贝的 tile CVPixelBuffer（owned）
    int x, y;              // tile 在 canvas 上的位置
    int w, h;              // tile 尺寸
    int filled;            // 是否已填充
} FSTileSlot;

static void tile_slots_free(SDL_VoutOverlay_Opaque *opaque)
{
    if (!opaque || !opaque->tiles)
        return;
    for (int i = 0; i < opaque->tile_expected; i++) {
        if (opaque->tiles[i].pb) {
            CVPixelBufferRelease(opaque->tiles[i].pb);
            opaque->tiles[i].pb = NULL;
        }
    }
    free(opaque->tiles);
    opaque->tiles = NULL;
    opaque->tile_expected = 0;
    opaque->tile_received = 0;
    opaque->tile_ready    = 0;
    opaque->tile_mode     = 0;
    opaque->tile_canvas_w = 0;
    opaque->tile_canvas_h = 0;
}

static int func_is_tile_pending(SDL_VoutOverlay *overlay)
{
    if (!overlay) return 0;
    SDL_VoutOverlay_Opaque *opaque = overlay->opaque;
    if (!opaque || !opaque->tile_mode) return 0;
    return opaque->tile_ready ? 0 : 1;
}

static int func_get_tile_count(SDL_VoutOverlay *overlay)
{
    if (!overlay) return 0;
    SDL_VoutOverlay_Opaque *opaque = overlay->opaque;
    if (!opaque || !opaque->tile_mode) return 0;
    return opaque->tile_received;
}

static int func_get_tile_buffers(SDL_VoutOverlay *overlay,
                                 CVPixelBufferRef *out_buffers,
                                 int *out_x, int *out_y,
                                 int *out_w, int *out_h,
                                 int max_count)
{
    if (!overlay) return 0;
    SDL_VoutOverlay_Opaque *opaque = overlay->opaque;
    if (!opaque || !opaque->tile_mode || !opaque->tiles) return 0;
    int n = opaque->tile_expected < max_count ? opaque->tile_expected : max_count;
    int k = 0;
    for (int i = 0; i < n; i++) {
        FSTileSlot *slot = &opaque->tiles[i];
        if (!slot->filled || !slot->pb) continue;
        if (out_buffers) out_buffers[k] = slot->pb;
        if (out_x) out_x[k] = slot->x;
        if (out_y) out_y[k] = slot->y;
        if (out_w) out_w[k] = slot->w;
        if (out_h) out_h[k] = slot->h;
        k++;
    }
    return k;
}
#endif

static SDL_Class g_vout_overlay_ffmpeg_class = {
    .name = "FFmpegVoutOverlay",
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
    tile_slots_free(opaque);
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

    SDL_VoutOverlay_Opaque *opaque = overlay->opaque;

#if IS_TILEGRID_HEIC_ENABLED
    /* ---------- HEIC tile grid 分支 ----------
       Tile grids are still carried as CVPixelBuffers because no renderer consumes tile
       AVFrames yet. Only MetalView can show them; AVFrame-passthrough renderers
       (FSPlaceboView, render_avframe) fall straight through to the single-frame retain. */
    if (!opaque->render_avframe) {
        FSTileGridMetadata *tmeta = NULL;
        if (frame->opaque_ref && frame->opaque_ref->size >= (int)sizeof(FSTileGridMetadata)) {
            tmeta = (FSTileGridMetadata *)frame->opaque_ref->data;
            if (tmeta->nb_tiles <= 0 || tmeta->canvas_w <= 0 || tmeta->canvas_h <= 0) {
                tmeta = NULL; // 非法元数据，回落到单帧
            }
        }

        if (tmeta) {
            // 首次进入 tile 模式：初始化槽位
            if (!opaque->tile_mode ||
                opaque->tile_expected != tmeta->nb_tiles ||
                opaque->tile_canvas_w != tmeta->canvas_w ||
                opaque->tile_canvas_h != tmeta->canvas_h) {
                
                // 之前可能有残留，先清理
                tile_slots_free(opaque);
                
                opaque->tile_mode     = 1;
                opaque->tile_expected = tmeta->nb_tiles;
                opaque->tile_received = 0;
                opaque->tile_ready    = 0;
                opaque->tile_canvas_w = tmeta->canvas_w;
                opaque->tile_canvas_h = tmeta->canvas_h;
                opaque->tiles = (FSTileSlot *)calloc((size_t)tmeta->nb_tiles, sizeof(FSTileSlot));
                if (!opaque->tiles) {
                    ALOGE("tile_mode: allocate tiles array failed");
                    opaque->tile_expected = 0;
                    opaque->tile_mode     = 0;
                    return -100;
                }
                
                overlay->is_tile_grid   = 1;
                overlay->tile_canvas_w  = tmeta->canvas_w;
                overlay->tile_canvas_h  = tmeta->canvas_h;
                overlay->w              = tmeta->w;
                overlay->h              = tmeta->h;
            }
            
            int idx = tmeta->tile_index;
            if (idx < 0 || idx >= opaque->tile_expected) {
                ALOGE("tile_mode: invalid tile_index %d (expected<%d)", idx, opaque->tile_expected);
                return 0; // 忽略，继续累积
            }
            
            FSTileSlot *slot = &opaque->tiles[idx];
            // 如果该槽位已有（重复 put 导致），先释放旧的
            if (slot->pb) {
                CVPixelBufferRelease(slot->pb);
                slot->pb = NULL;
                slot->filled = 0;
                if (opaque->tile_received > 0) opaque->tile_received--;
            }
            
            // 每个 tile 分辨率可能与 pool 不符，直接不走 pool
            CVPixelBufferRef pb = FSCVPixelBufferCreateFromAVFrame(frame, NULL);
            if (!pb) {
                ALOGE("tile_mode: createCVPixelBufferFromAVFrame failed for tile %d", idx);
                return 0;
            }
            slot->pb     = pb;
            slot->x      = tmeta->tile_x;
            slot->y      = tmeta->tile_y;
            slot->w      = tmeta->tile_w > 0 ? tmeta->tile_w : frame->width;
            slot->h      = tmeta->tile_h > 0 ? tmeta->tile_h : frame->height;
            slot->filled = 1;
            opaque->tile_received++;
            
            ALOGD("tile_mode: received tile %d/%d at (%d,%d) %dx%d",
                  opaque->tile_received, opaque->tile_expected,
                  slot->x, slot->y, slot->w, slot->h);
            
            // pitches 先维持个合理值，渲染侧不再用 overlay->pitches
            overlay->pitches[0] = CVPixelBufferGetWidth(pb);
            
            if (opaque->tile_received >= opaque->tile_expected) {
                opaque->tile_ready = 1;
                ALOGI("tile_mode: all %d tiles gathered, canvas=%dx%d",
                      opaque->tile_expected, opaque->tile_canvas_w, opaque->tile_canvas_h);
            }
            return 0;
        }
        
        /* ---------- 普通单帧路径（非 tile 或 opaque 丢失） ---------- */
        // 若此前处于 tile 模式（切换到普通视频），清理 tile 状态
        if (opaque->tile_mode) {
            tile_slots_free(opaque);
            overlay->is_tile_grid  = 0;
            overlay->tile_canvas_w = 0;
            overlay->tile_canvas_h = 0;
        }
    } // !render_avframe
#endif

    // Single-frame path: retain the raw decoded frame (with color / Dolby Vision side
    // data) and let the renderer derive what it needs. FSMetalView converts it to a
    // CVPixelBuffer on the render thread (pool-reused); FSPlaceboView uploads it directly.
    // The overlay no longer produces a CVPixelBuffer here. Published on the overlay for
    // the dispatch layer.
    if (!overlay->av_frame) {
        overlay->av_frame = av_frame_alloc();
        if (!overlay->av_frame) return -100;
    }
    av_frame_unref(overlay->av_frame);
    if (av_frame_ref(overlay->av_frame, frame) < 0) return -100;
    overlay->w = frame->width;
    overlay->h = frame->height;
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
             width, height, (const char*) pd->name, display);
    
    SDL_VoutOverlay_Opaque *opaque = overlay->opaque;
    opaque->mutex         = SDL_CreateMutex();
    overlay->opaque_class = &g_vout_overlay_ffmpeg_class;
    overlay->format       = SDL_FCC__FFVTB;
    overlay->is_private   = 1;
    overlay->pitches      = opaque->pitches;
    overlay->w            = width;
    overlay->h            = height;
    overlay->free_l             = func_free_l;
    overlay->lock               = func_lock;
    overlay->unlock             = func_unlock;
    overlay->func_fill_frame    = func_fill_avframe_to_cvpixelbuffer;
    opaque->render_avframe      = display->render_avframe;
#if IS_TILEGRID_HEIC_ENABLED
    overlay->func_is_tile_pending = func_is_tile_pending;
    overlay->func_get_tile_count  = func_get_tile_count;
    overlay->func_get_tile_buffers = func_get_tile_buffers;
#endif

    return overlay;
}
