//
//  FSMetalFBO.h
//  FSMediaPlayerKit
//
//  Created by Reach Matt on 2024/4/10.
//

#import <Foundation/Foundation.h>

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
