/*****************************************************************************
 * ijksdl_vout.c
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

#include "ijksdl_vout.h"
#include <stdlib.h>

#include <assert.h>
#include "ijksdl_image_convert.h"

#if defined(__ANDROID__)
#include <android/native_window_jni.h>
#endif

#if defined(__APPLE__)
#include <libavutil/pixdesc.h>
#endif

typedef struct _SDL_Image_Converter
{
    struct SwsContext *sws_ctx;
    AVFrame *frame;
    AVBufferRef *frame_buffer;
    int frame_buffer_size;
}_SDL_Image_Converter;

#if defined(__APPLE__)
/*
 * 把源帧的 alpha 通道补回转换后的目标帧。
 *
 * 为什么要自己补：FFmpeg 是带 --disable-swscale-alpha 构建的（FFToolChain 里
 * module-*.sh 都有这一项，为了省体积），swscale 在这种情况下会忽略 alpha，
 * 转换结果里 alpha 恒为 255——于是「透明视频」（webm/VP9、ProRes4444、rawvideo
 * yuva*、png/rgba 等）在软解 + CPU 转格式之后整块变成不透明，底层视图透不出来
 * （issue #56 的透明背景只剩黑边可见就是这个原因）。alpha 只是逐像素搬运，
 * 不涉及色彩运算，所以这里直接读源帧的 alpha 组件写进目标帧即可。
 *
 * 只处理目标为 8bit 打包 RGB（BGRA/RGBA/ARGB/ABGR，渲染器靠它做混合）的情况；
 * 源可以是独立的 alpha 平面（yuva420p/yuva444p10/12/16 ...），也可以是打包在
 * 第 4 个分量里的格式（argb/rgba/...）。
 */
static void fs_merge_alpha_channel(const AVFrame *src, const AVFrame *dst)
{
    const AVPixFmtDescriptor *src_desc = av_pix_fmt_desc_get(src->format);
    const AVPixFmtDescriptor *dst_desc = av_pix_fmt_desc_get(dst->format);
    if (!src_desc || !dst_desc) {
        return;
    }
    if (!(src_desc->flags & AV_PIX_FMT_FLAG_ALPHA) || !(dst_desc->flags & AV_PIX_FMT_FLAG_ALPHA)) {
        return;
    }
    const AVComponentDescriptor *da = &dst_desc->comp[3];
    const AVComponentDescriptor *sa = &src_desc->comp[3];
    // 目标只支持 8bit 打包 RGB（step 4 / depth 8），其他情况保持原样。
    if (da->step != 4 || da->depth != 8 || !dst->data[0]) {
        return;
    }

    const int w = dst->width;
    const int h = dst->height;
    uint8_t *dst_data = dst->data[0];
    const int dst_stride = dst->linesize[0];

    if (src_desc->flags & AV_PIX_FMT_FLAG_PLANAR) {
        const uint8_t *src_data = src->data[sa->plane];
        if (!src_data || src->linesize[sa->plane] <= 0) {
            return;
        }
        const int src_stride = src->linesize[sa->plane];
        const int shift = sa->depth > 8 ? sa->depth - 8 : 0;
        for (int y = 0; y < h; y++) {
            const uint8_t *s = src_data + (size_t)y * src_stride;
            uint8_t *d = dst_data + (size_t)y * dst_stride + da->offset;
            if (shift == 0) {
                for (int x = 0; x < w; x++) {
                    d[x * da->step] = s[x];
                }
            } else {
                const uint16_t *s16 = (const uint16_t *)s;
                for (int x = 0; x < w; x++) {
                    d[x * da->step] = (uint8_t)(s16[x] >> shift);
                }
            }
        }
    } else {
        const uint8_t *src_data = src->data[0];
        if (!src_data || src->linesize[0] <= 0) {
            return;
        }
        const int src_stride = src->linesize[0];
        const int shift = sa->depth > 8 ? sa->depth - 8 : 0;
        for (int y = 0; y < h; y++) {
            const uint8_t *s = src_data + (size_t)y * src_stride;
            uint8_t *d = dst_data + (size_t)y * dst_stride + da->offset;
            if (shift == 0) {
                for (int x = 0; x < w; x++) {
                    d[x * da->step] = s[(size_t)x * sa->step + sa->offset];
                }
            } else {
                for (int x = 0; x < w; x++) {
                    const uint16_t v = ((const uint16_t *)(s + (size_t)x * sa->step))[sa->offset / 2];
                    d[x * da->step] = (uint8_t)(v >> shift);
                }
            }
        }
    }
}
#endif

void SDL_VoutFree(SDL_Vout *vout)
{
    if (!vout)
        return;

    _SDL_Image_Converter *convert = vout->image_converter;
    if (NULL != convert) {
        if (convert->sws_ctx) {
            sws_freeContext(convert->sws_ctx);
        }
        if (convert->frame) {
            av_frame_free(&convert->frame);
            av_buffer_unref(&convert->frame_buffer);
        }
        vout->image_converter = NULL;
    }
    
    if (vout->free_l) {
        vout->free_l(vout);
    } else {
        free(vout);
    }
}

void SDL_VoutFreeP(SDL_Vout **pvout)
{
    if (!pvout)
        return;

    SDL_VoutFree(*pvout);
    *pvout = NULL;
}

int SDL_VoutDisplayYUVOverlay(SDL_Vout *vout, const Frame *frame, SDL_TextureOverlay *sub_overlay)
{
    if (vout && vout->display_overlay)
        return vout->display_overlay(vout, frame, sub_overlay);

    return -1;
}

int SDL_VoutConvertFrame(SDL_Vout *vout, int dst_format, const AVFrame *inFrame, const AVFrame **outFrame)
{
    if (!vout) {
        return -1;
    }
    
    if (inFrame->format == dst_format) {
        if (outFrame) {
            *outFrame = inFrame;
        }
        return 0;
    }
    
    _SDL_Image_Converter *convert = vout->image_converter;
    if (NULL == convert) {
        convert = malloc(sizeof(_SDL_Image_Converter));
        memset(convert, 0, sizeof(_SDL_Image_Converter));
        
        convert->frame = av_frame_alloc();
        
        av_frame_copy_props(convert->frame, inFrame);
        convert->frame->format = dst_format;
        
        vout->image_converter = convert;
        convert->frame_buffer = NULL;
        
        enum AVPixelFormat const in_avformat = inFrame->format;
        const AVPixFmtDescriptor *in_pd = av_pix_fmt_desc_get(in_avformat);
        
        enum AVPixelFormat const dst_avformat = dst_format;
        const AVPixFmtDescriptor *dst_pd = av_pix_fmt_desc_get(dst_avformat);
        ALOGI("convert pixel format:%s->%s",in_pd->name,dst_pd->name);
    }
    
    int frame_bytes = av_image_get_buffer_size(dst_format, inFrame->width, inFrame->height, 1);
    if (frame_bytes != convert->frame_buffer_size) {
        AVBufferRef *frame_buffer_ref;
        if (convert->frame_buffer != NULL) {
            if (av_buffer_realloc(&convert->frame_buffer, frame_bytes)) {
                return -2;
            }
            frame_buffer_ref = convert->frame_buffer;
        } else {
            frame_buffer_ref = av_buffer_alloc(frame_bytes);
        }
        if (!frame_buffer_ref) {
            return -3;
        }
        
        av_image_fill_arrays(convert->frame->data, convert->frame->linesize,
                             frame_buffer_ref->data, convert->frame->format, inFrame->width, inFrame->height, 1);
        
        convert->frame_buffer = frame_buffer_ref;
        convert->frame_buffer_size = frame_bytes;
    }
    
    //优先使用libyuv转换
    int r = ijk_image_convert(inFrame->width, inFrame->height,
                             dst_format, convert->frame->data, convert->frame->linesize,
                             inFrame->format, (const uint8_t**) inFrame->data, inFrame->linesize);
    
    //libyuv转换失败？
    if (r) {
        convert->sws_ctx = sws_getCachedContext(convert->sws_ctx, inFrame->width, inFrame->height,
                                  inFrame->format, inFrame->width, inFrame->height,
                                  convert->frame->format, SWS_BILINEAR, NULL, NULL, NULL);
        
        if (convert->sws_ctx == NULL) {
            ALOGE("sws_getCachedContext failed");
            return -4;
        }
        
        int scaled = sws_scale(convert->sws_ctx, (const uint8_t**) inFrame->data, inFrame->linesize,
                  0, inFrame->height, convert->frame->data, convert->frame->linesize);
        r = scaled == inFrame->height ? 0 : -6;
    }
    
    if (r == 0 && outFrame) {
        convert->frame->width  = inFrame->width;
        convert->frame->height = inFrame->height;
#if defined(__APPLE__)
        // swscale（--disable-swscale-alpha 构建）丢掉的 alpha 自己补回来。
        // 必须在 width/height 赋值之后：补 alpha 是按目标帧尺寸逐行搬运的。
        fs_merge_alpha_channel(inFrame, convert->frame);
#endif
        /* convert->frame is reused across frames, so av_frame_copy_props (called
         * once at converter creation) leaves a stale opaque_ref. Refresh it from
         * the current inFrame so per-frame metadata (e.g. HEIC tile-grid
         * FSTileGridMetadata) propagates through the conversion. */
        av_buffer_unref(&convert->frame->opaque_ref);
        if (inFrame->opaque_ref) {
            convert->frame->opaque_ref = av_buffer_ref(inFrame->opaque_ref);
            if (!convert->frame->opaque_ref) {
                return -5;
            }
        }

        *outFrame = convert->frame;
    }
    
    return r;
}

SDL_VoutOverlay *SDL_Vout_CreateOverlay(int width, int height, int src_format, SDL_Vout *vout)
{
    if (vout && vout->create_overlay)
        return vout->create_overlay(width, height, src_format, vout);

    return NULL;
}

int SDL_VoutLockYUVOverlay(SDL_VoutOverlay *overlay)
{
    if (overlay && overlay->lock)
        return overlay->lock(overlay);

    return -1;
}

int SDL_VoutUnlockYUVOverlay(SDL_VoutOverlay *overlay)
{
    if (overlay && overlay->unlock)
        return overlay->unlock(overlay);

    return -1;
}

void SDL_VoutFreeYUVOverlay(SDL_VoutOverlay *overlay)
{
    if (!overlay)
        return;
    if (overlay->free_l) {
        overlay->free_l(overlay);
    } else {
        free(overlay);
    }
}

int SDL_VoutFillFrameYUVOverlay(SDL_VoutOverlay *overlay, const AVFrame *frame)
{
    if (!overlay || !overlay->func_fill_frame)
        return -1;

    return overlay->func_fill_frame(overlay, frame);
}

#if IS_TILEGRID_HEIC_ENABLED
int SDL_VoutOverlay_IsTilePending(SDL_VoutOverlay *overlay)
{
    if (!overlay || !overlay->func_is_tile_pending)
        return 0;
    return overlay->func_is_tile_pending(overlay);
}

int SDL_VoutOverlay_GetTileCount(SDL_VoutOverlay *overlay)
{
    if (!overlay || !overlay->func_get_tile_count)
        return 0;
    return overlay->func_get_tile_count(overlay);
}

int SDL_VoutOverlay_GetTileAVFrames(SDL_VoutOverlay *overlay,
                                    AVFrame **out_frames,
                                    int *out_x, int *out_y,
                                    int *out_w, int *out_h,
                                    int max_count)
{
    if (!overlay || !overlay->func_get_tile_avframes)
        return 0;
    return overlay->func_get_tile_avframes(overlay, out_frames, out_x, out_y, out_w, out_h, max_count);
}

void SDL_VoutOverlay_GetTileCanvas(SDL_VoutOverlay *overlay, int *out_w, int *out_h)
{
    if (!overlay || !overlay->func_get_tile_canvas)
        return;
    return overlay->func_get_tile_canvas(overlay, out_w, out_h);
}

#endif
