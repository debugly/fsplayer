/*****************************************************************************
 * ijk_heic_tile_overlay.c
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

#include "ijk_heic_tile_overlay.h"
#include "ijksdl_log.h"
#include "ijkplayer/ff_heic_tile.h"
#include "ff_version.h"

#if IS_TILEGRID_HEIC_ENABLED

#include <stdlib.h>

typedef struct FSTileSlot {
    AVFrame *frame;        // 已 av_frame_ref 的 tile 帧（owned），渲染侧再转 CVPixelBuffer
    int x, y;              // tile 在 canvas 上的位置
    int w, h;              // tile 尺寸
    int filled;            // 是否已填充
} FSTileSlot;

void fs_tile_acc_free(FSTileAccumulator *acc)
{
    if (!acc || !acc->tiles)
        return;
    for (int i = 0; i < acc->tile_expected; i++) {
        if (acc->tiles[i].frame) {
            av_frame_free(&acc->tiles[i].frame);
        }
    }
    free(acc->tiles);
    acc->tiles = NULL;
    acc->tile_expected = 0;
    acc->tile_received = 0;
    acc->tile_ready    = 0;
    acc->tile_mode     = 0;
    acc->tile_canvas_w = 0;
    acc->tile_canvas_h = 0;
}

int fs_tile_acc_is_pending(const FSTileAccumulator *acc)
{
    if (!acc || !acc->tile_mode) return 0;
    return acc->tile_ready ? 0 : 1;
}

int fs_tile_acc_count(const FSTileAccumulator *acc)
{
    if (!acc || !acc->tile_mode) return 0;
    return acc->tile_received;
}

void fs_tile_acc_get_canvas(const FSTileAccumulator *acc, int *out_w, int *out_h) {
    if (!acc || !acc->tile_mode) return;
    if (out_w) {
        *out_w = acc->tile_canvas_w;
    }
    if (out_h) {
        *out_h = acc->tile_canvas_h;
    }
}

int fs_tile_acc_get_avframes(const FSTileAccumulator *acc,
                             AVFrame **out_frames,
                             int *out_x, int *out_y,
                             int *out_w, int *out_h,
                             int max_count)
{
    if (!acc || !acc->tile_mode || !acc->tiles) return 0;
    int n = acc->tile_expected < max_count ? acc->tile_expected : max_count;
    int k = 0;
    for (int i = 0; i < n; i++) {
        FSTileSlot *slot = &acc->tiles[i];
        if (!slot->filled || !slot->frame) continue;
        if (out_frames) out_frames[k] = slot->frame;
        if (out_x) out_x[k] = slot->x;
        if (out_y) out_y[k] = slot->y;
        if (out_w) out_w[k] = slot->w;
        if (out_h) out_h[k] = slot->h;
        k++;
    }
    return k;
}

int fs_tile_acc_fill(SDL_VoutOverlay *overlay, FSTileAccumulator *acc, const AVFrame *frame)
{
    if (!overlay || !acc || !frame)
        return -100;

    /* ---------- HEIC tile grid 分支 ----------
       Tile grids carry each tile's AVFrame up to the renderer, which converts to
       CVPixelBuffer itself (FSMetalView) or uploads it directly (FSPlaceboView) —
       matching the single-frame path. Tiles always accumulate here; renderers that
       cannot composite tiles yet simply won't display them. */
    FSTileGridMetadata *tmeta = NULL;
    if (frame->opaque_ref && frame->opaque_ref->size >= (int)sizeof(FSTileGridMetadata)) {
        tmeta = (FSTileGridMetadata *)frame->opaque_ref->data;
        if (tmeta->nb_tiles <= 0 || tmeta->canvas_w <= 0 || tmeta->canvas_h <= 0) {
            tmeta = NULL; // 非法元数据，回落到单帧
        }
    }

    if (tmeta) {
        // 首次进入 tile 模式：初始化槽位
        if (!acc->tile_mode ||
            acc->tile_expected != tmeta->nb_tiles ||
            acc->tile_canvas_w != tmeta->canvas_w ||
            acc->tile_canvas_h != tmeta->canvas_h) {

            // 之前可能有残留，先清理
            fs_tile_acc_free(acc);

            acc->tile_mode     = 1;
            acc->tile_expected = tmeta->nb_tiles;
            acc->tile_received = 0;
            acc->tile_ready    = 0;
            acc->tile_canvas_w = tmeta->canvas_w;
            acc->tile_canvas_h = tmeta->canvas_h;
            acc->tiles = (FSTileSlot *)calloc((size_t)tmeta->nb_tiles, sizeof(FSTileSlot));
            if (!acc->tiles) {
                ALOGE("HEIC tile_mode: allocate tiles array failed");
                acc->tile_expected = 0;
                acc->tile_mode     = 0;
                return -100;
            }

            overlay->is_tile_grid   = 1;
//            overlay->tile_canvas_w  = tmeta->canvas_w;
//            overlay->tile_canvas_h  = tmeta->canvas_h;
        }

        int idx = tmeta->tile_index;
        if (idx < 0 || idx >= acc->tile_expected) {
            ALOGE("HEIC tile_mode: invalid tile_index %d (expected<%d)", idx, acc->tile_expected);
            return 1; // 忽略此帧，但仍处于 tile 模式，继续累积
        }

        FSTileSlot *slot = &acc->tiles[idx];
        // 如果该槽位已有（重复 put 导致），先释放旧的
        if (slot->frame) {
            av_frame_free(&slot->frame);
            slot->filled = 0;
            if (acc->tile_received > 0) acc->tile_received--;
        }

        // 保留该 tile 的原始 AVFrame（含色彩/像素信息，VTB 的 CVPixelBuffer 随 data[3]
        // 一起被 av_frame_ref 保活），转成 CVPixelBuffer 的工作交给渲染侧（FSMetalView）。
        slot->frame = av_frame_alloc();
        if (!slot->frame) {
            ALOGE("HEIC tile_mode: av_frame_alloc failed for tile %d", idx);
            return 1;
        }
        if (av_frame_ref(slot->frame, frame) < 0) {
            ALOGE("HEIC tile_mode: av_frame_ref failed for tile %d", idx);
            av_frame_free(&slot->frame);
            return 1;
        }
        slot->x      = tmeta->tile_x;
        slot->y      = tmeta->tile_y;
        slot->w      = tmeta->tile_w > 0 ? tmeta->tile_w : frame->width;
        slot->h      = tmeta->tile_h > 0 ? tmeta->tile_h : frame->height;
        slot->filled = 1;
        acc->tile_received++;

        ALOGD("HEIC tile_mode: received tile %d/%d at (%d,%d) %dx%d",
              acc->tile_received, acc->tile_expected,
              slot->x, slot->y, slot->w, slot->h);

        if (acc->tile_received >= acc->tile_expected) {
            acc->tile_ready = 1;
            ALOGI("HEIC tile_mode: all %d tiles gathered, canvas=%dx%d",
                  acc->tile_expected, acc->tile_canvas_w, acc->tile_canvas_h);
        }
        return 1;
    }

    /* ---------- 普通单帧路径（非 tile 或 opaque 丢失） ---------- */
    // 若此前处于 tile 模式（切换到普通视频），清理 tile 状态
    if (acc->tile_mode) {
        fs_tile_acc_free(acc);
        overlay->is_tile_grid  = 0;
//        overlay->tile_canvas_w = 0;
//        overlay->tile_canvas_h = 0;
    }
    return 0;
}

#endif /* IS_TILEGRID_HEIC_ENABLED */
