//
//  FSMetalBlurFilter.h
//  FSPlayer
//
//  Created by debugly on 2026/6/16.
//

@import Foundation;
@import MetalKit;

NS_ASSUME_NONNULL_BEGIN

// 对图片做多次高斯模糊，生成可直接采样的 BGRA 纹理（用作视频背景）。
@interface FSMetalBlurFilter : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device;

// 把图片缩小后做 iterations 次高斯模糊，返回 BGRA(premultiplied) 纹理。
// iterations 越多越模糊（有效 sigma 约按 sqrt(iterations) 增长），推荐 2~4。
- (nullable id<MTLTexture>)blurredTextureFromImage:(CGImageRef)cgImage
                                        iterations:(int)iterations
                                      commandQueue:(id<MTLCommandQueue>)commandQueue;

@end

NS_ASSUME_NONNULL_END
