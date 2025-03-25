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

#include "ijksdl/gles2/internal.h"

//for hdr (macos only,ios not support convert IOSurface to texture)
static const char g_shader_hdr[] = FS_GLES_STRING(
    varying vec2 vv2_Texcoord;
    uniform sampler2DRect us2_Sampler0;
    uniform sampler2DRect us2_Sampler1;
    uniform sampler2DRect subSampler;
#if TARGET_OS_OSX
    uniform vec2 textureDimension0;
    uniform vec2 textureDimension1;
    uniform vec2 subTextureDimension;
#endif
    uniform mat3 um3_ColorConversion;
    uniform vec3 um3_rgbAdjustment;
    
    uniform int isSubtitle;
    uniform int isFullRange;
    uniform int transferFun;
    uniform float hdrPercentage;
                                                   
    #define FF_MAX(a,b) ((a) > (b) ? (a) : (b))
    #define FF_MAX3(a,b,c) FF_MAX(FF_MAX(a,b),c)
    #define FF_FLT_MAX 3.402823466e+38
    #define FF_FLT_MIN 1.175494351e-38
                                                   
    // [arib b67 eotf
    const float ARIB_B67_A = 0.17883277;
    const float ARIB_B67_B = 0.28466892;
    const float ARIB_B67_C = 0.55991073;
    float arib_b67_inverse_oetf(float x)
    {
        // Prevent negative pixels expanding into positive values.
        x = max(x, 0.0);
        if (x <= 0.5)
        x = (x * x) * (1.0 / 3.0);
        else
        x = (exp((x - ARIB_B67_C) / ARIB_B67_A) + ARIB_B67_B) / 12.0;
        return x;
    }
    float ootf_1_2(float x)
    {
        return x < 0.0 ? x : pow(x, 1.2);
    }
    float arib_b67_eotf(float x)
    {
        return ootf_1_2(arib_b67_inverse_oetf(x));
    }
    // arib b67 eotf]

    // [st 2084 eotf
    float ST2084_M1 = 0.1593017578125;
    const float ST2084_M2 = 78.84375;
    const float ST2084_C1 = 0.8359375;
    const float ST2084_C2 = 18.8515625;
    const float ST2084_C3 = 18.6875;
    
    float st_2084_eotf(float x)
    {
        float xpow = pow(x, float(1.0 / ST2084_M2));
        float num = max(xpow - ST2084_C1, 0.0);
        float den = max(ST2084_C2 - ST2084_C3 * xpow, FF_FLT_MIN);
        return pow(num/den, 1.0 / ST2084_M1);
    }
    // st 2084 eotf]

    // [tonemap hable
    float hableF(float inVal)
    {
        //fix xcode error:Too many arguments provided to function-like macro invocation
        float a = 0.15;
        float b = 0.50;
        float c = 0.10;
        float d = 0.20;
        float e = 0.02;
        float f = 0.30;
        return (inVal * (inVal * a + b * c) + d * e) / (inVal * (inVal * a + b) + d * f) - e / f;
    }
    // tonemap hable]

    // [bt709
    float rec_1886_inverse_eotf(float x)
    {
        return x < 0.0 ? 0.0 : pow(x, 1.0 / 2.4);
    }

    float rec_1886_eotf(float x)
    {
        return x < 0.0 ? 0.0 : pow(x, 2.4);
    }
    // bt709]
                      
    void main() {
       
        if (isSubtitle == 1) {
            vec4 subColor;
        #if TARGET_OS_OSX
            subColor = texture2DRect(subSampler, vv2_Texcoord * subTextureDimension);
        #else
            subColor = texture2DRect(subSampler, vv2_Texcoord);
        #endif
            fragColor = subColor.bgra;
            return;
        }
        // 0、先把 [0.0,1.0] 范围的YUV 处理为 [0.0,1.0] 范围的RGB
        #if TARGET_OS_OSX
        vec2 recTexCoord0 = vv2_Texcoord * textureDimension0;
        vec2 recTexCoord1 = vv2_Texcoord * textureDimension1;
        //OpenGL会在将这些值存入帧缓冲前主动将值处理为0.0到1.0之间
        float x = texture2DRect(us2_Sampler0, recTexCoord0).r;
        vec2 yz = texture2DRect(us2_Sampler1, recTexCoord1).rg;
        vec3 yuv = vec3(x,yz);
        #else
        float x = texture2DRect(us2_Sampler0, vv2_Texcoord).r;
        vec2 yz = texture2DRect(us2_Sampler1, vv2_Texcoord).rg;
        vec3 yuv = vec3(x,yz);
        #endif
        
        vec3 offset;
        if (isFullRange == 1) {
            offset = vec3(0.0, -0.5, -0.5);
        } else {
            offset = vec3(- (16.0 / 255.0), -0.5, -0.5);
        }
        yuv += offset;
        //使用 BT.2020 矩阵转为RGB
        vec3 rgb10bit = um3_ColorConversion * yuv;
        
        // 1、HDR 非线性电信号转为 HDR 线性光信号（EOTF）
        float peak_luminance = 50.0;
        vec3 myFragColor;
        
        if (vv2_Texcoord.x <= hdrPercentage) {
            if (transferFun == 1) {
               float to_linear_scale = 10000.0 / peak_luminance;
               myFragColor = to_linear_scale * vec3(st_2084_eotf(rgb10bit.r), st_2084_eotf(rgb10bit.g), st_2084_eotf(rgb10bit.b));
            } else if (transferFun == 2) {
               float to_linear_scale = 1000.0 / peak_luminance;
               myFragColor = to_linear_scale * vec3(arib_b67_eotf(rgb10bit.r), arib_b67_eotf(rgb10bit.g), arib_b67_eotf(rgb10bit.b));
            } else {
               myFragColor = vec3(rec_1886_eotf(rgb10bit.r), rec_1886_eotf(rgb10bit.g), rec_1886_eotf(rgb10bit.b));
            }

            // 2、HDR 线性光信号做颜色空间转换（Color Space Converting）
            // color-primaries REC_2020 to REC_709
            mat3 rgb2xyz2020 = mat3(0.6370, 0.1446, 0.1689,
                                   0.2627, 0.6780, 0.0593,
                                   0.0000, 0.0281, 1.0610);
            mat3 xyz2rgb709 = mat3(3.2410, -1.5374, -0.4986,
                                  -0.9692, 1.8760, 0.0416,
                                  0.0556, -0.2040, 1.0570);
            myFragColor *= rgb2xyz2020 * xyz2rgb709;

            // 3、HDR 线性光信号色调映射为 SDR 线性光信号（Tone Mapping）
            float sig = FF_MAX(FF_MAX3(myFragColor.r, myFragColor.g, myFragColor.b), 1e-6);
            float sig_orig = sig;
            float peak = 10.0;
            sig = hableF(sig) / hableF(peak);
            myFragColor *= sig / sig_orig;

            // 4、SDR 线性光信号转 SDR 非线性电信号（OETF）
            myFragColor = vec3(rec_1886_inverse_eotf(myFragColor.r), rec_1886_inverse_eotf(myFragColor.g), rec_1886_inverse_eotf(myFragColor.b));
        } else {
            myFragColor = rgb10bit;
        }
        
        fragColor = vec4(rgb_adjust(myFragColor,um3_rgbAdjustment), 1.0);
    }

);

//for 420sp
static const char g_shader_nv12[] = FS_GLES_STRING(
    varying vec2 vv2_Texcoord;
    uniform mat3 um3_ColorConversion;
    uniform vec3 um3_rgbAdjustment;
    
    uniform sampler2DRect us2_Sampler0;
    uniform sampler2DRect us2_Sampler1;
#if TARGET_OS_OSX
    uniform vec2 textureDimension0;
    uniform vec2 textureDimension1;
    uniform vec2 subTextureDimension;
#endif
    uniform int isSubtitle;
    uniform sampler2DRect subSampler;
    uniform int isFullRange;
                                         
    void main()
    {
        if (isSubtitle == 1) {
            vec4 subColor;
        #if TARGET_OS_OSX
            subColor = texture2DRect(subSampler, vv2_Texcoord * subTextureDimension);
        #else
            subColor = texture2DRect(subSampler, vv2_Texcoord);
        #endif
            fragColor = subColor.bgra;
            return;
        }
#if TARGET_OS_OSX
        vec3 yuv;
        vec2 recTexCoord0 = vv2_Texcoord * textureDimension0;
        vec2 recTexCoord1 = vv2_Texcoord * textureDimension1;
        
        yuv.x = texture2DRect(us2_Sampler0, recTexCoord0).r;
        yuv.yz = texture2DRect(us2_Sampler1, recTexCoord1).rg;
#else
        mediump vec3 yuv;
        yuv.x = texture2DRect(us2_Sampler0, vv2_Texcoord).r;
        yuv.yz = texture2DRect(us2_Sampler1, vv2_Texcoord).rg;
#endif
        vec3 offset;
        if (isFullRange == 1) {
            offset = vec3(0.0, -0.5, -0.5);
        } else {
            offset = vec3(- (16.0 / 255.0), -0.5, -0.5);
        }
        yuv += offset;
        vec3 rgb = um3_ColorConversion * yuv;
        rgb = rgb_adjust(rgb,um3_rgbAdjustment);
        fragColor = vec4(rgb, 1.0);
    }
);

//for bgrx texture
static const char g_shader_rect_bgrx_1[] = FS_GLES_STRING(
    varying vec2 vv2_Texcoord;
    uniform vec3 um3_rgbAdjustment;
    
    uniform sampler2DRect us2_Sampler0;
#if TARGET_OS_OSX
    uniform vec2 textureDimension0;
    uniform vec2 subTextureDimension;
#endif
    uniform int isSubtitle;
    uniform sampler2DRect subSampler;
    
    void main()
    {
        if (isSubtitle == 1) {
            vec4 subColor;
        #if TARGET_OS_OSX
            subColor = texture2DRect(subSampler, vv2_Texcoord * subTextureDimension);
        #else
            subColor = texture2DRect(subSampler, vv2_Texcoord);
        #endif
            fragColor = subColor.bgra;
            return;
        }
        #if TARGET_OS_OSX
        vec2 recTexCoord0 = vv2_Texcoord * textureDimension0;
        vec3 rgb = texture2DRect(us2_Sampler0, recTexCoord0).rgb;
        #else
        vec3 rgb = texture2DRect(us2_Sampler0, vv2_Texcoord).rgb;
        #endif
        rgb = rgb_adjust(rgb,um3_rgbAdjustment);
        fragColor = vec4(rgb, 1.0);
    }
);

//for uyvy texture
static const char g_shader_rect_uyvy_legacy_1[] = FS_GLES_STRING(
    varying vec2 vv2_Texcoord;
    uniform vec3 um3_rgbAdjustment;
    
    uniform sampler2DRect us2_Sampler0;
    uniform vec2 textureDimension0;
    uniform vec2 subTextureDimension;
    uniform int isSubtitle;
    uniform sampler2DRect subSampler;
                                            
    void main()
    {
        if (isSubtitle == 1) {
            vec4 subColor = texture2DRect(subSampler, vv2_Texcoord * subTextureDimension);
            fragColor = subColor.bgra;
            return;
        }
        vec2 recTexCoord0 = vv2_Texcoord * textureDimension0;
        vec3 rgb = texture2DRect(us2_Sampler0, recTexCoord0).rgb;
        rgb = rgb_adjust(rgb,um3_rgbAdjustment);
        fragColor = vec4(rgb, 1.0);
    }
);

//for xrgb texture (macos only,ios not support convert IOSurface to texture)
static const char g_shader_rect_xrgb_1[] = FS_GLES_STRING(
    varying vec2 vv2_Texcoord;
    uniform vec3 um3_rgbAdjustment;
    
    uniform sampler2DRect us2_Sampler0;
#if TARGET_OS_OSX
    uniform vec2 textureDimension0;
    uniform vec2 subTextureDimension;
#endif
    uniform int isSubtitle;
    uniform sampler2DRect subSampler;
                                                 
    void main()
    {
        if (isSubtitle == 1) {
            vec4 subColor;
        #if TARGET_OS_OSX
            subColor = texture2DRect(subSampler, vv2_Texcoord * subTextureDimension);
        #else
            subColor = texture2DRect(subSampler, vv2_Texcoord);
        #endif
            fragColor = subColor.bgra;
            return;
        }
        #if TARGET_OS_OSX
        vec2 recTexCoord0 = vv2_Texcoord * textureDimension0;
        //bgra -> argb
        //argb -> bgra
        vec3 rgb = texture2DRect(us2_Sampler0, recTexCoord0).gra;
        rgb = rgb_adjust(rgb,um3_rgbAdjustment);
        #else
        vec3 rgb = texture2DRect(us2_Sampler0, vv2_Texcoord).rgb;
        #endif
        fragColor = vec4(rgb, 1.0);
    }
);

//for yuv420p
static const char g_shader_rect_3[] = FS_GLES_STRING(
    varying vec2 vv2_Texcoord;
    uniform mat3 um3_ColorConversion;
    uniform vec3 um3_rgbAdjustment;
                                                   
    uniform sampler2DRect us2_Sampler0;
    uniform sampler2DRect us2_Sampler1;
    uniform sampler2DRect us2_Sampler2;
#if TARGET_OS_OSX
    uniform vec2 textureDimension0;
    uniform vec2 textureDimension1;
    uniform vec2 textureDimension2;
    uniform vec2 subTextureDimension;
#endif
    uniform int isSubtitle;
    uniform sampler2DRect subSampler;
    uniform int isFullRange;
                                                      
    void main()
    {
        if (isSubtitle == 1) {
            vec4 subColor;
        #if TARGET_OS_OSX
            subColor = texture2DRect(subSampler, vv2_Texcoord * subTextureDimension);
        #else
            subColor = texture2DRect(subSampler, vv2_Texcoord);
        #endif
            fragColor = subColor.bgra;
            return;
        }
#if TARGET_OS_OSX
        vec3 yuv;
        vec2 recTexCoord0 = vv2_Texcoord * textureDimension0;
        vec2 recTexCoord1 = vv2_Texcoord * textureDimension1;
        vec2 recTexCoord2 = vv2_Texcoord * textureDimension2;

        yuv.x = texture2DRect(us2_Sampler0, recTexCoord0).r;
        yuv.y = texture2DRect(us2_Sampler1, recTexCoord1).r;
        yuv.z = texture2DRect(us2_Sampler2, recTexCoord2).r;
#else
        mediump vec3 yuv;
        yuv.x = texture2DRect(us2_Sampler0, vv2_Texcoord).r;
        yuv.y = texture2DRect(us2_Sampler1, vv2_Texcoord).r;
        yuv.z = texture2DRect(us2_Sampler2, vv2_Texcoord).r;
#endif
        vec3 offset;
        if (isFullRange == 1) {
            offset = vec3(0.0, -0.5, -0.5);
        } else {
            offset = vec3(- (16.0 / 255.0), -0.5, -0.5);
        }
        yuv += offset;
        vec3 rgb = um3_ColorConversion * yuv;
        rgb = rgb_adjust(rgb,um3_rgbAdjustment);
        fragColor = vec4(rgb, 1.0);
    }
);

//for uyvy texture
static const char g_shader_rect_uyvy_1[] = FS_GLES_STRING(
    varying vec2 vv2_Texcoord;
    uniform vec3 um3_rgbAdjustment;
    uniform mat3 um3_ColorConversion;
    uniform sampler2DRect us2_Sampler0;
    uniform vec2 textureDimension0;
    
    uniform int isSubtitle;
    uniform sampler2DRect subSampler;
    uniform vec2 subTextureDimension;
    uniform int isFullRange;
          
    void main()
    {
        if (isSubtitle == 1) {
            vec4 subColor;
        #if TARGET_OS_OSX
            subColor = texture2DRect(subSampler, vv2_Texcoord * subTextureDimension);
        #else
            subColor = texture2DRect(subSampler, vv2_Texcoord);
        #endif
            fragColor = subColor.bgra;
            return;
        }
        vec2 recTexCoord0 = vv2_Texcoord * textureDimension0;
        vec3 yuv = texture2DRect(us2_Sampler0, recTexCoord0).gbr;
        vec3 offset;
        if (isFullRange == 1) {
            offset = vec3(0.0, -0.5, -0.5);
        } else {
            offset = vec3(- (16.0 / 255.0), -0.5, -0.5);
        }
        yuv += offset;
        vec3 rgb = um3_ColorConversion * yuv;
        rgb = rgb_adjust(rgb,um3_rgbAdjustment);
        fragColor = vec4(rgb, 1.0);
    }
);

void ijk_get_apple_common_fragment_shader(FS_SHADER_TYPE type,char *out,int ver)
{
    *out = '\0';
    sprintf(out, "#version %d\n",ver);
#if TARGET_OS_IOS
    strcat(out, "#define texture2DRect texture2D\n");
    strcat(out, "#define sampler2DRect sampler2D\n");
    strcat(out, "#define fragColor gl_FragColor\n");
    strcat(out,"precision highp float;\n");
    strcat(out,"precision lowp sampler2D;\n");
#else
    if (ver >= 330) {
        strcat(out, "#define varying in\n");
        strcat(out, "#define texture2DRect texture\n");
        strcat(out, "out vec4 fragColor;\n");
    } else {
        strcat(out, "#define fragColor gl_FragColor\n");
    }
#endif
    strcat(out, "\n");
    strcat(out, FS_GLES_STRING(
                vec3 rgb_adjust(vec3 rgb,vec3 rgbAdjustment) {
                    //C 是对比度值，B 是亮度值，S 是饱和度
                    float B = rgbAdjustment.x;
                    float S = rgbAdjustment.y;
                    float C = rgbAdjustment.z;

                    rgb = (rgb - 0.5) * C + 0.5;
                    rgb = rgb + (0.75 * B - 0.5) / 2.5 - 0.1;
                    vec3 intensity = vec3(dot(rgb, vec3(0.299, 0.587, 0.114)));
                    return intensity + S * (rgb - intensity);
                }
                                ));
    strcat(out, "\n");
    
    const char * buffer;
    //for rgbx
    switch (type) {
        case BGRX_SHADER:
        {
            buffer = g_shader_rect_bgrx_1;
        }
            break;
        case XRGB_SHADER:
        {
            buffer = g_shader_rect_xrgb_1;
        }
            break;
        case YUV_2P_SDR_SHADER:
        {
            buffer = g_shader_nv12;
        }
            break;
        case YUV_2P_HDR_SHADER:
        {
            buffer = g_shader_hdr;
        }
            break;
        case YUV_3P_SHADER:
        {
            buffer = g_shader_rect_3;
        }
            break;
        case UYVY_SHADER:
        case YUYV_SHADER:
        {
            if (ver >= 330) {
                buffer = g_shader_rect_uyvy_1;
            } else {
                buffer = g_shader_rect_uyvy_legacy_1;
            }
        }
            break;
        case NONE_SHADER:
        {
            assert(0);
            buffer = "";
        }
            break;
    }
    
    strcat(out, buffer);
}
