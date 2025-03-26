//
//  FSMetalOffscreenRendering.m
//  FFmpegTutorial-macOS
//
//  Created by debugly on 2022/12/2.
//  Copyright © 2022 debugly's Awesome FFmpeg Tutotial. All rights reserved.
//


#import "FSMetalOffscreenRendering.h"
#import "FSMetalFBO.h"
@import CoreImage;
@import Metal;

@interface FSMetalOffscreenRendering ()
{
    FSMetalFBO* _fbo;
}
@end

@implementation FSMetalOffscreenRendering

- (CGImageRef)_snapshot
{
    CVPixelBufferRef pixelBuffer = CVPixelBufferRetain([_fbo pixelBuffer]);
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    
    static CIContext *context = nil;
    if (!context) {
        context = [CIContext contextWithOptions:NULL];
    }
    CGRect rect = CGRectMake(0,0,
                             CVPixelBufferGetWidth(pixelBuffer),
                             CVPixelBufferGetHeight(pixelBuffer));
    CGImageRef imageRef = [context createCGImage:ciImage fromRect:rect];
    CVPixelBufferRelease(pixelBuffer);
    return imageRef ? (CGImageRef)CFAutorelease(imageRef) : NULL;
}

- (CGImageRef)snapshot:(CGSize)targetSize
                device:(id <MTLDevice>)device
         commandBuffer:(id<MTLCommandBuffer>)commandBuffer
       doUploadPicture:(void(^)(id<MTLRenderCommandEncoder>))block
{
    if (![_fbo canReuse:targetSize]) {
        _fbo = [[FSMetalFBO alloc] init:device size:targetSize];
    }
    
    id<MTLRenderCommandEncoder> renderEncoder = [_fbo createRenderEncoder:commandBuffer];
    
    if (!renderEncoder) {
        return NULL;
    }
    
    if (block) {
        block(renderEncoder);
    }
    [renderEncoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    return [self _snapshot];
}

@end
