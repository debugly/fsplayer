//
//  FSMetalTileGridPipeline.h
//  FSPlayer
//
//  Created by debugly on 2026/6/16.
//

@import MetalKit;

@class FSTilePiece;

NS_ASSUME_NONNULL_BEGIN

// 把 HEIC tile-grid 的多个 tile 合成成一张完整画面（BGRA），返回可直接采样显示的纹理。
// 合成阶段不做旋转/调色，只把每个 tile 按位置铺到画布上；调用方拿到纹理后可当普通单帧来
// 旋转/缩放/快照，从而让旋转作用于整张图，避免逐 tile 旋转错乱。
// 输入 attach 保持不变；后续旋转/刷新由视图复用自己的合成结果。
@interface FSMetalTileGridPipeline : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device;

// 将 tilePieces 按各自位置铺到 canvasW x canvasH 的画布上，返回合成后的 BGRA 纹理。
// textureCache 用于生成纹理（可为 NULL）；commandQueue 用于提交合成命令。失败返回 nil。
- (id<MTLTexture>)compositeTileGrid:(NSArray<FSTilePiece *> *)tilePieces
                            canvasW:(int)canvasW
                            canvasH:(int)canvasH
                       textureCache:(CVMetalTextureCacheRef)textureCache
                       commandQueue:(id<MTLCommandQueue>)commandQueue;

// 最近一次合成结果的 BGRA CVPixelBuffer（纹理的后备缓冲）。
// 调用方用它来建立/匹配显示用的渲染管线（管线需要按像素格式选择 shader）。
@property (nonatomic, readonly, nullable) CVPixelBufferRef compositedPixelBuffer;

@end

NS_ASSUME_NONNULL_END
