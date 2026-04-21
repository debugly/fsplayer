/*****************************************************************************
 * ff_heic_tile.h
 *****************************************************************************
 * HEIC tile grid metadata shared between ff_ffplay (packet/frame layer) and
 * the overlay implementations (ijksdl_vout_overlay_ffmpeg.m, etc.).
 *
 * A pointer to this struct is attached to AVPacket::opaque_ref (and, with
 * AV_CODEC_FLAG_COPY_OPAQUE, propagated to AVFrame::opaque_ref) so that the
 * overlay layer can know which tile slot a decoded frame occupies and how to
 * composite it into the final canvas.
 *****************************************************************************/

#ifndef FSPLAYER_FF_HEIC_TILE_H
#define FSPLAYER_FF_HEIC_TILE_H

typedef struct FSTileGridMetadata {
    int tile_index;     // 0-based index within the tile-grid group
    int nb_tiles;       // total tile count of this group
    int canvas_w;       // full canvas width  (grid->coded_width) contain padding
    int canvas_h;       // full canvas height (grid->coded_height) contain padding
    int w;              // display width  (grid->width)
    int h;              // display height (grid->height)
    int tile_x;         // tile's top-left x on canvas
    int tile_y;         // tile's top-left y on canvas
    int tile_w;         // tile's intrinsic width
    int tile_h;         // tile's intrinsic height
} FSTileGridMetadata;

#endif /* FSPLAYER_FF_HEIC_TILE_H */
