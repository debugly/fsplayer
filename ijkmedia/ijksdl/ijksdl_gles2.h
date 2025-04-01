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
 * License along with FSPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#ifndef FSSDL__IJKSDL_GLES2_H
#define FSSDL__IJKSDL_GLES2_H
#include "ijksdl_stdinc.h"
#ifdef __APPLE__
    #include <TargetConditionals.h>
    #include <CoreVideo/CVPixelBuffer.h>
    #if TARGET_OS_OSX
        #include <OpenGL/OpenGL.h>
        #include <OpenGL/gl3.h>
        #include <OpenGL/gl3ext.h>
    #endif /* TARGET_OS_OSX */
#else
    #include <GLES2/gl2.h>
    #include <GLES2/gl2ext.h>
    #include <GLES2/gl2platform.h>
#endif /* __APPLE__ */

typedef struct SDL_VoutOverlay SDL_VoutOverlay;

/*
 * Common
 */

//#ifdef DEBUG
//#define FS_GLES2_checkError_TRACE(op)
//#define FS_GLES2_checkError_DEBUG(op)
//#else
#define FS_GLES2_checkError_TRACE(op) FS_GLES2_checkError(op) 
#define FS_GLES2_checkError_DEBUG(op) FS_GLES2_checkError(op)
//#endif

void FS_GLES2_printString(const char *name, GLenum s);
void FS_GLES2_checkError(const char *op);

GLuint FS_GLES2_loadShader(GLenum shader_type, const char *shader_source);


/*
 * Renderer
 */
#define FS_GLES2_MAX_PLANE 3
typedef struct FS_GLES2_Renderer FS_GLES2_Renderer;
#ifdef __APPLE__
//openglVer greater than 330 use morden opengl, otherwise use legacy opengl
FS_GLES2_Renderer *FS_GLES2_Renderer_createApple(CVPixelBufferRef videoPicture, int openglVer);
#else
void* FS_GLES2_Renderer_getVideoImage(FS_GLES2_Renderer *renderer, SDL_VoutOverlay *overlay);
FS_GLES2_Renderer *FS_GLES2_Renderer_create(SDL_VoutOverlay *overlay, int openglVer);
#endif
void      FS_GLES2_Renderer_reset(FS_GLES2_Renderer *renderer);
void      FS_GLES2_Renderer_free(FS_GLES2_Renderer *renderer);
void      FS_GLES2_Renderer_freeP(FS_GLES2_Renderer **renderer);

GLboolean FS_GLES2_Renderer_isValid(FS_GLES2_Renderer *renderer);
GLboolean FS_GLES2_Renderer_isFormat(FS_GLES2_Renderer *renderer, int format);
//call once
GLboolean FS_GLES2_Renderer_init(FS_GLES2_Renderer *renderer);
GLboolean FS_GLES2_Renderer_useProgram(FS_GLES2_Renderer *renderer);
void FS_GLES2_Renderer_updateColorConversion(FS_GLES2_Renderer *renderer, float brightness, float satutaion, float contrast);

GLboolean FS_GLES2_Renderer_updateVertex(FS_GLES2_Renderer *renderer, SDL_VoutOverlay *overlay);
GLboolean FS_GLES2_Renderer_updateVertex2(FS_GLES2_Renderer *renderer, int overlay_h, int overlay_w, int buffer_w, int sar_num, int sar_den);
GLboolean FS_GLES2_Renderer_uploadTexture(FS_GLES2_Renderer *renderer, void *texture);
void FS_GLES2_Renderer_updateHdrAnimationProgress(FS_GLES2_Renderer *renderer, float per);
GLboolean FS_GLES2_Renderer_isHDR(FS_GLES2_Renderer *renderer);
GLboolean FS_GLES2_Renderer_resetVao(FS_GLES2_Renderer *renderer);
void FS_GLES2_Renderer_drawArrays(void);

void FS_GLES2_Renderer_beginDrawSubtitle(FS_GLES2_Renderer *renderer);
void FS_GLES2_Renderer_updateSubtitleVertex(FS_GLES2_Renderer *renderer, float width, float height);
GLboolean FS_GLES2_Renderer_uploadSubtitleTexture(FS_GLES2_Renderer *renderer, int texture, int w, int h);
void FS_GLES2_Renderer_endDrawSubtitle(FS_GLES2_Renderer *renderer);

#define FS_GLES2_GRAVITY_MIN                   (0)
#define FS_GLES2_GRAVITY_RESIZE                (0) // Stretch to fill layer bounds.
#define FS_GLES2_GRAVITY_RESIZE_ASPECT         (1) // Preserve aspect ratio; fit within layer bounds.
#define FS_GLES2_GRAVITY_RESIZE_ASPECT_FILL    (2) // Preserve aspect ratio; fill layer bounds.
#define FS_GLES2_GRAVITY_MAX                   (2)

GLboolean FS_GLES2_Renderer_setGravity(FS_GLES2_Renderer *renderer, int gravity, GLsizei view_width, GLsizei view_height);

void      FS_GLES2_Renderer_updateRotate(FS_GLES2_Renderer *renderer, int type, int degrees);
void      FS_GLES2_Renderer_updateAutoZRotate(FS_GLES2_Renderer *renderer, int degrees);
void      FS_GLES2_Renderer_updateUserDefinedDAR(FS_GLES2_Renderer *renderer, float ratio);
int       FS_GLES2_Renderer_isZRotate90oddMultiple(FS_GLES2_Renderer *renderer);

#endif
