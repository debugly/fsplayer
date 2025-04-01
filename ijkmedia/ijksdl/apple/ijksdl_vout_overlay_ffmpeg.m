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

#define USE_VIMAGE_ACCELERATE 0

#if USE_VIMAGE_ACCELERATE
#import <Accelerate/Accelerate.h>
#endif

struct SDL_VoutOverlay_Opaque {
    SDL_mutex *mutex;
    Uint16 pitches[AV_NUM_DATA_POINTERS];

    CVPixelBufferRef pixelBuffer;
    CVPixelBufferPoolRef pixelBufferPool;
};

static SDL_Class g_vout_overlay_ffmpeg_class = {
    .name = "FFmpegVoutOverlay",
};

static NSDictionary* prepareCVPixelBufferAttibutes(const int format,const bool fullRange, const int h, const int w)
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
        ALOGE("unsupported pixel format:%s!",pd->name);
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
    [attributes setObject:@(YES) forKey:(NSString*)kCVPixelBufferOpenGLCompatibilityKey];
    
    return attributes;
}

static CVReturn createCVPixelBufferPoolFromAVFrame(CVPixelBufferPoolRef * poolRef, int width, int height, int format)
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

static CVPixelBufferRef createCVPixelBufferFromAVFrame(const AVFrame *frame,CVPixelBufferPoolRef poolRef)
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

static bool check_object(SDL_VoutOverlay* object, const char *func_name)
{
    if (!object || !object->opaque || !object->opaque_class) {
        ALOGE("%s: invalid pipeline\n", func_name);
        return false;
    }

    if (object->opaque_class != &g_vout_overlay_ffmpeg_class) {
        ALOGE("%s.%s: unsupported method\n", object->opaque_class->name, func_name);
        return false;
    }

    return true;
}

CVPixelBufferRef SDL_VoutFFmpeg_GetCVPixelBufferRef(SDL_VoutOverlay *overlay)
{
    if (!check_object(overlay, __func__))
        return NULL;

    SDL_VoutOverlay_Opaque *opaque = overlay->opaque;
    return opaque->pixelBuffer;
}

static void func_free_l(SDL_VoutOverlay *overlay)
{
    SDLTRACE("SDL_Overlay(ffmpeg): overlay_free_l(%p)\n", overlay);
    if (!overlay)
        return;

    SDL_VoutOverlay_Opaque *opaque = overlay->opaque;
    if (!opaque)
        return;

    if (opaque->pixelBuffer) {
        CVPixelBufferRelease(opaque->pixelBuffer);
        opaque->pixelBuffer = NULL;
    }
    
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
    if (overlay) {
        SDL_VoutOverlay_Opaque *opaque = overlay->opaque;
        
        if (opaque->pixelBuffer) {
            CVPixelBufferRelease(opaque->pixelBuffer);
            opaque->pixelBuffer = NULL;
        }
        
        CVPixelBufferPoolRef poolRef = NULL;
        if (opaque->pixelBufferPool) {
            NSDictionary *attributes = (__bridge NSDictionary *)CVPixelBufferPoolGetPixelBufferAttributes(opaque->pixelBufferPool);
            int _width = [[attributes objectForKey:(NSString*)kCVPixelBufferWidthKey] intValue];
            int _height = [[attributes objectForKey:(NSString*)kCVPixelBufferHeightKey] intValue];
            if (frame->width == _width && frame->height == _height) {
                poolRef = opaque->pixelBufferPool;
            }
        }
        
        CVPixelBufferRef pixel_buffer = createCVPixelBufferFromAVFrame(frame, poolRef);
        if (pixel_buffer) {
            opaque->pixelBuffer = pixel_buffer;
            if (CVPixelBufferIsPlanar(pixel_buffer)) {
                int planes = (int)CVPixelBufferGetPlaneCount(pixel_buffer);
                for (int i = 0; i < planes; i ++) {
                    overlay->pitches[i] = CVPixelBufferGetWidthOfPlane(pixel_buffer, i);
                }
            } else {
                overlay->pitches[0] = CVPixelBufferGetWidth(pixel_buffer);
            }
            return 0;
        }
    }
    return -100;
}

struct SDL_Vout_Opaque {
    void *cvPixelBufferPool;
    int cv_format;
};

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
    
    SDL_Vout_Opaque * voutOpaque = display->opaque;
    if (display->cvpixelbufferpool && !voutOpaque->cvPixelBufferPool) {
        CVPixelBufferPoolRef cvPixelBufferPool = NULL;
        createCVPixelBufferPoolFromAVFrame(&cvPixelBufferPool, width, height, format);
        voutOpaque->cvPixelBufferPool = cvPixelBufferPool;
        voutOpaque->cv_format = format;
    }
    
    if (voutOpaque->cv_format == format) {
        opaque->pixelBufferPool = (CVPixelBufferPoolRef)voutOpaque->cvPixelBufferPool;
    }

    return overlay;
}
