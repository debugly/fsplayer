/*
 * ijksdl_gpu_opengl_renderer_macos.h
 *
 * Copyright (c) 2024 debugly <qianlongxu@gmail.com>
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

#import <Foundation/Foundation.h>

@class FSSDLOpenGLFBO;
@protocol FSSDLSubtitleTextureWrapper;

@interface FSSDLOpenGLSubRenderer : NSObject

- (void)setupOpenGLProgramIfNeed;
- (void)clean;
- (void)bindFBO:(FSSDLOpenGLFBO *)fbo;
- (void)updateSubtitleVertexIfNeed:(CGRect)rect;
- (void)drawTexture:(id<FSSDLSubtitleTextureWrapper>)subTexture colors:(void *)colors;

@end
