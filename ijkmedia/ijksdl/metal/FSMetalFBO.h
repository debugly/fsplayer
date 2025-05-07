//
//  FSMetalFBO.h
//  FSPlayer
//
//  Created by debugly on 2024/4/10.
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CVPixelBuffer.h>
#import <Metal/MTLTexture.h>

NS_ASSUME_NONNULL_BEGIN


@protocol MTLRenderCommandEncoder,MTLParallelRenderCommandEncoder,MTLCommandBuffer,MTLDevice;

@interface FSMetalFBO : NSObject

- (instancetype)init:(id<MTLDevice>)device
                size:(CGSize)targetSize;

- (BOOL)canReuse:(CGSize)size;
- (id<MTLRenderCommandEncoder>)createRenderEncoder:(id<MTLCommandBuffer>)commandBuffer;
- (id<MTLParallelRenderCommandEncoder>)createParallelRenderEncoder:(id<MTLCommandBuffer>)commandBuffer;
- (CGSize)size;
- (CVPixelBufferRef)pixelBuffer;
- (id<MTLTexture>)texture;

@end

NS_ASSUME_NONNULL_END
