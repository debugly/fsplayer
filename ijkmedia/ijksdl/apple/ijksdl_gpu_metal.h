//
//  ijksdl_gpu_metal.h
//  FSMediaPlayerKit
//
//  Created by Reach Matt on 2024/4/14.
//

#import <Foundation/Foundation.h>

@protocol MTLDevice;
typedef struct SDL_GPU SDL_GPU;

API_AVAILABLE(macos(10.13),ios(11.0),tvos(12.0))
SDL_GPU *SDL_CreateGPU_WithMTLDevice(id<MTLDevice>device);
