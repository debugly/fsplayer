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

#ifndef FSSDL__IJKSDL_GLES2__INTERNAL__H
#define FSSDL__IJKSDL_GLES2__INTERNAL__H

#include <assert.h>
#include <stdlib.h>
#include "ijksdl/ijksdl_fourcc.h"
#include "ijksdl/ijksdl_log.h"
#include "ijksdl/ijksdl_gles2.h"
#include "ijksdl/ijksdl_vout.h"
#include "math_util.h"
#include "color_matrix.h"

#define FS_GLES_STRINGIZE(x)   #x
#define FS_GLES_STRINGIZE2(x)  FS_GLES_STRINGIZE(x)
#define FS_GLES_STRING(x)      FS_GLES_STRINGIZE2(x)

typedef struct FS_GLES2_Renderer_Opaque FS_GLES2_Renderer_Opaque;

#ifdef __APPLE__
typedef enum : int {
    NONE_SHADER,
    BGRX_SHADER,
    XRGB_SHADER,
    YUV_2P_SDR_SHADER,//for 420sp
    YUV_2P_HDR_SHADER,//for sp 10bit hdr
    YUV_3P_SHADER,//for 420p
    UYVY_SHADER,  //for uyvy
    YUYV_SHADER   //for yuyv
} FS_SHADER_TYPE;

static inline const int FS_Sample_Count_For_Shader(FS_SHADER_TYPE type)
{
    switch (type) {
        case BGRX_SHADER:
        case XRGB_SHADER:
        case UYVY_SHADER:
        case YUYV_SHADER:
        {
            return 1;
        }
        case YUV_2P_SDR_SHADER:
        case YUV_2P_HDR_SHADER:
        {
            return 2;
        }
        case YUV_3P_SHADER:
        {
            return 3;
        }
        case NONE_SHADER:
        {
            return 0;
        }
    }
}
#endif

typedef struct FS_GLES2_Renderer
{
    FS_GLES2_Renderer_Opaque *opaque;

    GLuint program;

    GLuint plane_textures[FS_GLES2_MAX_PLANE];

    GLint av4_position;
    GLint av2_texcoord;
    GLint um4_mvp;

    GLint us2_sampler[FS_GLES2_MAX_PLANE];
    GLint subSampler;//subtitle
    GLint um3_color_conversion;
    YUV_2_RGB_Color_Matrix colorMatrix;
    FS_Color_Transfer_Function transferFun;
    GLint transferFunUM;
    GLboolean isFullRange;
    GLboolean isHDR;
    GLint fullRangeUM;
    GLfloat hdrAnimationPercentage;
    GLint hdrAnimationUM;
    GLint um3_rgb_adjustment;
    
    GLboolean (*func_use)(FS_GLES2_Renderer *renderer);
    GLsizei   (*func_getBufferWidth)(FS_GLES2_Renderer *renderer, SDL_VoutOverlay *overlay);
    GLboolean (*func_uploadTexture)(FS_GLES2_Renderer *renderer, void *picture);
    GLvoid    (*func_useSubtitle)(FS_GLES2_Renderer *renderer,GLboolean subtitle);
    GLboolean (*func_uploadSubtitle)(FS_GLES2_Renderer *renderer, int tex, int w, int h);
    GLvoid    (*func_updateHDRAnimation)(FS_GLES2_Renderer *renderer, float per);
    GLboolean (*func_isHDR)(FS_GLES2_Renderer *renderer);
#ifndef __APPLE__
    void*     (*func_getVideoImage)(FS_GLES2_Renderer *renderer, SDL_VoutOverlay *overlay);
#endif
    GLvoid    (*func_destroy)(FS_GLES2_Renderer *renderer);

    GLsizei buffer_width;
    GLsizei visible_width;

    GLfloat texcoords[8];

    GLfloat vertices[8];
    int     vertices_changed;
    int     mvp_changed;
    int     rgb_adjust_changed;
    int     drawingSubtitle;
    /// 顶点对象
    GLuint vbo;
    GLuint vao;
    
    int     format;
    int     gravity;
    GLsizei layer_width;
    GLsizei layer_height;
    
    //record last overly info
    int     frame_width;
    int     frame_height;
    int     frame_sar_num;
    int     frame_sar_den;
    
    //user defined video ratio
    float   user_dar_ratio;

    GLsizei last_buffer_width;
    
    //for auto rotate video
    int auto_z_rotate_degrees;
    //for rotate
    int rotate_type;//x=1;y=2;z=3
    int rotate_degrees;
    GLfloat rgb_adjustment[3];
} FS_GLES2_Renderer;

ijk_matrix FS_GLES2_makeOrtho(GLfloat left, GLfloat right, GLfloat bottom, GLfloat top, GLfloat near, GLfloat far);

ijk_matrix FS_GLES2_defaultOrtho(void);

void FS_GLES2_getVertexShader_default(char *out,int ver);

#ifndef __APPLE__
const char *FS_GLES2_getFragmentShader_rgb(void);
const char *FS_GLES2_getFragmentShader_argb(void);

const char *FS_GL_getFragmentShader_yuv420sp(void);
const char *FS_GL_getFragmentShader_yuv420p(void);

FS_GLES2_Renderer *FS_GL_Renderer_create_rgbx(void);
FS_GLES2_Renderer *FS_GL_Renderer_create_xrgb(void);

#else

FS_GLES2_Renderer *ijk_create_common_gl_Renderer(CVPixelBufferRef videoPicture, int openglVer);
void ijk_get_apple_common_fragment_shader(FS_SHADER_TYPE type, char *out, int ver);

GLboolean ijk_upload_texture_with_cvpixelbuffer(CVPixelBufferRef pixel_buffer, int textures[3]);
#endif

const GLfloat *FS_GLES2_getColorMatrix_bt2020(void);
const GLfloat *FS_GLES2_getColorMatrix_bt709(void);
const GLfloat *FS_GLES2_getColorMatrix_bt601(void);

FS_GLES2_Renderer *FS_GLES2_Renderer_create_base(const char *fragment_shader_source, int openglVer);

#endif
