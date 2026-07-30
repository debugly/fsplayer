//
//  FSMetalBlurFilter.m
//  FSPlayer
//
//  Created by debugly on 2026/6/16.
//

#import "FSMetalBlurFilter.h"
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

@interface FSMetalBlurFilter ()
{
    id<MTLDevice> _device;
}
@end

@implementation FSMetalBlurFilter

- (instancetype)initWithDevice:(id<MTLDevice>)device
{
    self = [super init];
    if (self) {
        NSAssert(device, @"device can't be nil!");
        _device = device;
    }
    return self;
}

- (id<MTLTexture>)blurredTextureFromImage:(CGImageRef)cgImage
                                    sigma:(float)sigma
                               iterations:(int)iterations
                             commandQueue:(id<MTLCommandQueue>)commandQueue
{
    if (!cgImage || !_device || !commandQueue) {
        return nil;
    }

    size_t srcW = CGImageGetWidth(cgImage);
    size_t srcH = CGImageGetHeight(cgImage);
    if (srcW == 0 || srcH == 0) {
        return nil;
    }

    // 背景不需要高分辨率，缩小本身就能加重模糊并显著降低开销。
    const CGFloat maxSide = 400.0;
    CGFloat scale = MIN(1.0, maxSide / MAX(srcW, srcH));
    size_t w = MAX((size_t)1, (size_t)(srcW * scale));
    size_t h = MAX((size_t)1, (size_t)(srcH * scale));

    // 画到 BGRA(premultiplied) 位图，匹配字幕管线 DIRECT 片元的取样格式。
    size_t bytesPerRow = w * 4;
    void *data = calloc(h, bytesPerRow);
    if (!data) {
        return nil;
    }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(data, w, h, 8, bytesPerRow, cs,
                                             (uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        free(data);
        return nil;
    }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cgImage);

    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                   width:w
                                                                                  height:h
                                                                               mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> texA = [_device newTextureWithDescriptor:desc];
    id<MTLTexture> texB = [_device newTextureWithDescriptor:desc];
    if (texA) {
        [texA replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:data bytesPerRow:bytesPerRow];
    }
    free(data);
    CGContextRelease(ctx);
    if (!texA || !texB) {
        return texA;
    }

    MPSImageGaussianBlur *blur = [[MPSImageGaussianBlur alloc] initWithDevice:_device sigma:sigma > 0 ? sigma : 30.0];
    blur.edgeMode = MPSImageEdgeModeClamp;

    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    id<MTLTexture> src = texA;
    id<MTLTexture> dst = texB;
    int n = MAX(1, iterations);
    for (int i = 0; i < n; i++) {
        [blur encodeToCommandBuffer:commandBuffer sourceTexture:src destinationTexture:dst];
        id<MTLTexture> tmp = src; src = dst; dst = tmp;
    }
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    // n 次交换后，结果在 src。
    return src;
}

@end
