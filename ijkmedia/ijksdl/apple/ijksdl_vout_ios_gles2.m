/*
 * ijksdl_vout_ios_gles2.c
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

#import "ijksdl_vout_ios_gles2.h"

#include <assert.h>
#include "ijksdl/ijksdl_vout.h"
#include "ijksdl/ijksdl_vout_internal.h"
#include "ijksdl_vout_overlay_ffmpeg.h"
#include "ijksdl_vout_overlay_ffmpeg_hw.h"
#include "ijkplayer/ff_subtitle_def.h"
#import "ijksdl_gpu_metal.h"
#include "ff_ffplay_def.h"

@implementation FSTilePiece

- (void)dealloc
{
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }
    if (_avframe) {
        av_frame_free(&self->_avframe);
    }
}

@end

@implementation FSOverlayAttach

- (void)dealloc
{
    if (self.videoPicture) {
        CVPixelBufferRelease(self.videoPicture);
        self.videoPicture = NULL;
    }
    if (self.avframe) {
        av_frame_free(&self->_avframe);
    }
    // FSTilePiece 内部 dealloc 自动释放其 pixelBuffer
    if (self.videoCVTextures) {
        for (id item in self.videoCVTextures) {
            CVMetalTextureRef texRef = (__bridge CVMetalTextureRef)item;
            if (texRef) {
                CFRelease(texRef);
            }
        }
        self.videoCVTextures = nil;
    }
    // FSTilePiece 内部 dealloc 自动释放其 pixelBuffer 与 cvTextures
    self.tilePieces = nil;
    self.subTexture = nil;
    if (self.overlay) {
        SDL_TextureOverlay_Release(&self->_overlay);
    }
}

- (id)subTexture
{
    if (self.overlay) {
        return (__bridge id)self.overlay->getTexture(self.overlay);
    } else {
        return nil;
    }
}

@end

struct SDL_Vout_Opaque {
    void *cvPixelBufferPool;
    int cv_format;
    __strong UIView<FSVideoRenderingProtocol> *gl_view;
};

static SDL_VoutOverlay *vout_create_overlay_l(int width, int height, int src_format, SDL_Vout *vout)
{
    switch (src_format) {
        case AV_PIX_FMT_VIDEOTOOLBOX:
            return SDL_VoutFFmpeg_HW_CreateOverlay(width, height, vout);
        default:
            return SDL_VoutFFmpeg_CreateOverlay(width, height, src_format, vout);
    }
}

static SDL_VoutOverlay *vout_create_overlay(int width, int height, int src_format, SDL_Vout *vout)
{
    SDL_LockMutex(vout->mutex);
    SDL_VoutOverlay *overlay = vout_create_overlay_l(width, height, src_format, vout);
    SDL_UnlockMutex(vout->mutex);
    return overlay;
}

static void vout_free_l(SDL_Vout *vout)
{
    if (!vout)
        return;
    
    SDL_Vout_Opaque *opaque = vout->opaque;
    if (opaque) {
        opaque->gl_view = nil;
        if (opaque->cvPixelBufferPool) {
            CVPixelBufferPoolRelease(opaque->cvPixelBufferPool);
            opaque->cvPixelBufferPool = NULL;
        }
    }
    
    SDL_Vout_FreeInternal(vout);
}

static int vout_display_overlay_l(SDL_Vout *vout, const Frame *frame, SDL_VoutOverlay *overlay, SDL_TextureOverlay *sub_overlay)
{
    // `frame` is the owning Frame from the player's picture queue. It carries the
    // display geometry (frame->w/h) the renderer scales to; pixel data still flows
    // through `overlay` (overlay->av_frame / tile AVFrames).

    SDL_Vout_Opaque *opaque = vout->opaque;
    UIView<FSVideoRenderingProtocol>* gl_view = opaque->gl_view;
    
    if (!gl_view) {
        ALOGE("vout_display_overlay_l: NULL gl_view\n");
        return -1;
    }
    
    if (!overlay) {
        FSOverlayAttach *attach = [[FSOverlayAttach alloc] init];
        attach.overlay = SDL_TextureOverlay_Retain(sub_overlay);
        return [gl_view displayAttach:attach];
    }

    if (!frame || frame->disp_w <= 0 || frame->disp_h <= 0) {
        ALOGE("vout_display_overlay_l: invalid frame dimensions(%d, %d)\n",
              frame ? frame->disp_w : -1, frame ? frame->disp_h : -1);
        return -3;
    }

//    if (SDL_FCC__VTB != overlay->format && SDL_FCC__FFVTB != overlay->format) {
//        ALOGE("vout_display_overlay_l: invalid format:%d\n",overlay->format);
//        return -4;
//    }
#if IS_TILEGRID_HEIC_ENABLED
    /* HEIC tile grid 路径：把所有 tile 的 AVFrame 打包到 FSOverlayAttach.tilePieces，
       渲染侧（FSMetalView）再把每个 AVFrame 转成 CVPixelBuffer 后合成。 */
    if (overlay->is_tile_grid) {
        int count = SDL_VoutOverlay_GetTileCount(overlay);
        if (count <= 0) {
            ALOGE("vout_display_overlay_l: tile-grid overlay with 0 tiles\n");
            return -5;
        }
        AVFrame **frames = (AVFrame **)calloc(count, sizeof(AVFrame *));
        int *xs = (int *)calloc(count, sizeof(int));
        int *ys = (int *)calloc(count, sizeof(int));
        int *ws = (int *)calloc(count, sizeof(int));
        int *hs = (int *)calloc(count, sizeof(int));
        int got = SDL_VoutOverlay_GetTileAVFrames(overlay, frames, xs, ys, ws, hs, count);

        FSOverlayAttach *attach = [[FSOverlayAttach alloc] init];
        attach.w = frame->disp_w;
        attach.h = frame->disp_h;
        attach.pixelW = overlay->tile_canvas_w;
        attach.pixelH = overlay->tile_canvas_h;
        attach.fps    = frame->fps;
        attach.sarNum = frame->sar.num;
        attach.sarDen = frame->sar.den;
        attach.autoZRotate = frame->auto_z_rotate_degrees;
        attach.videoPicture = NULL;

        int has_alpha = 0;
        NSMutableArray<FSTilePiece *> *pieces = [NSMutableArray arrayWithCapacity:got];
        for (int i = 0; i < got; i++) {
            if (!frames[i]) continue;
            // 获取像素格式描述符
            const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(frames[i]->format);
            if (desc && (desc->flags & AV_PIX_FMT_FLAG_ALPHA)) {
                has_alpha = 1;
            }
            FSTilePiece *p = [[FSTilePiece alloc] init];
            // Clone the tile frame (owned by attach); the renderer converts it to a
            // CVPixelBuffer. Mirrors the single-frame av_frame_clone below.
            p.avframe = av_frame_clone(frames[i]);
            p.x = xs[i]; p.y = ys[i];
            p.w = ws[i]; p.h = hs[i];
            [pieces addObject:p];
        }
        attach.tilePieces = pieces;
        attach.overlay = SDL_TextureOverlay_Retain(sub_overlay);
        attach.hasAlpha = has_alpha;
        free(frames); free(xs); free(ys); free(ws); free(hs);
        return [gl_view displayAttach:attach];
    }
#endif
    
    // The renderer consumes the decoded AVFrame directly: FSPlaceboView uploads it,
    // FSMetalView derives a CVPixelBuffer from it on the render thread. The dispatch
    // layer no longer pulls a CVPixelBuffer here (that logic moved into the renderer).
    // Both Apple overlay impls (VTB & software) publish the frame on overlay->av_frame,
    // so no format branch is needed to pick an accessor.
    AVFrame *av_frame = overlay->av_frame;

    if (av_frame) {
        int has_alpha = 0;
        // 获取像素格式描述符
        const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(av_frame->format);
        if (desc && (desc->flags & AV_PIX_FMT_FLAG_ALPHA)) {
            has_alpha = 1;
        }
        
        FSOverlayAttach *attach = [[FSOverlayAttach alloc] init];
        attach.w = frame->disp_w;
        attach.h = frame->disp_h;

        // pixelW/H default to the frame's coded size; renderers that need the padded
        // buffer dimensions (FSMetalView crop) overwrite these once they materialise
        // the CVPixelBuffer.
        attach.pixelW = av_frame->width;
        attach.pixelH = av_frame->height;
        attach.fps    = frame->fps;
        attach.sarNum = frame->sar.num;
        attach.sarDen = frame->sar.den;
        attach.autoZRotate = frame->auto_z_rotate_degrees;
        attach.hasAlpha = has_alpha;
        // Carry the full frame (with DoVi/HDR side data) to the renderer.
        attach.avframe = av_frame_clone(av_frame);
        attach.overlay = SDL_TextureOverlay_Retain(sub_overlay);
        return [gl_view displayAttach:attach];
    } else {
        ALOGE("vout_display_overlay_l: no video picture.\n");
        return -5;
    }
}

static int vout_display_overlay(SDL_Vout *vout, const Frame *frame, SDL_VoutOverlay *overlay, SDL_TextureOverlay *sub_overlay)
{
    @autoreleasepool {
        SDL_LockMutex(vout->mutex);
        int retval = vout_display_overlay_l(vout, frame, overlay, sub_overlay);
        SDL_UnlockMutex(vout->mutex);
        return retval;
    }
}

SDL_Vout *SDL_VoutIos_CreateForGLES2(void)
{
    SDL_Vout *vout = SDL_Vout_CreateInternal(sizeof(SDL_Vout_Opaque));
    if (!vout)
        return NULL;
    
    SDL_Vout_Opaque *opaque = vout->opaque;
    opaque->cv_format = -1;
    vout->create_overlay = vout_create_overlay;
    vout->free_l = vout_free_l;
    vout->display_overlay = vout_display_overlay;
    return vout;
}

static void SDL_VoutIos_SetGLView_l(SDL_Vout *vout, UIView<FSVideoRenderingProtocol>* view)
{
    SDL_Vout_Opaque *opaque = vout->opaque;
    if (opaque->gl_view != view) {
        opaque->gl_view = view;
    }
}

void SDL_VoutIos_SetGLView(SDL_Vout *vout, UIView<FSVideoRenderingProtocol>* view)
{
    SDL_LockMutex(vout->mutex);
    SDL_VoutIos_SetGLView_l(vout, view);
    SDL_UnlockMutex(vout->mutex);
}

SDL_TextureOverlay * SDL_TextureOverlay_Retain(SDL_TextureOverlay *t)
{
    if (t) {
        __atomic_add_fetch(&t->refCount, 1, __ATOMIC_RELEASE);
    }
    return t;
}

void SDL_TextureOverlay_Release(SDL_TextureOverlay **tp)
{
    if (tp) {
        if (*tp) {
            if (__atomic_add_fetch(&(*tp)->refCount, -1, __ATOMIC_RELEASE) == 0) {
                (*tp)->dealloc(*tp);
                free(*tp);
            }
        }
        *tp = NULL;
    }
}

void SDL_FBOOverlayFreeP(SDL_FBOOverlay **poverlay)
{
    if (poverlay) {
        if (*poverlay) {
            (*poverlay)->dealloc(*poverlay);
            free(*poverlay);
        }
        *poverlay = NULL;
    }
}

SDL_GPU *SDL_CreateGPU_WithContext(id context)
{
    return SDL_CreateGPU_WithMTLDevice(context);
}

void SDL_GPUFreeP(SDL_GPU **pgpu)
{
    if (pgpu) {
        if (*pgpu) {
            (*pgpu)->dealloc(*pgpu);
            free(*pgpu);
        }
        *pgpu = NULL;
    }
}

#if TARGET_OS_OSX
#pragma mark - save image for debug ass

static CGContextRef _CreateCGBitmapContext(size_t w, size_t h, size_t bpc, size_t bpp, size_t bpr, uint32_t bmi)
{
    assert(bpp != 24);
    /*
     AV_PIX_FMT_RGB24 bpp is 24! not supported!
     Crash:
     2020-06-06 00:08:20.245208+0800 FFmpegTutorial[23649:2335631] [Unknown process name] CGBitmapContextCreate: unsupported parameter combination: set CGBITMAP_CONTEXT_LOG_ERRORS environmental variable to see the details
     2020-06-06 00:08:20.245417+0800 FFmpegTutorial[23649:2335631] [Unknown process name] CGBitmapContextCreateImage: invalid context 0x0. If you want to see the backtrace, please set CG_CONTEXT_SHOW_BACKTRACE environmental variable.
     */
    //Update: Since 10.8, CGColorSpaceCreateDeviceRGB is equivalent to sRGB, and is closer to option 2)
    //CGColorSpaceCreateWithName(kCGColorSpaceSRGB)
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmapContext = CGBitmapContextCreate(
                                                       NULL,
                                                       w,
                                                       h,
                                                       bpc,
                                                       bpr,
                                                       colorSpace,
                                                       bmi
                                                       );
    
    CGColorSpaceRelease(colorSpace);
    return bitmapContext;
}

static NSError * mr_mkdirP(NSString *aDir)
{
    BOOL isDirectory = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:aDir isDirectory:&isDirectory]) {
        if (isDirectory) {
            return nil;
        } else {
            //remove the file
            [[NSFileManager defaultManager] removeItemAtPath:aDir error:NULL];
        }
    }
    //aDir is not exist
    NSError *err = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:aDir withIntermediateDirectories:YES attributes:nil error:&err];
    return err;
}

static NSString * mr_DirWithType(NSSearchPathDirectory directory,NSArray<NSString *>*pathArr)
{
    NSString *directoryDir = [NSSearchPathForDirectoriesInDomains(directory, NSUserDomainMask, YES) firstObject];
    NSString *aDir = directoryDir;
    for (NSString *dir in pathArr) {
        aDir = [aDir stringByAppendingPathComponent:dir];
    }
    if (mr_mkdirP(aDir)) {
        return nil;
    }
    return aDir;
}

static BOOL saveImageToFile(CGImageRef img,NSString *imgPath)
{
    CFStringRef imageUTType = NULL;
    NSString *fileType = [[imgPath pathExtension] lowercaseString];
    if ([fileType isEqualToString:@"jpg"] || [fileType isEqualToString:@"jpeg"]) {
        imageUTType = kUTTypeJPEG;
    } else if ([fileType isEqualToString:@"png"]) {
        imageUTType = kUTTypePNG;
    } else if ([fileType isEqualToString:@"tiff"]) {
        imageUTType = kUTTypeTIFF;
    } else if ([fileType isEqualToString:@"bmp"]) {
        imageUTType = kUTTypeBMP;
    } else if ([fileType isEqualToString:@"gif"]) {
        imageUTType = kUTTypeGIF;
    } else if ([fileType isEqualToString:@"pdf"]) {
        imageUTType = kUTTypePDF;
    }
    
    if (imageUTType == NULL) {
        imageUTType = kUTTypePNG;
    }
    
    CFStringRef key = kCGImageDestinationLossyCompressionQuality;
    CFStringRef value = CFSTR("0.5");
    const void * keys[] = {key};
    const void * values[] = {value};
    CFDictionaryRef opts = CFDictionaryCreate(CFAllocatorGetDefault(), keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    NSURL *fileUrl = [NSURL fileURLWithPath:imgPath];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef) fileUrl, imageUTType, 1, opts);
    CFRelease(opts);
    
    if (destination) {
        CGImageDestinationAddImage(destination, img, NULL);
        CGImageDestinationFinalize(destination);
        CFRelease(destination);
        return YES;
    } else {
        return NO;
    }
}

void SaveIMGToFile(uint8_t *data,int width,int height,IMG_FORMAT format, char *tag, int pts)
{
    const GLint bytesPerRow = width * 4;
    
    uint32_t bmi;
    if (format == IMG_FORMAT_RGBA) {
        bmi = (uint32_t)kCGBitmapByteOrderDefault | (uint32_t)kCGImageAlphaNoneSkipLast;
    } else {
        bmi = (uint32_t)kCGBitmapByteOrder32Little | (uint32_t)kCGImageAlphaPremultipliedFirst;
    }
    CGContextRef ctx = _CreateCGBitmapContext(width, height, 8, 32, bytesPerRow, bmi);
    if (ctx) {
        void * bitmapData = CGBitmapContextGetData(ctx);
        if (bitmapData) {
            memcpy(bitmapData, data, bytesPerRow * height);
            CGImageRef img = CGBitmapContextCreateImage(ctx);
            if (img) {
                NSString *dir = mr_DirWithType(NSPicturesDirectory, @[@"ijkplayer"]);
                if (!tag) {
                    tag = "";
                }
                if (pts == -1) {
                    pts = (int)CFAbsoluteTimeGetCurrent();
                }
                NSString *fileName = [NSString stringWithFormat:@"%s-%d.png",tag,pts];
                NSString *filePath = [dir stringByAppendingPathComponent:fileName];
                ALOGI("save img:%@",filePath);
                saveImageToFile(img, filePath);
                CFRelease(img);
            }
        }
        CGContextRelease(ctx);
    }
}
#endif
