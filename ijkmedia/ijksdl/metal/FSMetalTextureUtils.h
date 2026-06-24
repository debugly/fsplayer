//
//  FSMetalTextureUtils.h
//  FSPlayer
//
//  Created by debugly on 2026/6/18.
//

@import MetalKit;

NS_ASSUME_NONNULL_BEGIN

/// 将 CVPixelBufferRef 转换为 Metal 纹理数组（每个平面一个纹理）。
/// 支持 planar YUV（NV12 / YUV420P 等）和单平面格式，自动适配 Metal Texture Cache
/// 或 CPU 上传两种路径（由 USE_METAL_TEXTURE_CACHE 编译开关控制）。
@interface FSMetalTextureUtils : NSObject

/// 从 pixelBuffer 生成 Metal 纹理。
/// @param pixelBuffer 输入像素缓冲（YUV/RGB 等，由内部 mp_format 表查 Metal 格式）。
/// @param textureCache  Metal Texture Cache（可为 NULL，不传时走 CPU 上传路径）。
/// @param device Metal 设备。
/// @return 纹理数组（按平面顺序），失败返回 nil。
+ (nullable NSArray<id<MTLTexture>> *)doGenerateTexture:(CVPixelBufferRef)pixelBuffer
                                           textureCache:(nullable CVMetalTextureCacheRef)textureCache
                                                 device:(id<MTLDevice>)device;

@end

NS_ASSUME_NONNULL_END
