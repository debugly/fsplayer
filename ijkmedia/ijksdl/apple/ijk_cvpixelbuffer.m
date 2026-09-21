/*
 * ijk_cvpixelbuffer.m
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

#include "ijk_cvpixelbuffer.h"
#include "../ijksdl_log.h"
#include <libavutil/hwcontext_videotoolbox.h>

#define USE_VIMAGE_ACCELERATE 0

#if USE_VIMAGE_ACCELERATE
#import <Accelerate/Accelerate.h>
#endif

static NSDictionary* prepareCVPixelBufferAttibutes(const int format, const bool fullRange, const int h, const int w)
{
    //CoreVideo does not provide support for all of these formats; this list just defines their names.
    int pixelFormatType = 0;

    if (format == AV_PIX_FMT_RGB24) {
        pixelFormatType = kCVPixelFormatType_24RGB;
    } else if (format == AV_PIX_FMT_ARGB || format == AV_PIX_FMT_0RGB) {
        pixelFormatType = kCVPixelFormatType_32ARGB;
    } else if (format == AV_PIX_FMT_NV12) {
        pixelFormatType = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    } else if (format == AV_PIX_FMT_BGRA || format == AV_PIX_FMT_BGR0) {
        pixelFormatType = kCVPixelFormatType_32BGRA;
    } else if (format == AV_PIX_FMT_YUV420P) {
        pixelFormatType = kCVPixelFormatType_420YpCbCr8PlanarFullRange;
    } else if (format == AV_PIX_FMT_YUVJ420P) {
        pixelFormatType = kCVPixelFormatType_420YpCbCr8Planar;
    } else if (format == AV_PIX_FMT_UYVY422) {
        pixelFormatType = kCVPixelFormatType_422YpCbCr8;
    } else if (format == AV_PIX_FMT_YUYV422) {
        pixelFormatType = fullRange ? kCVPixelFormatType_422YpCbCr8FullRange : kCVPixelFormatType_422YpCbCr8_yuvs;
    } else if (format == AV_PIX_FMT_P010) {
        pixelFormatType = fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    } else if (format == AV_PIX_FMT_P216) {
        pixelFormatType = kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange;
    } else if (format == AV_PIX_FMT_P416) {
        pixelFormatType = kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange;
    } else if (format == AV_PIX_FMT_AYUV64) {
        pixelFormatType = kCVPixelFormatType_4444AYpCbCr16;
    }
//    else if (format == AV_PIX_FMT_YUV444P10) {
//       pixelFormatType = kCVPixelFormatType_444YpCbCr10;
//    } else if (format == AV_PIX_FMT_NV16) {
//       pixelFormatType = fullRange ? kCVPixelFormatType_422YpCbCr8BiPlanarFullRange : kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange;
//    }
    //    kCVReturnInvalidPixelFormat
//    else if (format == AV_PIX_FMT_BGR24) {
//        pixelFormatType = kCVPixelFormatType_24BGR;
//    }
//    else if (format == AV_PIX_FMT_RGB565BE) {
//        pixelFormatType = kCVPixelFormatType_16BE565;
//    } else if (format == AV_PIX_FMT_RGB565LE) {
//        pixelFormatType = kCVPixelFormatType_16LE565;
//    }
//    else if (format == AV_PIX_FMT_RGB0 || format == AV_PIX_FMT_RGBA) {
//        pixelFormatType = kCVPixelFormatType_32RGBA;
//    }
//    RGB555 可以创建出 CVPixelBuffer，但是显示时失败了。
//    else if (format == AV_PIX_FMT_RGB555BE) {
//        pixelFormatType = kCVPixelFormatType_16BE555;
//    } else if (format == AV_PIX_FMT_RGB555LE) {
//        pixelFormatType = kCVPixelFormatType_16LE555;
//    }
    else {
        enum AVPixelFormat const avformat = format;
        const AVPixFmtDescriptor *pd = av_pix_fmt_desc_get(avformat);
        ALOGE("unsupported pixel format:%s!", pd->name);
        return nil;
    }

    const int linesize = 32;//FFmpeg 解码数据对齐是32，这里期望CVPixelBuffer也能使用32对齐，但实际来看却是64！
    NSMutableDictionary*attributes = [NSMutableDictionary dictionary];
    [attributes setObject:@(pixelFormatType) forKey:(NSString*)kCVPixelBufferPixelFormatTypeKey];
    [attributes setObject:[NSNumber numberWithInt:w] forKey:(NSString*)kCVPixelBufferWidthKey];
    [attributes setObject:[NSNumber numberWithInt:h] forKey:(NSString*)kCVPixelBufferHeightKey];
    [attributes setObject:@(linesize) forKey:(NSString*)kCVPixelBufferBytesPerRowAlignmentKey];
    [attributes setObject:[NSDictionary dictionary] forKey:(NSString*)kCVPixelBufferIOSurfacePropertiesKey];
    [attributes setObject:@(YES) forKey:(NSString*)kCVPixelBufferMetalCompatibilityKey];

    return attributes;
}

CVReturn FSCVPixelBufferPoolCreateForAVFrame(CVPixelBufferPoolRef *poolRef, int width, int height, int format)
{
    if (NULL == poolRef) {
        return kCVReturnInvalidArgument;
    }

    CVReturn result = kCVReturnError;
    //FIXME TODO
    const bool fullRange = true;
    NSDictionary * attributes = prepareCVPixelBufferAttibutes(format, fullRange, height, width);

    result = CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef) attributes, poolRef);

    if (result != kCVReturnSuccess) {
        ALOGE("CVPixelBufferCreate Failed:%d\n", result);
    }
    return result;
}

CVPixelBufferPoolRef FSSwPixelBufferPoolEnsure(FSSwPixelBufferPool *p, int width, int height, int format)
{
    if (NULL == p) {
        return NULL;
    }
    if (!p->pool ||
        p->width != width ||
        p->height != height ||
        p->format != format) {
        if (p->pool) {
            CVPixelBufferPoolRelease(p->pool);
            p->pool = NULL;
        }
        CVPixelBufferPoolRef pool = NULL;
        if (FSCVPixelBufferPoolCreateForAVFrame(&pool, width, height, format) == kCVReturnSuccess) {
            p->pool   = pool;
            p->width  = width;
            p->height = height;
            p->format = format;
        }
    }
    return p->pool;
}

void FSSwPixelBufferPoolRelease(FSSwPixelBufferPool *p)
{
    if (NULL == p) {
        return;
    }
    if (p->pool) {
        CVPixelBufferPoolRelease(p->pool);
        p->pool = NULL;
    }
    p->width = p->height = p->format = 0;
}

#if USE_VIMAGE_ACCELERATE
NS_INLINE size_t  pixelSizeForCV(CVPixelBufferRef pixelBuffer) {
    size_t pixelSize = 0;   // For vImageCopyBuffer()
    {
        NSString* kBitsPerBlock = (__bridge NSString*)kCVPixelFormatBitsPerBlock;
        NSString* kBlockWidth = (__bridge NSString*)kCVPixelFormatBlockWidth;
        NSString* kBlockHeight = (__bridge NSString*)kCVPixelFormatBlockHeight;

        OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
        CFDictionaryRef pfDict = CVPixelFormatDescriptionCreateWithPixelFormatType(kCFAllocatorDefault, pixelFormat);
        NSDictionary* dict = CFBridgingRelease(pfDict);

        int numBitsPerBlock = ((NSNumber*)dict[kBitsPerBlock]).intValue;
        int numWidthPerBlock = MAX(1,((NSNumber*)dict[kBlockWidth]).intValue);
        int numHeightPerBlock = MAX(1,((NSNumber*)dict[kBlockHeight]).intValue);
        int numPixelPerBlock = numWidthPerBlock * numHeightPerBlock;
        if (numPixelPerBlock) {
            pixelSize = ceil(numBitsPerBlock / numPixelPerBlock / 8.0);
        }
    }
    return pixelSize;
}
#endif

CVPixelBufferRef FSCVPixelBufferCreateFromAVFrame(const AVFrame *frame, CVPixelBufferPoolRef poolRef)
{
    if (NULL == frame) {
        return NULL;
    }

    const int w = frame->width;
    const int h = frame->height;
    const int format = frame->format;

    if (NULL == frame || w == 0 || h == 0) {
        return NULL;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn result = kCVReturnError;

    if (poolRef) {
        result = CVPixelBufferPoolCreatePixelBuffer(NULL, poolRef, &pixelBuffer);
        if (kCVReturnSuccess != result) {
            ALOGE("Overly FFmpeg Create CVPixelBuffer Failed using pool:%d\n", result);
        }
    }

    if (kCVReturnSuccess != result) {
        //AVCOL_RANGE_MPEG对应tv，AVCOL_RANGE_JPEG对应pc
        //Y′ values are conventionally shifted and scaled to the range [16, 235] (referred to as studio swing or "TV levels") rather than using the full range of [0, 255] (referred to as full swing or "PC levels").
        //https://en.wikipedia.org/wiki/YUV#Numerical_approximations

        const bool fullRange = frame->color_range == AVCOL_RANGE_JPEG;
        NSDictionary* attributes = prepareCVPixelBufferAttibutes(format, fullRange, h, w);

        if (!attributes) {
            ALOGE("Overly FFmpeg Create CVPixelBuffer Failed: no attributes\n");
            return NULL;
        }
        const int pixelFormatType = [attributes[(NSString*)kCVPixelBufferPixelFormatTypeKey] intValue];

        result = CVPixelBufferCreate(kCFAllocatorDefault,
                                     w,
                                     h,
                                     pixelFormatType,
                                     (__bridge CFDictionaryRef)(attributes),
                                     &pixelBuffer);
    }

    if (kCVReturnSuccess == result) {
        av_vt_pixbuf_set_attachments(NULL, pixelBuffer, frame);

        int planes = 1;
        if (CVPixelBufferIsPlanar(pixelBuffer)) {
            planes = (int)CVPixelBufferGetPlaneCount(pixelBuffer);
        }

        CVPixelBufferLockBaseAddress(pixelBuffer,0);
        for (int p = 0; p < planes; p++) {
            uint8_t *src = frame->data[p];
            uint8_t *dst = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, p);
            if (!src || !dst) {
                continue;
            }

            int src_linesize = (int)frame->linesize[p];
            int dst_linesize = (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, p);
            int height = (int)CVPixelBufferGetHeightOfPlane(pixelBuffer, p);
#if USE_VIMAGE_ACCELERATE
            int width  = (int)CVPixelBufferGetWidthOfPlane(pixelBuffer, p);
            vImage_Buffer sourceBuffer = {0};
            sourceBuffer.data = src;
            sourceBuffer.width = frame->width;
            sourceBuffer.height = frame->height;
            sourceBuffer.rowBytes = (int)frame->linesize[p];

            vImage_Buffer targetBuffer = {0};
            targetBuffer.data = dst;
            targetBuffer.width = CVPixelBufferGetWidth(pixelBuffer);
            targetBuffer.height = CVPixelBufferGetHeight(pixelBuffer);
            targetBuffer.rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, p);

            const AVPixFmtDescriptor *fd = av_pix_fmt_desc_get(frame->format);
            size_t pixelSize = ceil(fd->comp[p].depth/8.0);
//            av_get_bits_per_pixel(fd);
//            targetBuffer.rowBytes/targetBuffer.width;//pixelSizeForCV(pixelBuffer);
            if (src && dst) {
                assert(pixelSize > 0);

                vImage_Error convErr = kvImageNoError;
                //crash：EXC_BAD_ACCESS
                convErr = vImageCopyBuffer(&sourceBuffer, &targetBuffer,
                                           pixelSize, kvImageDoNotTile);
                if (convErr != kvImageNoError) {
                    NSLog(@"-------------------");
                }
            }
#else
            if (src_linesize == dst_linesize) {
                memcpy(dst, src, dst_linesize * height);
            } else {
                int bytewidth = MIN(src_linesize, dst_linesize);
                av_image_copy_plane(dst, dst_linesize, src, src_linesize, bytewidth, height);
            }
#endif
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        return pixelBuffer;
    } else {
        ALOGE("Overly FFmpeg Create CVPixelBuffer Failed:%d\n", result);
        return NULL;
    }
}
