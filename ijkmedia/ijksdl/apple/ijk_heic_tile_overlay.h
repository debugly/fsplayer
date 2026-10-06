/*****************************************************************************
 * ijk_heic_tile_overlay.h
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

/*
 * Shared HEIC tile-grid accumulation logic used by the overlay
 * (ijksdl/ffmpeg/ijksdl_vout_overlay_ffmpeg.c) for software and VideoToolbox
 * hardware frames alike.
 *
 * A tile-grid HEIC image is decoded as a sequence of tile AVFrames, each
 * carrying FSTileGridMetadata via frame->opaque_ref. This accumulator gathers
 * the tiles into slots until the whole grid is complete; the renderer then
 * pulls the per-tile AVFrames out and composites them onto the canvas.
 *
 * All routines are no-ops / wrapped by IS_TILEGRID_HEIC_ENABLED at the call
 * sites; this header/impl is only compiled meaningfully under FFmpeg 7.
 */

#ifndef IJKSDL__APPLE__IJK_HEIC_TILE_OVERLAY_H
#define IJKSDL__APPLE__IJK_HEIC_TILE_OVERLAY_H

#include "ijksdl_vout.h"
#include "ijksdl_inc_ffmpeg.h"

struct FSTileSlot;

/* Tile-grid accumulation state. Embed one of these in the overlay's private
 * SDL_VoutOverlay_Opaque struct and forward all tile calls to the helpers. */
typedef struct FSTileAccumulator {
    int         tile_mode;       // 1 表示当前正在累积 tile
    int         tile_expected;   // 期望总数（grid->nb_tiles）
    int         tile_received;   // 已收到并存入槽位的 tile 数
    int         tile_ready;      // 1 表示已攒齐、可显示
    int         tile_canvas_w;
    int         tile_canvas_h;
    struct FSTileSlot *tiles;    // 长度 tile_expected
} FSTileAccumulator;

/* Release all retained tile frames and reset the accumulator to empty. */
void fs_tile_acc_free(FSTileAccumulator *acc);

/*
 * Try to consume `frame` as a HEIC tile.
 *   returns 1  -> frame was a tile and has been accumulated; caller should
 *                 return success without running its single-frame path.
 *   returns 0  -> frame is not a tile (no/invalid metadata); caller should
 *                 fall through to its normal single-frame handling. Any prior
 *                 tile state has been cleared and the overlay's is_tile_grid
 *                 field reset.
 *   returns <0 -> hard error (allocation failure); caller should propagate.
 * Updates overlay->is_tile_grid as appropriate. Canvas dimensions live in the
 * accumulator; read them via fs_tile_acc_get_canvas.
 */
int fs_tile_acc_fill(SDL_VoutOverlay *overlay, FSTileAccumulator *acc, const AVFrame *frame);

/* 1 while tiles are still being gathered (grid not yet complete). */
int fs_tile_acc_is_pending(const FSTileAccumulator *acc);

/* Number of tiles received so far. */
int fs_tile_acc_count(const FSTileAccumulator *acc);

/* Full tile-grid canvas dimensions. Writes 0 when not in tile mode. */
void fs_tile_acc_get_canvas(const FSTileAccumulator *acc, int *out_w, int *out_h);

/* Borrow the accumulated tile AVFrames (owned by the accumulator) and their
 * canvas placement. Writes up to max_count entries, returns the count written. */
int fs_tile_acc_get_avframes(const FSTileAccumulator *acc,
                             AVFrame **out_frames,
                             int *out_x, int *out_y,
                             int *out_w, int *out_h,
                             int max_count);

#endif /* IJKSDL__APPLE__IJK_HEIC_TILE_OVERLAY_H */
