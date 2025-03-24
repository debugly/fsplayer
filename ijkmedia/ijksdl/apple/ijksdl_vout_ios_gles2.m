/*
 * ijksdl_vout_ios_gles2.c
 *
 * Copyright (c) 2013 Bilibili
 * Copyright (c) 2013 Zhang Rui <bbcallen@gmail.com>
 *
 * This file is part of ijkPlayer.
 *
 * ijkPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * ijkPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with ijkPlayer; if not, write to the Free Software
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

#if TARGET_OS_OSX
#include "../mac/FSSDLGLView.h"
#import "ijksdl_gpu_opengl_macos.h"
#import <OpenGL/gl3.h>
#endif


@implementation FSOverlayAttach

- (void)dealloc
{
    if (self.videoPicture) {
        CVPixelBufferRelease(self.videoPicture);
        self.videoPicture = NULL;
    }
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

static CVPixelBufferRef SDL_Overlay_getCVPixelBufferRef(SDL_VoutOverlay *overlay)
{
    switch (overlay->format) {
        case SDL_FCC__VTB:
            return SDL_VoutFFmpeg_HW_GetCVPixelBufferRef(overlay);
        case SDL_FCC__FFVTB:
            return SDL_VoutFFmpeg_GetCVPixelBufferRef(overlay);
        default:
            return NULL;
    }
}

static int vout_display_overlay_l(SDL_Vout *vout, SDL_VoutOverlay *overlay, SDL_TextureOverlay *sub_overlay)
{
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

    if (overlay->w <= 0 || overlay->h <= 0) {
        ALOGE("vout_display_overlay_l: invalid overlay dimensions(%d, %d)\n", overlay->w, overlay->h);
        return -3;
    }

    if (SDL_FCC__VTB != overlay->format && SDL_FCC__FFVTB != overlay->format) {
        ALOGE("vout_display_overlay_l: invalid format:%d\n",overlay->format);
        return -4;
    }
    
    CVPixelBufferRef videoPic = SDL_Overlay_getCVPixelBufferRef(overlay);
    if (videoPic) {
        FSOverlayAttach *attach = [[FSOverlayAttach alloc] init];
        attach.w = overlay->w;
        attach.h = overlay->h;
        
        attach.pixelW = (int)CVPixelBufferGetWidth(videoPic);
        attach.pixelH = (int)CVPixelBufferGetHeight(videoPic);
        attach.fps    = overlay->fps;
        attach.sarNum = overlay->sar_num;
        attach.sarDen = overlay->sar_den;
        attach.autoZRotate = overlay->auto_z_rotate_degrees;
        
        attach.videoPicture = CVPixelBufferRetain(videoPic);
        attach.overlay = SDL_TextureOverlay_Retain(sub_overlay);
        return [gl_view displayAttach:attach];
    } else {
        ALOGE("vout_display_overlay_l: no video picture.\n");
        return -5;
    }
}

static int vout_display_overlay(SDL_Vout *vout, SDL_VoutOverlay *overlay, SDL_TextureOverlay *sub_overlay)
{
    @autoreleasepool {
        SDL_LockMutex(vout->mutex);
        int retval = vout_display_overlay_l(vout, overlay, sub_overlay);
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

#if TARGET_OS_OSX
@interface _IJKSDLGLTextureWrapper : NSObject<FSSDLSubtitleTextureWrapper>

@property(nonatomic) GLuint texture;
@property(nonatomic) int w;
@property(nonatomic) int h;

@end

@implementation _IJKSDLGLTextureWrapper

- (void)dealloc
{
    if (_texture) {
        glDeleteTextures(1, &_texture);
        _texture = 0;
    }
}

- (GLuint)texture
{
    return _texture;
}

- (instancetype)initWith:(uint32_t)texture w:(int)w h:(int)h
{
    self = [super init];
    if (self) {
        self.w = w;
        self.h = h;
        self.texture = texture;
    }
    return self;
}

@end

id<FSSDLSubtitleTextureWrapper> FSSDL_crate_openglTextureWrapper(uint32_t texture, int w, int h)
{
    return [[_IJKSDLGLTextureWrapper alloc] initWith:texture w:w h:h];
}
#endif

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
#if TARGET_OS_OSX
    if ([context isKindOfClass:[NSOpenGLContext class]]) {
        return SDL_CreateGPU_WithGLContext(context);
    } else if (context){
        if (@available(macOS 10.13, iOS 11.0, tvOS 12.0, *)) {
            return SDL_CreateGPU_WithMTLDevice(context);
        } else {
            ALOGE("this version can't use metal!");
            assert(0);
        }
    }
#else
    return SDL_CreateGPU_WithMTLDevice(context);
#endif
    return NULL;
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
        bmi = kCGBitmapByteOrderDefault | kCGImageAlphaNoneSkipLast;
    } else {
        bmi = kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst;
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
