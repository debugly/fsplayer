/*
 * ijksdl_vout_ios_gles2.h
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

#include "ijksdl/ijksdl_stdinc.h"
#include "ijksdl/ijksdl_vout.h"
#include "../ijksdl_gpu.h"

#import "FSVideoRenderingProtocol.h"

#if TARGET_OS_OSX
@protocol FSSDLSubtitleTextureWrapper <NSObject>

@property(nonatomic) uint32_t texture;
@property(nonatomic) int w;
@property(nonatomic) int h;

@end

id<FSSDLSubtitleTextureWrapper> FSSDL_crate_openglTextureWrapper(uint32_t texture, int w, int h);

// Normalized Device Coordinates
static inline CGRect FSSDL_make_openGL_NDC(SDL_Rectangle frame, float scale, CGSize viewport)
{
    float swidth  = frame.w * scale;
    float sheight = frame.h * scale;
    
    float width  = viewport.width;
    float height = viewport.height;
    
    //处理缩放导致的坐标变化
    float sx = frame.x - (scale - 1.0) * frame.w * 0.5;
    float sy = frame.y;
    
    if (sy > height - sheight) {
        sy = height - sheight;
    }
    
    if (sy < 0) {
        sy = 0;
    }
    
#define NDC(x) (x * 2.0 - 1.0)
    float x = NDC(sx / width);
    //将 y 的原始值范围 [0,(height - sheight) / height] 转化到 [-1,1] 标准化范围
    //计算的是从上往下的距离
    float y = NDC(sy / height);
#undef NDC
    
    /*
     (x,y)在左上角，y轴，-1在最上面，1在最下面
     x,y--------
     |          |
     |----------
     */
    
    if (width != 0 && height != 0) {
        return (CGRect){
            x,
            y,
            2.0 * (swidth / width),
            2.0 * (sheight / height)
        };
    }
    return CGRectZero;
}

#endif

// Normalized Device Coordinates
static inline CGRect FSSDL_make_metal_NDC(SDL_Rectangle frame, float scale, CGSize viewport)
{
    float swidth  = frame.w * scale;
    float sheight = frame.h * scale;
    
    float width  = viewport.width;
    float height = viewport.height;
    
    //处理缩放导致的坐标变化
    float sx = frame.x - (scale - 1.0) * frame.w * 0.5;
    //图像y轴正方向朝下，加上高度表示的是左下角的坐标；
    float sy = frame.y + sheight;
    
    //左下角往下最多贴着最下面
    if (sy > height) {
        sy = height;
    }
    //左下角往上最少要保持一个内容的高度
    if (sy < sheight) {
        sy = sheight;
    }
    
#define NDC(x) (x * 2.0 - 1.0)
    float x = NDC(sx / width);
    //计算的是从下往上的距离
    float y = NDC((height - sy) / height);
#undef NDC

    //实际输出 [maxY,-1]
    /*
     (x,y)在左下角，y轴，1在最上面，-1在最下面
      ----------
     |          |
     x,y--------
     */
    
    if (width != 0 && height != 0) {
        return (CGRect){
            x,
            y,
            2.0 * (swidth / width),
            2.0 * (sheight / height)
        };
    }
    return CGRectZero;
}

SDL_Vout *SDL_VoutIos_CreateForGLES2(void);
void SDL_VoutIos_SetGLView(SDL_Vout *vout, UIView<FSVideoRenderingProtocol>* view);
SDL_GPU *SDL_CreateGPU_WithContext(id context);

