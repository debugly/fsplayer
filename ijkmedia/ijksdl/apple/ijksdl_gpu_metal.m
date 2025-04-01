/*
 * ijksdl_gpu_metal.m
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

#import "ijksdl_gpu_metal.h"
#import <MetalKit/MetalKit.h>
#import "FSMetalFBO.h"
#import "FSMetalSubtitlePipeline.h"
#import "ijksdl_gpu.h"
#include <libavutil/mem.h>
#import "ijksdl_vout_ios_gles2.h"

typedef struct SDL_GPU_Opaque_Metal {
    id<MTLDevice>device;
    id<MTLCommandQueue>commandQueue;
} SDL_GPU_Opaque_Metal;

typedef struct SDL_TextureOverlay_Opaque_Metal {
    id<MTLTexture>texture;
} SDL_TextureOverlay_Opaque_Metal;

API_AVAILABLE(macos(10.13),ios(11.0),tvos(12.0))
typedef struct API_AVAILABLE(macos(10.13),ios(11.0),tvos(12.0)) SDL_FBOOverlay_Opaque_Metal {
    SDL_TextureOverlay *texture;
    FSMetalFBO* fbo;
    id<MTLCommandQueue>commandQueue;
    id<MTLRenderCommandEncoder> renderEncoder;
    id<MTLParallelRenderCommandEncoder> parallelRenderEncoder;
    id<MTLCommandBuffer> commandBuffer;
    FSMetalSubtitlePipeline*subPipeline;
} SDL_FBOOverlay_Opaque_Metal;

static void* getTexture(SDL_TextureOverlay *overlay);

#pragma mark - Texture Metal

static void replaceRegion(SDL_TextureOverlay *overlay, SDL_Rectangle rect, void *pixels)
{
    if (overlay && overlay->opaque) {
        SDL_TextureOverlay_Opaque_Metal *op = overlay->opaque;
        if (op->texture) {
            if (rect.x + rect.w > op->texture.width) {
                rect.x = 0;
                rect.w = (int)op->texture.width;
            }
            
            if (rect.y + rect.h > op->texture.height) {
                rect.y = 0;
                rect.h = (int)op->texture.height;
            }
            
            overlay->dirtyRect = SDL_union_rectangle(overlay->dirtyRect, rect);
            
            int bpr = rect.stride;
            MTLRegion region = {
                {rect.x, rect.y, 0}, // MTLOrigin
                {rect.w, rect.h, 1} // MTLSize
            };

            [op->texture replaceRegion:region
                           mipmapLevel:0
                             withBytes:pixels
                           bytesPerRow:bpr];
        }
    }
}

static void clearMetalRegion(SDL_TextureOverlay *overlay)
{
    if (!overlay) {
        return;
    }
    
    if (isZeroRectangle(overlay->dirtyRect)) {
        return;
    }
    
    void *pixels = av_mallocz(overlay->dirtyRect.stride * overlay->dirtyRect.h);
    replaceRegion(overlay, overlay->dirtyRect, pixels);
    av_free(pixels);
    overlay->dirtyRect = SDL_Zero_Rectangle;
}

static void dealloc_texture(SDL_TextureOverlay *overlay)
{
    if (overlay) {
        SDL_TextureOverlay_Opaque_Metal *opaque = overlay->opaque;
        if (opaque) {
            opaque->texture = NULL;
            free(opaque);
        }
        overlay->opaque = NULL;
    }
}

static SDL_TextureOverlay * create_textureOverlay_with_mtlTexture(id<MTLTexture> texture)
{
    if (!texture) {
        return NULL;
    }
    
    SDL_TextureOverlay *overlay = (SDL_TextureOverlay*) calloc(1, sizeof(SDL_TextureOverlay));
    if (!overlay)
        return NULL;
    
    SDL_TextureOverlay_Opaque_Metal *opaque = (SDL_TextureOverlay_Opaque_Metal*) calloc(1, sizeof(SDL_TextureOverlay_Opaque_Metal));
    if (!opaque) {
        free(overlay);
        return NULL;
    }
    
    opaque->texture = texture;
    overlay->opaque = opaque;
    overlay->w = (int)texture.width;
    overlay->h = (int)texture.height;
    overlay->refCount = 1;
    bzero(overlay->palette, sizeof(overlay->palette));
    
    overlay->replaceRegion = replaceRegion;
    overlay->getTexture = getTexture;
    overlay->clearDirtyRect = clearMetalRegion;
    overlay->dealloc = dealloc_texture;
    
    return overlay;
}

static SDL_TextureOverlay *createMetalTexture(id<MTLDevice>device, int w, int h, SDL_TEXTURE_FMT fmt, const void *pixels)
{
    MTLTextureDescriptor *textureDescriptor = [[MTLTextureDescriptor alloc] init];

    if (fmt == SDL_TEXTURE_FMT_A8) {
        textureDescriptor.pixelFormat = MTLPixelFormatA8Unorm;
    } else if (fmt == SDL_TEXTURE_FMT_BRGA) {
        textureDescriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
    } else {
        assert(0);
    }
    
    // Set the pixel dimensions of the texture
    
    textureDescriptor.width  = w;
    textureDescriptor.height = h;
    
    // Create the texture from the device by using the descriptor
    id<MTLTexture> subTexture = [device newTextureWithDescriptor:textureDescriptor];
    if (pixels) {
        int bpr = w;
        MTLRegion region = {
            {0, 0, 0}, // MTLOrigin
            {w, h, 1} // MTLSize
        };

        [subTexture replaceRegion:region
                      mipmapLevel:0
                        withBytes:pixels
                      bytesPerRow:bpr];
    }
    SDL_TextureOverlay * to = create_textureOverlay_with_mtlTexture(subTexture);
    if (pixels) {
        to->dirtyRect = (SDL_Rectangle){0,0,w,h,w};
    }
    return to;
}

#pragma mark - Texture

static void* getTexture(SDL_TextureOverlay *overlay)
{
    if (overlay && overlay->opaque) {
        SDL_TextureOverlay_Opaque_Metal *opaque = overlay->opaque;
        return (__bridge void *)opaque->texture;
    }
    return NULL;
}

static SDL_TextureOverlay *createTexture(SDL_GPU *gpu, int w, int h, SDL_TEXTURE_FMT fmt, const void *pixels)
{
    if (!gpu && ! gpu->opaque) {
        return NULL;
    }
    
    SDL_GPU_Opaque_Metal *gop = gpu->opaque;
    return createMetalTexture(gop->device, w, h, fmt, pixels);
}

#pragma mark - FBO Metal

API_AVAILABLE(macos(10.13),ios(11.0),tvos(12.0))
static SDL_FBOOverlay *createMetalFBO(id<MTLDevice> device, int w, int h)
{
    if (!device) {
        return NULL;
    }
    
    SDL_FBOOverlay *overlay = (SDL_FBOOverlay*) calloc(1, sizeof(SDL_FBOOverlay));
    if (!overlay)
        return NULL;
    
    SDL_FBOOverlay_Opaque_Metal *opaque = (SDL_FBOOverlay_Opaque_Metal*) calloc(1, sizeof(SDL_FBOOverlay_Opaque_Metal));
    if (!opaque) {
        free(overlay);
        return NULL;
    }
    
    CGSize size = CGSizeMake(w, h);
    if (opaque->fbo) {
        if (![opaque->fbo canReuse:size]) {
            opaque->fbo = nil;
        }
    }
    if (!opaque->fbo) {
        opaque->fbo = [[FSMetalFBO alloc] init:device size:size];
    }
    opaque->commandQueue = [device newCommandQueue];
    overlay->opaque = (void *)opaque;
    return overlay;
}

#pragma mark - FBO

API_AVAILABLE(macos(10.13),ios(11.0),tvos(12.0))
static void beginDraw_fbo(SDL_GPU *gpu, SDL_FBOOverlay *overlay, int ass)
{
    if (!gpu || !gpu->opaque || !overlay || !overlay->opaque) {
        return;
    }
    
    SDL_FBOOverlay_Opaque_Metal *fop = overlay->opaque;
    SDL_GPU_Opaque_Metal *gop = gpu->opaque;
    if (ass) {
        
    } else {
        if (!fop->subPipeline) {
            if (@available(macOS 10.13, *)) {
                FSMetalSubtitlePipeline *subPipeline = [[FSMetalSubtitlePipeline alloc] initWithDevice:gop->device inFormat:FSMetalSubtitleInFormatA8 outFormat:FSMetalSubtitleOutFormatDIRECT];
                if ([subPipeline createRenderPipelineIfNeed]) {
                    fop->subPipeline = subPipeline;
                }
            } else {
                // Fallback on earlier versions
            }
        }
        
        if (fop->subPipeline) {
            id<MTLCommandBuffer>commandBuffer = [fop->commandQueue commandBuffer];
            fop->renderEncoder = [fop->fbo createRenderEncoder:commandBuffer];
            fop->commandBuffer = commandBuffer;
            
            // Set the region of the drawable to draw into.
            CGSize viewport = [fop->fbo size];
            [fop->renderEncoder setViewport:(MTLViewport){0.0, 0.0, viewport.width, viewport.height, -1.0, 1.0}];
        } else {
            return;
        }
    }
}

API_AVAILABLE(macos(10.13),ios(11.0),tvos(12.0))
static void drawTexture_fbo(SDL_GPU *gpu, SDL_FBOOverlay *foverlay, SDL_TextureOverlay *toverlay, SDL_Rectangle frame)
{
    if (!foverlay || !toverlay) {
        return;
    }
    
    SDL_FBOOverlay_Opaque_Metal *fop = foverlay->opaque;
    CGSize viewport = [fop->fbo size];
    CGRect rect = FSSDL_make_metal_NDC(frame, toverlay->scale, viewport);
    [fop->subPipeline updateSubtitleVertexIfNeed:rect];
    id<MTLTexture>texture = (__bridge id<MTLTexture>)toverlay->getTexture(toverlay);
    [fop->subPipeline drawTexture:texture encoder:fop->renderEncoder colors:toverlay->palette];
}

API_AVAILABLE(macos(10.13),ios(11.0),tvos(12.0))
static void endDraw_fbo(SDL_GPU *gpu, SDL_FBOOverlay *overlay)
{
    if (!overlay || !overlay->opaque) {
        return;
    }
    
    SDL_FBOOverlay_Opaque_Metal *fop = overlay->opaque;
    
    [fop->renderEncoder endEncoding];
    [fop->renderEncoder popDebugGroup];
    [fop->parallelRenderEncoder endEncoding];
    [fop->commandBuffer commit];
    [fop->commandBuffer waitUntilCompleted];

    fop->renderEncoder = nil;
    fop->parallelRenderEncoder = nil;
    fop->commandBuffer = nil;
}

static void clear_fbo(SDL_FBOOverlay *overlay)
{
    
}

API_AVAILABLE(macos(10.13),ios(11.0),tvos(12.0))
static void dealloc_fbo(SDL_FBOOverlay *overlay)
{
    if (!overlay || !overlay->opaque) {
        return;
    }
    
    SDL_FBOOverlay_Opaque_Metal *fop = overlay->opaque;
    
    SDL_TextureOverlay_Release(&fop->texture);
    fop->fbo = nil;
    fop->commandQueue = nil;
    fop->renderEncoder = nil;
    fop->commandBuffer = nil;
    fop->subPipeline = nil;
    free(fop);
}

API_AVAILABLE(macos(10.13),ios(11.0),tvos(12.0))
static SDL_TextureOverlay * getTexture_fbo(SDL_FBOOverlay *foverlay)
{
    if (!foverlay || !foverlay->opaque) {
        return NULL;
    }
    
    SDL_FBOOverlay_Opaque_Metal *fop = foverlay->opaque;
    if (!fop->texture) {
        id<MTLTexture> subTexture = [fop->fbo texture];
        fop->texture = create_textureOverlay_with_mtlTexture(subTexture);
    }
    return SDL_TextureOverlay_Retain(fop->texture);
}

API_AVAILABLE(macos(10.13),ios(11.0),tvos(12.0))
static SDL_FBOOverlay *createFBO(SDL_GPU *gpu, int w, int h)
{
    if (!gpu || !gpu->opaque) {
        return NULL;
    }
    
    SDL_GPU_Opaque_Metal *gop = gpu->opaque;
    SDL_FBOOverlay *overlay = createMetalFBO(gop->device, w, h);
    
    if (overlay) {
        overlay->w = w;
        overlay->h = h;
        overlay->beginDraw = beginDraw_fbo;
        overlay->drawTexture = drawTexture_fbo;
        overlay->endDraw = endDraw_fbo;
        overlay->clear = clear_fbo;
        overlay->getTexture = getTexture_fbo;
        overlay->dealloc = dealloc_fbo;
    }
    return overlay;
}

#pragma mark - GPU

static void dealloc_gpu(SDL_GPU *gpu)
{
    if (!gpu || !gpu->opaque) {
        return;
    }
    
    SDL_GPU_Opaque_Metal *gop = gpu->opaque;
    gop->device = NULL;
    gop->commandQueue = NULL;
    free(gop);
}

API_AVAILABLE(macos(10.13),ios(11.0),tvos(12.0))
SDL_GPU *SDL_CreateGPU_WithMTLDevice(id<MTLDevice>device)
{
    if (!device) {
        return NULL;
    }
    SDL_GPU *gl = (SDL_GPU*) calloc(1, sizeof(SDL_GPU));
    if (!gl)
        return NULL;
    
    SDL_GPU_Opaque_Metal *opaque = av_mallocz(sizeof(SDL_GPU_Opaque_Metal));
    if (!opaque) {
        free(gl);
        return NULL;
    }
    opaque->device = device;
    gl->opaque = opaque;
    gl->createTexture = createTexture;
    gl->createFBO = createFBO;
    gl->dealloc = dealloc_gpu;
    
    return gl;
}
