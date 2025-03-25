//
//  ijksdl_gpu_opengl_macos.h
//  FSPlayer
//
//  Created by Reach Matt on 2024/4/14.
//

#import <Foundation/Foundation.h>

@class NSOpenGLContext;
typedef struct SDL_GPU SDL_GPU;

SDL_GPU *SDL_CreateGPU_WithGLContext(NSOpenGLContext * context);
