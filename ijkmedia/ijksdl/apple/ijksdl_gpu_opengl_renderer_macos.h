//
//  ijksdl_gpu_opengl_renderer_macos.h
//  FSPlayer
//
//  Created by Reach Matt on 2024/4/15.
//

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
