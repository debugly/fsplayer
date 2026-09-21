/*
 * ijk_cvpixelbuffer.h
 *
 * Copyright (c) 2026 debugly <qianlongxu@gmail.com>
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

#ifndef FSSDL__IJK_CVPIXELBUFFER_H
#define FSSDL__IJK_CVPIXELBUFFER_H

#include "ijksdl/ffmpeg/ijksdl_inc_ffmpeg.h"
#import <CoreVideo/CoreVideo.h>

/*
 * Convert a software-decoded AVFrame into a CVPixelBuffer, copying the frame's
 * planes and stamping its color / Dolby Vision side data as CVBuffer attachments
 * (via av_vt_pixbuf_set_attachments), so downstream renderers can read colorspace,
 * range and transfer function from the buffer.
 *
 * When poolRef is non-NULL a buffer is drawn from that pool (its format must match
 * the frame); otherwise a standalone buffer is created from the frame's dimensions
 * and pixel format. Returns a +1 retained CVPixelBufferRef the caller owns, or NULL
 * on failure (e.g. unsupported pixel format).
 */
CVPixelBufferRef FSCVPixelBufferCreateFromAVFrame(const AVFrame *frame, CVPixelBufferPoolRef poolRef);

/*
 * Create a CVPixelBufferPool sized for width x height frames of the given AVPixelFormat.
 * Returns kCVReturnSuccess and writes the +1 owned pool into *poolRef on success.
 */
CVReturn FSCVPixelBufferPoolCreateForAVFrame(CVPixelBufferPoolRef *poolRef, int width, int height, int format);

/*
 * A CVPixelBufferPool paired with the frame geometry it was created for, so callers
 * converting a stream of software-decoded AVFrames can reuse one pool and only recreate
 * it when the frame's dimensions or pixel format change. Zero-initialise before first use
 * (e.g. as an ivar); VideoToolbox frames don't need it (their buffer is frame->data[3]).
 */
typedef struct FSSwPixelBufferPool {
    CVPixelBufferPoolRef pool;
    int width;
    int height;
    int format;
} FSSwPixelBufferPool;

/*
 * Ensure the pool matches (width, height, format), recreating it on mismatch. Returns the
 * current pool (may be NULL if creation failed). The pool stays owned by the struct.
 */
CVPixelBufferPoolRef FSSwPixelBufferPoolEnsure(FSSwPixelBufferPool *p, int width, int height, int format);

/*
 * Release the pool and reset the cached geometry. Safe to call on a zero-initialised or
 * already-released struct.
 */
void FSSwPixelBufferPoolRelease(FSSwPixelBufferPool *p);

#endif
