/*
 * Copyright (c) 2016 Bilibili
 * copyright (c) 2016 Zhang Rui <bbcallen@gmail.com>
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

//https://github.com/mpv-player/mpv

//vda: add support for nv12 image formats
//
//The hardware always decodes to nv12 so using this image format causes less cpu
//usage than uyvy (which we are currently using, since Apple examples and other
//free software use that). The reduction in cpu usage can add up to quite a bit,
//especially for 4k or high fps video.
//
//This needs an accompaning commit in libavcodec.
//提交：
//5258c012febdfba0ef56ad8ce6f7cb003611c47b

#ifndef FSSDL__renderer_pixfmt__INTERNAL__H
#define FSSDL__renderer_pixfmt__INTERNAL__H

#import <CoreVideo/CoreVideo.h>

#define USE_LEGACY_OPENGL 0

#if TARGET_OS_OSX
    #define OpenGLTextureCacheRef   CVOpenGLTextureCacheRef
    #define OpenGLTextureRef        CVOpenGLTextureRef
    #define OpenGLTextureCacheFlush CVOpenGLTextureCacheFlush
    #define OpenGLTextureGetTarget  CVOpenGLTextureGetTarget
    #define OpenGLTextureGetName    CVOpenGLTextureGetName
    #define OpenGL_RED_EXT          GL_RED
    #define OpenGL_RG_EXT           GL_RG
#else
    #define OpenGLTextureCacheRef   CVOpenGLESTextureCacheRef
    #define OpenGLTextureRef        CVOpenGLESTextureRef
    #define OpenGLTextureCacheFlush CVOpenGLESTextureCacheFlush
    #define OpenGLTextureGetTarget  CVOpenGLESTextureGetTarget
    #define OpenGLTextureGetName    CVOpenGLESTextureGetName
    #define OpenGL_RED_EXT          GL_RED_EXT
    #define OpenGL_RG_EXT           GL_RG_EXT
#endif

#define MP_MAX_PLANES 3
#define MP_ARRAY_SIZE(s) (sizeof(s) / sizeof((s)[0]))

struct vt_gl_plane_format {
    GLenum gl_format;
    GLenum gl_type;
    GLenum gl_internal_format;
};

struct vt_format {
    uint32_t cvpixfmt;
    int planes;
    struct vt_gl_plane_format gl[MP_MAX_PLANES];
};

static struct vt_format vt_formats[] = {
    {
        .cvpixfmt = kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
        .planes = 2,
        .gl = {
            { GL_RED, GL_UNSIGNED_BYTE, GL_RED },
            { GL_RG,  GL_UNSIGNED_BYTE, GL_RG }
        }
    },
    {
        .cvpixfmt = kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
        .planes = 2,
        .gl = {
            { GL_RED, GL_UNSIGNED_BYTE, GL_RED },
            { GL_RG,  GL_UNSIGNED_BYTE, GL_RG }
        }
    },
    {
        .cvpixfmt = kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
        .planes = 2,
        .gl = {
            { GL_RED, GL_UNSIGNED_BYTE, GL_RED },
            { GL_RG,  GL_UNSIGNED_BYTE, GL_RG }
        }
    },
    {
        .cvpixfmt = kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
        .planes = 2,
        .gl = {
            { GL_RED, GL_UNSIGNED_BYTE, GL_RED },
            { GL_RG,  GL_UNSIGNED_BYTE, GL_RG }
        }
    },
    {
        .cvpixfmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        .planes = 2,
        .gl = {
//           when use RED/RG,the fsh must use r and rg!
            { GL_RED, GL_UNSIGNED_BYTE, GL_RED },
            { GL_RG,  GL_UNSIGNED_BYTE, GL_RG } ,
//           330 后使用这个绿屏，when use LUMINANCE/LUMINANCE_ALPHA,the fsh must use r and ra!
//            { GL_LUMINANCE, GL_UNSIGNED_BYTE, GL_LUMINANCE },
//            { GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, GL_LUMINANCE_ALPHA }
        }
    },
    {
        .cvpixfmt = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        .planes = 2,
        .gl = {
            { GL_RED, GL_UNSIGNED_BYTE, GL_RED },
            { GL_RG,  GL_UNSIGNED_BYTE, GL_RG }
        }
    },
    {
        .cvpixfmt = kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
        .planes = 2,
        .gl = {
            { GL_RED, GL_UNSIGNED_SHORT, GL_RED },
            { GL_RG,  GL_UNSIGNED_SHORT, GL_RG }
        }
    },
    {
        .cvpixfmt = kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
        .planes = 2,
        .gl = {
            { GL_RED, GL_UNSIGNED_SHORT, GL_RED },
            { GL_RG,  GL_UNSIGNED_SHORT, GL_RG }
        }
    },
    {
        .cvpixfmt = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        .planes = 2,
        .gl = {
            { GL_RED, GL_UNSIGNED_SHORT, GL_RED },
            { GL_RG,  GL_UNSIGNED_SHORT, GL_RG }
        }
    },
    {
        .cvpixfmt = kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
        .planes = 2,
        .gl = {
            { GL_RED, GL_UNSIGNED_SHORT, GL_RED },
            { GL_RG,  GL_UNSIGNED_SHORT, GL_RG }
        }
    },
    {
        .cvpixfmt = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        .planes = 2,
        .gl = {
            { GL_RED, GL_UNSIGNED_SHORT, GL_RED },
            { GL_RG,  GL_UNSIGNED_SHORT, GL_RG }
        }
    },
    {
        .cvpixfmt = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        .planes = 2,
        .gl = {
            { GL_RED, GL_UNSIGNED_SHORT, GL_RED },
            { GL_RG,  GL_UNSIGNED_SHORT, GL_RG }
        }
    },
    {
        .cvpixfmt = kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange,
        .planes = 2,
        .gl = {
            { GL_RED, GL_UNSIGNED_SHORT, GL_RED },
            { GL_RG,  GL_UNSIGNED_SHORT, GL_RG }
        }
    },
    {
        .cvpixfmt = kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange,
        .planes = 2,
        .gl = {
            { GL_RED, GL_UNSIGNED_SHORT, GL_RED },
            { GL_RG,  GL_UNSIGNED_SHORT, GL_RG }
        }
    },
#if TARGET_OS_OSX
    {
        .cvpixfmt = kCVPixelFormatType_422YpCbCr8,
        .planes = 1,
        .gl = {
#if USE_LEGACY_OPENGL
            { GL_YCBCR_422_APPLE, GL_UNSIGNED_SHORT_8_8_APPLE, GL_RGB }
#else    //330
            { GL_RGB_422_APPLE, GL_UNSIGNED_SHORT_8_8_APPLE, GL_RGB }
#endif
        }
    },
    {
        .cvpixfmt = kCVPixelFormatType_422YpCbCr8_yuvs,
        .planes = 1,
        .gl = {
#if USE_LEGACY_OPENGL
            { GL_YCBCR_422_APPLE, GL_UNSIGNED_SHORT_8_8_REV_APPLE, GL_RGB }
#else   //330
            { GL_RGB_422_APPLE, GL_UNSIGNED_SHORT_8_8_REV_APPLE, GL_RGB }
#endif
        }
    },
    {
        .cvpixfmt = kCVPixelFormatType_422YpCbCr8FullRange,
        .planes = 1,
        .gl = {
#if USE_LEGACY_OPENGL
            { GL_YCBCR_422_APPLE, GL_UNSIGNED_SHORT_8_8_REV_APPLE, GL_RGB }
#else   //330
            { GL_RGB_422_APPLE, GL_UNSIGNED_SHORT_8_8_REV_APPLE, GL_RGB }
#endif
        }
    },
#endif
    {
        .cvpixfmt = kCVPixelFormatType_420YpCbCr8Planar,
        .planes = 3,
        .gl = {
#if TARGET_OS_OSX
            { GL_RED, GL_UNSIGNED_BYTE, GL_RED },
            { GL_RED, GL_UNSIGNED_BYTE, GL_RED },
            { GL_RED, GL_UNSIGNED_BYTE, GL_RED }
#else
            { GL_RED, GL_UNSIGNED_BYTE, GL_RED },
            { GL_RED, GL_UNSIGNED_BYTE, GL_RED },
            { GL_RED, GL_UNSIGNED_BYTE, GL_RED }
#endif
        }
    },
    {
        .cvpixfmt = kCVPixelFormatType_420YpCbCr8PlanarFullRange,
        .planes = 3,
        .gl = {
#if TARGET_OS_OSX
            { GL_RED, GL_UNSIGNED_BYTE, GL_RED },
            { GL_RED, GL_UNSIGNED_BYTE, GL_RED },
            { GL_RED, GL_UNSIGNED_BYTE, GL_RED }
#else
            { GL_RED, GL_UNSIGNED_BYTE, GL_RED },
            { GL_RED, GL_UNSIGNED_BYTE, GL_RED },
            { GL_RED, GL_UNSIGNED_BYTE, GL_RED }
#endif
        }
    },
    {
        .cvpixfmt = kCVPixelFormatType_32BGRA,
        .planes = 1,
        .gl = {
        #if TARGET_OS_OSX
            { GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, GL_RGBA }
        #else
            //cvpixelbuffer not support kCVPixelFormatType_32RGBA return -6680 errer code.
            { GL_BGRA, GL_UNSIGNED_BYTE, GL_RGBA }
        #endif
        }
    },
#if TARGET_OS_OSX
    //iOS not support! [EAGLContext texImageIOSurface]: Failed to create IOSurface image (texture)
    {
        .cvpixfmt = kCVPixelFormatType_32ARGB,
        .planes = 1,
        .gl = {
            { GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, GL_RGBA }
        }
    },
#endif
#if 0
    {
//        creating IOSurface texture invalid numerical value: kCVPixelFormatType_24RGB
        .cvpixfmt = kCVPixelFormatType_24RGB,
        .planes = 1,
        .gl = {
#if TARGET_OS_OSX
            { GL_BGR, GL_UNSIGNED_INT_8_8_8_8_REV, GL_RGBA }
#else
            { GL_BGR, GL_UNSIGNED_INT, GL_RGBA }
#endif
        }
    }
#endif
};

static inline struct vt_format *vt_get_gl_format(uint32_t cvpixfmt)
{
    for (int i = 0; i < MP_ARRAY_SIZE(vt_formats); i++) {
        if (vt_formats[i].cvpixfmt == cvpixfmt)
            return &vt_formats[i];
    }
    return NULL;
}

#endif
