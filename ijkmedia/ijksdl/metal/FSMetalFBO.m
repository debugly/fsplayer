//
//  FSMetalFBO.m
//  FSMediaPlayerKit
//
//  Created by Reach Matt on 2024/4/10.
//

#import "FSMetalFBO.h"
@import Metal;
@import CoreVideo;

@interface FSMetalFBO()
{
    CVPixelBufferRef _pixelBuffer;
    MTLRenderPassDescriptor* _passDescriptor;
}
@end

@implementation FSMetalFBO

- (void)dealloc
{
    CVPixelBufferRelease(_pixelBuffer);
}

+ (CVPixelBufferRef)createCVPixelBufferWithSize:(CGSize)size
{
    CVPixelBufferRef pixelBuffer;
    NSDictionary* cvBufferProperties = @{
        (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    CVReturn cvret = CVPixelBufferCreate(kCFAllocatorDefault,
                                         size.width, size.height,
                                         kCVPixelFormatType_32BGRA,
                                         (__bridge CFDictionaryRef)cvBufferProperties,
                                         &pixelBuffer);
    
    
    if (cvret == kCVReturnSuccess) {
        return pixelBuffer;
    } else {
        NSAssert(NO, @"Failed to create CVPixelBuffer:%d",cvret);
    }
    return NULL;
}

/**
 Create a Metal texture from the CoreVideo pixel buffer using the following steps, and as annotated in the code listings below:
 */
+ (id <MTLTexture>)createMetalTextureFromCVPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                                device:(id<MTLDevice>)device
{
    CVMetalTextureCacheRef textureCache;
    // 1. Create a Metal Core Video texture cache from the pixel buffer.
    CVReturn cvret = CVMetalTextureCacheCreate(
                    kCFAllocatorDefault,
                    nil,
                    device,
                    nil,
                    &textureCache);
    
    if (cvret != kCVReturnSuccess) {
        NSLog(@"Failed to create Metal texture cache");
        return nil;
    }
    
    // 2. Create a CoreVideo pixel buffer backed Metal texture image from the texture cache.
    CVMetalTextureRef texture;
    size_t width  = (size_t)CVPixelBufferGetWidth(pixelBuffer);
    size_t height = (size_t)CVPixelBufferGetHeight(pixelBuffer);
    cvret = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault,
                    textureCache,
                    pixelBuffer, nil,
                    MTLPixelFormatBGRA8Unorm,
                    width, height,
                    0,
                    &texture);
    
    CFRelease(textureCache);
    
    if (cvret != kCVReturnSuccess) {
        NSLog(@"Failed to create CoreVideo Metal texture from image");
        return nil;
    }
    
    // 3. Get a Metal texture using the CoreVideo Metal texture reference.
    id <MTLTexture> metalTexture = CVMetalTextureGetTexture(texture);
    
    CFRelease(texture);
    
    if (!metalTexture) {
        NSLog(@"Failed to create Metal texture CoreVideo Metal Texture");
    }
    
    return metalTexture;
}

+ (MTLRenderPassDescriptor *)renderPassDescriptor:(id<MTLDevice>)device
                                      pixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    id<MTLTexture> renderTargetTexture = [self createMetalTextureFromCVPixelBuffer:pixelBuffer device:device];
    MTLRenderPassDescriptor *passDescriptor = [MTLRenderPassDescriptor new];
    passDescriptor.colorAttachments[0].texture = renderTargetTexture;
    passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    return passDescriptor;
}

- (BOOL)preparePassDescriptor:(CGSize)size device:(id<MTLDevice>)device
{
    if (!_passDescriptor) {
        // Texture to render to and then sample from.
        if (!_pixelBuffer) {
            _pixelBuffer = [[self class] createCVPixelBufferWithSize:size];
        }
        _passDescriptor = [[self class] renderPassDescriptor:device pixelBuffer:_pixelBuffer];
    }
    return !!_passDescriptor;
}

- (id<MTLRenderCommandEncoder>)createRenderEncoder:(id<MTLCommandBuffer>)commandBuffer
{
    return [commandBuffer renderCommandEncoderWithDescriptor:_passDescriptor];
}

- (id<MTLParallelRenderCommandEncoder>)createParallelRenderEncoder:(id<MTLCommandBuffer>)commandBuffer
{
    return [commandBuffer parallelRenderCommandEncoderWithDescriptor:_passDescriptor];
}

- (instancetype)init:(id<MTLDevice>)device
                size:(CGSize)targetSize
{
    self = [super init];
    if (self) {
        [self preparePassDescriptor:targetSize device:device];
    }
    return self;
}

- (BOOL)canReuse:(CGSize)size
{
    if (_pixelBuffer && _passDescriptor) {
        int width  = (int)CVPixelBufferGetWidth(_pixelBuffer);
        int height = (int)CVPixelBufferGetHeight(_pixelBuffer);
        if (width == (int)size.width && height == (int)size.height) {
            return YES;
        }
    }
    return NO;
}

- (CGSize)size
{
    return (CGSize){CVPixelBufferGetWidth(_pixelBuffer),CVPixelBufferGetHeight(_pixelBuffer)};
}

- (CVPixelBufferRef)pixelBuffer
{
    return _pixelBuffer;
}

- (id<MTLTexture>)texture
{
    return _passDescriptor.colorAttachments[0].texture;
}

@end
