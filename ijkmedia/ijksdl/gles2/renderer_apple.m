/*
 * Copyright (c) 2016 Bilibili
 * Copyright (c) 2016 Zhang Rui <bbcallen@gmail.com>
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
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include "internal.h"
#if TARGET_OS_OSX
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#else
#if __OBJC__
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/EAGL.h>
//https://github.com/lechium/iOS14Headers/blob/c0b7e9f0049c6b2571358584eed67c841140624f/System/Library/Frameworks/OpenGLES.framework/EAGLContext.h
@interface EAGLContext ()
- (BOOL)texImageIOSurface:(IOSurfaceRef)arg1 target:(unsigned long long)arg2 internalFormat:(unsigned long long)arg3 width:(unsigned)arg4 height:(unsigned)arg5 format:(unsigned long long)arg6 type:(unsigned long long)arg7 plane:(unsigned)arg8 invert:(BOOL)arg9;
//begin ios 11
- (BOOL)texImageIOSurface:(IOSurfaceRef)arg1 target:(unsigned long long)arg2 internalFormat:(unsigned long long)arg3 width:(unsigned)arg4 height:(unsigned)arg5 format:(unsigned long long)arg6 type:(unsigned long long)arg7 plane:(unsigned)arg8;
@end

#endif
#endif

#import <CoreVideo/CoreVideo.h>
#include "ijksdl_vout_overlay_ffmpeg_hw.h"
#include "ijksdl_vout_overlay_ffmpeg.h"
#include "renderer_pixfmt.h"
#import "ijk_vout_common.h"

#if TARGET_OS_OSX
#define GL_TEXTURE_TARGET GL_TEXTURE_RECTANGLE
#else
#define GL_TEXTURE_TARGET GL_TEXTURE_2D
#endif

typedef struct FS_GLES2_Renderer_Opaque
{
    GLint                 isSubtitle;
    int samples;
#if TARGET_OS_OSX
    GLint                 textureDimension[3];
    GLint                 subTextureDimension;
#endif
} FS_GLES2_Renderer_Opaque;

static GLboolean use(FS_GLES2_Renderer *renderer)
{
    //ALOGI("use common vtb render\n");
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    //glEnable(GL_TEXTURE_TARGET);
    glUseProgram(renderer->program);            FS_GLES2_checkError_TRACE("glUseProgram");
    FS_GLES2_Renderer_Opaque * opaque = renderer->opaque;
    if (opaque->samples == 0) {
        ALOGE("renderer apple samples must not be zero");
    }
    if (0 == renderer->plane_textures[0])
        glGenTextures(opaque->samples, renderer->plane_textures);
    return GL_TRUE;
}

static GLsizei getBufferWidth(FS_GLES2_Renderer *renderer, SDL_VoutOverlay *overlay)
{
    if (!overlay)
        return 0;

    return overlay->pitches[0];
}

static GLboolean upload_texture_use_IOSurface(CVPixelBufferRef pixel_buffer,FS_GLES2_Renderer *renderer)
{
    uint32_t cvpixfmt = CVPixelBufferGetPixelFormatType(pixel_buffer);
    struct vt_format *f = vt_get_gl_format(cvpixfmt);
    if (!f) {
        ALOGE("CVPixelBuffer has unsupported format type\n");
        return GL_FALSE;
    }

    const bool planar = CVPixelBufferIsPlanar(pixel_buffer);
    const int planes  = (int)CVPixelBufferGetPlaneCount(pixel_buffer);
    
    if ((planar && planes != f->planes) || (!planar && f->planes != 1)) {
        ALOGE("CVPixelBuffer planes is wrong:%d,%d\n", planes, f->planes);
        return GL_FALSE;
    }
    
    GLenum gl_target = GL_TEXTURE_TARGET;
    
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixel_buffer);
    
    if (!surface) {
        printf("CVPixelBuffer has no IOSurface\n");
        return GL_FALSE;
    }
    
    for (int i = 0; i < f->planes; i++) {
        GLfloat w = (GLfloat)CVPixelBufferGetWidthOfPlane(pixel_buffer, i);
        GLfloat h = (GLfloat)CVPixelBufferGetHeightOfPlane(pixel_buffer, i);

        //设置采样器位置，保证了每个uniform采样器对应着正确的纹理单元
        glUniform1i(renderer->us2_sampler[i], i);
        glActiveTexture(GL_TEXTURE0 + i);
        glBindTexture(gl_target, renderer->plane_textures[i]);
        struct vt_gl_plane_format plane_format = f->gl[i];
#if TARGET_OS_IOS
        if (![[EAGLContext currentContext] texImageIOSurface:surface target:gl_target internalFormat:plane_format.gl_internal_format width:w height:h format:plane_format.gl_format type:plane_format.gl_type plane:i invert:NO]) {
            ALOGE("creating IOSurface texture for plane %d failed.\n",i);
            return GL_FALSE;
        }
//        
//        //(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const GLvoid* pixels)
//        glTexImage2D(gl_target, 0, plane_format.gl_internal_format, w, h, 0, plane_format.gl_format, plane_format.gl_type, CVPixelBufferGetBaseAddressOfPlane(pixel_buffer,i));
        
#else
        glUniform2f(renderer->opaque->textureDimension[i], w, h);
        
        CGLError err = CGLTexImageIOSurface2D(CGLGetCurrentContext(),
                                              gl_target,
                                              plane_format.gl_internal_format,
                                              w,
                                              h,
                                              plane_format.gl_format,
                                              plane_format.gl_type,
                                              surface,
                                              i);
        if (err != kCGLNoError) {
            ALOGE("creating IOSurface texture for plane %d failed: %s\n",
                   i, CGLErrorString(err));
            return GL_FALSE;
        }
#endif
        {
            glTexParameteri(gl_target, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(gl_target, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameterf(gl_target, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameterf(gl_target, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        }
    }
    return GL_TRUE;
}

GLboolean ijk_upload_texture_with_cvpixelbuffer(CVPixelBufferRef pixel_buffer, int textures[3])
{
    uint32_t cvpixfmt = CVPixelBufferGetPixelFormatType(pixel_buffer);
    struct vt_format *f = vt_get_gl_format(cvpixfmt);
    if (!f) {
        ALOGE("CVPixelBuffer has unsupported format type\n");
        return GL_FALSE;
    }

    const bool planar = CVPixelBufferIsPlanar(pixel_buffer);
    const int planes  = (int)CVPixelBufferGetPlaneCount(pixel_buffer);
    
    if ((planar && planes != f->planes) || (!planar && f->planes != 1)) {
        ALOGE("CVPixelBuffer planes is wrong:%d,%d\n", planes, f->planes);
        return GL_FALSE;
    }
    GLenum gl_target = GL_TEXTURE_TARGET;
    
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixel_buffer);
    
    if (!surface) {
        printf("CVPixelBuffer has no IOSurface\n");
        return GL_FALSE;
    }
    
    for (int i = 0; i < f->planes; i++) {
        GLfloat w = (GLfloat)CVPixelBufferGetWidthOfPlane(pixel_buffer, i);
        GLfloat h = (GLfloat)CVPixelBufferGetHeightOfPlane(pixel_buffer, i);

        glActiveTexture(GL_TEXTURE0 + i);
        glBindTexture(gl_target, textures[i]);
        struct vt_gl_plane_format plane_format = f->gl[i];
#if TARGET_OS_IOS
        if (![[EAGLContext currentContext] texImageIOSurface:surface target:gl_target internalFormat:plane_format.gl_internal_format width:w height:h format:plane_format.gl_format type:plane_format.gl_type plane:i invert:NO]) {
            ALOGE("creating IOSurface texture for plane %d failed.\n",i);
            return GL_FALSE;
        }
//
//        //(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const GLvoid* pixels)
//        glTexImage2D(gl_target, 0, plane_format.gl_internal_format, w, h, 0, plane_format.gl_format, plane_format.gl_type, CVPixelBufferGetBaseAddressOfPlane(pixel_buffer,i));
        
#else
        CGLError err = CGLTexImageIOSurface2D(CGLGetCurrentContext(),
                                              gl_target,
                                              plane_format.gl_internal_format,
                                              w,
                                              h,
                                              plane_format.gl_format,
                                              plane_format.gl_type,
                                              surface,
                                              i);
        if (err != kCGLNoError) {
            ALOGE("creating IOSurface texture for plane %d failed: %s\n",
                   i, CGLErrorString(err));
            return GL_FALSE;
        }
#endif
        {
            glTexParameteri(gl_target, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(gl_target, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameterf(gl_target, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameterf(gl_target, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        }
    }
    return GL_TRUE;
}

static GLboolean upload_Texture(FS_GLES2_Renderer *renderer, void *picture)
{
    if (!picture) {
        return GL_FALSE;
    }
    CVPixelBufferRef pixel_buffer = (CVPixelBufferRef)picture;
    
    FS_GLES2_Renderer_Opaque *opaque = renderer->opaque;
    if (!opaque) {
        return GL_FALSE;
    }
    FS_GLES2_checkError_TRACE("transferFunUM begin");
    if (renderer->colorMatrix != YUV_2_RGB_Color_Matrix_None) {
        glUniformMatrix3fv(renderer->um3_color_conversion, 1, GL_FALSE, FS_GLES2_getColorMatrix(renderer->colorMatrix));
        FS_GLES2_checkError_TRACE("transferFunUM 1");
    }
    
    if (renderer->fullRangeUM != -1) {
        glUniform1i(renderer->fullRangeUM, renderer->isFullRange);
        FS_GLES2_checkError_TRACE("transferFunUM 2");
    }
    
    if (renderer->transferFunUM != -1) {
        glUniform1i(renderer->transferFunUM, renderer->transferFun);
        FS_GLES2_checkError_TRACE("transferFunUM 3");
    }
    
    if (renderer->hdrAnimationUM != -1) {
        glUniform1f(renderer->hdrAnimationUM, renderer->hdrAnimationPercentage);
    }
    
    FS_GLES2_checkError_TRACE("transferFunUM");
    CVPixelBufferRetain(pixel_buffer);
    GLboolean uploaded = upload_texture_use_IOSurface(pixel_buffer, renderer);
    CVPixelBufferRelease(pixel_buffer);
    return uploaded;
}

static GLvoid destroy(FS_GLES2_Renderer *renderer)
{
    if (!renderer || !renderer->opaque)
        return;
    free(renderer->opaque);
    renderer->opaque = nil;
}

static GLvoid useSubtitle(FS_GLES2_Renderer *renderer,GLboolean subtitle)
{
    glUniform1i(renderer->opaque->isSubtitle, (GLint)subtitle);
}

static GLvoid updateHDRAnimation(FS_GLES2_Renderer *renderer,float per)
{
    renderer->hdrAnimationPercentage = per;
}

GLboolean isHDR(FS_GLES2_Renderer *renderer)
{
    return renderer->isHDR;
}

static GLboolean uploadSubtitle(FS_GLES2_Renderer *renderer, int texture, int w, int h)
{
    if (!texture) {
        return GL_FALSE;
    }

    FS_GLES2_Renderer_Opaque *opaque = renderer->opaque;
    if (!opaque) {
        return GL_FALSE;
    }
    
    GLenum GLTarget = GL_TEXTURE_TARGET;
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GLTarget, texture);
    FS_GLES2_checkError_TRACE("uploadSubtitle1");
    //设置采样器位置，和纹理单元对应
    glUniform1i(renderer->subSampler, 0);
    FS_GLES2_checkError_TRACE("uploadSubtitle2");
#if TARGET_OS_OSX
    glUniform2f(renderer->opaque->subTextureDimension, w, h);
#endif
    FS_GLES2_checkError_TRACE("uploadSubtitle3");
    glTexParameteri(GLTarget, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GLTarget, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameterf(GLTarget, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameterf(GLTarget, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    
    return true;
}

FS_GLES2_Renderer *ijk_create_common_gl_Renderer(CVPixelBufferRef videoPicture, int openglVer)
{
    Uint32 cv_format = CVPixelBufferGetPixelFormatType(videoPicture);
    CFStringRef colorMatrixStr = CVBufferGetAttachment(videoPicture, kCVImageBufferYCbCrMatrixKey, NULL);
    CFStringRef transferFuntion = CVBufferGetAttachment(videoPicture, kCVImageBufferTransferFunctionKey, NULL);
    
    FS_SHADER_TYPE shaderType;
    if (cv_format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || 
        cv_format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
        cv_format == kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange ||
        cv_format == kCVPixelFormatType_422YpCbCr8BiPlanarFullRange  ||
        cv_format == kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange ||
        cv_format == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange) {
        ALOGI("create render yuv420sp\n");
        shaderType = YUV_2P_SDR_SHADER;
    } else if (cv_format == kCVPixelFormatType_32BGRA) {
        ALOGI("create render bgrx\n");
        shaderType = BGRX_SHADER;
    } else if (cv_format == kCVPixelFormatType_32ARGB) {
        ALOGI("create render xrgb\n");
        shaderType = XRGB_SHADER;
    } else if (cv_format == kCVPixelFormatType_420YpCbCr8Planar ||
               cv_format == kCVPixelFormatType_420YpCbCr8PlanarFullRange) {
        ALOGI("create render yuv420p\n");
        shaderType = YUV_3P_SHADER;
    }
    #if TARGET_OS_OSX
    else if (cv_format == kCVPixelFormatType_422YpCbCr8) {
        ALOGI("create render uyvy\n");
        shaderType = UYVY_SHADER;
    } else if (cv_format == kCVPixelFormatType_422YpCbCr8_yuvs || cv_format == kCVPixelFormatType_422YpCbCr8FullRange) {
        ALOGI("create render yuyv\n");
        shaderType = YUYV_SHADER;
    }
    #endif
    else if (cv_format == kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange ||
             cv_format == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange ||
             cv_format == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange ||
             cv_format == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange ||
             cv_format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
             cv_format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
             cv_format == kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange ||
             cv_format == kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange
             ) {
        if (colorMatrixStr != nil &&
            CFStringCompare(colorMatrixStr, kCVImageBufferYCbCrMatrix_ITU_R_2020, 0) == kCFCompareEqualTo) {
            shaderType = YUV_2P_HDR_SHADER;
        } else {
            shaderType = YUV_2P_SDR_SHADER;
        }
    } else {
        ALOGE("create render failed,unknown format:%4s\n",(char *)&cv_format);
        return NULL;
    }
    
    YUV_2_RGB_Color_Matrix colorMatrixType = YUV_2_RGB_Color_Matrix_None;
    if (shaderType != BGRX_SHADER && shaderType != XRGB_SHADER) {
        if (colorMatrixStr != nil) {
            if (CFStringCompare(colorMatrixStr, kCVImageBufferYCbCrMatrix_ITU_R_709_2, 0) == kCFCompareEqualTo) {
                colorMatrixType = YUV_2_RGB_Color_Matrix_BT709;
            } else if (CFStringCompare(colorMatrixStr, kCVImageBufferYCbCrMatrix_ITU_R_601_4, 0) == kCFCompareEqualTo) {
                colorMatrixType = YUV_2_RGB_Color_Matrix_BT601;
            } else if (CFStringCompare(colorMatrixStr, kCVImageBufferYCbCrMatrix_ITU_R_2020, 0) == kCFCompareEqualTo) {
                colorMatrixType = YUV_2_RGB_Color_Matrix_BT2020;
            } else {
                colorMatrixType = YUV_2_RGB_Color_Matrix_BT709;
            }
        } else {
            colorMatrixType = YUV_2_RGB_Color_Matrix_BT709;
        }
    }
    int fullRange = 0;
    //full color range
    if (kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange == cv_format ||
        kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange == cv_format ||
        kCVPixelFormatType_420YpCbCr8PlanarFullRange == cv_format ||
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange == cv_format ||
        kCVPixelFormatType_422YpCbCr8BiPlanarFullRange == cv_format ||
        kCVPixelFormatType_444YpCbCr8BiPlanarFullRange == cv_format ||
        kCVPixelFormatType_422YpCbCr8FullRange == cv_format ||
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange == cv_format ||
        kCVPixelFormatType_422YpCbCr10BiPlanarFullRange == cv_format ||
        kCVPixelFormatType_444YpCbCr10BiPlanarFullRange == cv_format) {
        fullRange = 1;
    }
    FS_Color_Transfer_Function tf;
    if (transferFuntion) {
        if (CFStringCompare(transferFuntion, FS_TransferFunction_ITU_R_2100_HLG, 0) == kCFCompareEqualTo) {
            tf = FS_Color_Transfer_Function_HLG;
        } else if (CFStringCompare(transferFuntion, FS_TransferFunction_SMPTE_ST_2084_PQ, 0) == kCFCompareEqualTo || CFStringCompare(transferFuntion, FS_TransferFunction_SMPTE_ST_428_1, 0) == kCFCompareEqualTo) {
            tf = FS_Color_Transfer_Function_PQ;
        } else {
            tf = FS_Color_Transfer_Function_LINEAR;
        }
    } else {
        tf = FS_Color_Transfer_Function_LINEAR;
    }
        
    char shader_buffer[5120] = { '\0' };
    
    ijk_get_apple_common_fragment_shader(shaderType,shader_buffer,openglVer);
    FS_GLES2_Renderer *renderer = FS_GLES2_Renderer_create_base(shader_buffer,openglVer);

    if (!renderer)
        goto fail;
    
    renderer->colorMatrix = colorMatrixType;
    renderer->isFullRange = fullRange;
    renderer->transferFun = tf;
    renderer->isHDR = shaderType == YUV_2P_HDR_SHADER;
    
    const int samples = FS_Sample_Count_For_Shader(shaderType);
    
    for (int i = 0; i < samples; i++) {
        char name[20] = "us2_Sampler";
        name[strlen(name)] = (char)i + '0';
        renderer->us2_sampler[i] = glGetUniformLocation(renderer->program, name); FS_GLES2_checkError_TRACE("glGetUniformLocation(us2_Sampler)");
    }
    
    renderer->subSampler = glGetUniformLocation(renderer->program, "subSampler"); FS_GLES2_checkError_TRACE("glGetUniformLocation(subSampler)");
    
    //yuv to rgb
    renderer->um3_color_conversion = glGetUniformLocation(renderer->program, "um3_ColorConversion");
    renderer->fullRangeUM   = glGetUniformLocation(renderer->program, "isFullRange");
    renderer->transferFunUM = glGetUniformLocation(renderer->program, "transferFun");
    renderer->hdrAnimationUM = glGetUniformLocation(renderer->program, "hdrPercentage");
    renderer->um3_rgb_adjustment = glGetUniformLocation(renderer->program, "um3_rgbAdjustment"); FS_GLES2_checkError_TRACE("glGetUniformLocation(um3_rgb_adjustmentVector)");
    
    renderer->func_use            = use;
    renderer->func_getBufferWidth = getBufferWidth;
    renderer->func_uploadTexture  = upload_Texture;
    renderer->func_destroy        = destroy;
    renderer->func_useSubtitle    = useSubtitle;
    renderer->func_uploadSubtitle = uploadSubtitle;
    renderer->func_updateHDRAnimation = updateHDRAnimation;
    renderer->func_isHDR = isHDR;
    renderer->opaque = calloc(1, sizeof(FS_GLES2_Renderer_Opaque));
    if (!renderer->opaque)
        goto fail;
    bzero(renderer->opaque, sizeof(FS_GLES2_Renderer_Opaque));
    renderer->opaque->samples = samples;
    renderer->opaque->isSubtitle = glGetUniformLocation(renderer->program, "isSubtitle");
    
#if TARGET_OS_OSX
    for (int i = 0; i < samples; i++) {
        char name[20] = "textureDimension";
        name[strlen(name)] = (char)i + '0';
        GLint textureDimension = glGetUniformLocation(renderer->program, name);
        renderer->opaque->textureDimension[i] = textureDimension;
    }
    renderer->opaque->subTextureDimension = glGetUniformLocation(renderer->program, "subTextureDimension");
#endif
    renderer->format = cv_format;
    return renderer;
fail:
    FS_GLES2_Renderer_free(renderer);
    return NULL;
}
