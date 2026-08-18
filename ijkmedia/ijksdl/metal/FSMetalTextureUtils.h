//
//  FSMetalTextureUtils.h
//  FSPlayer
//
//  Created by debugly on 2026/6/18.
//

@import MetalKit;

NS_ASSUME_NONNULL_BEGIN

/// 将 CVPixelBufferRef 转换为 Metal 纹理数组（每个平面一个纹理）。
/// 支持 planar YUV（NV12 / YUV420P 等）和单平面格式。
/// 是否零拷贝由调用方决定：传入 textureCache 则 wrap IOSurface，
/// 传 NULL 或 wrap 失败则回退 CPU 上传。
@interface FSMetalTextureUtils : NSObject

/// 从 pixelBuffer 生成 Metal 纹理。
/// @param pixelBuffer 输入像素缓冲（YUV/RGB 等，由内部 mp_format 表查 Metal 格式）。
/// @param textureCache  Metal Texture Cache（可为 NULL，不传时走 CPU 上传路径）。
/// @param device Metal 设备。
/// @return 纹理数组（按平面顺序），任一平面失败整体返回 nil。
+ (nullable NSArray<id<MTLTexture>> *)doGenerateTexture:(CVPixelBufferRef)pixelBuffer
                                           textureCache:(nullable CVMetalTextureCacheRef)textureCache
                                                 device:(id<MTLDevice>)device;

/// 从 pixelBuffer 生成 Metal 纹理，同时通过 outCVTextures 输出包裹了 CVPixelBuffer 的 CVMetalTextureRef 引用。
/// 获得 outCVTextures 后由调用方（如 FSOverlayAttach）负责在合适时机执行 CFRelease。
+ (nullable NSArray<id<MTLTexture>> *)doGenerateTexture:(CVPixelBufferRef)pixelBuffer
                                           textureCache:(nullable CVMetalTextureCacheRef)textureCache
                                                 device:(id<MTLDevice>)device
                                          outCVTextures:(NSMutableArray * _Nullable * _Nullable)outCVTextures;

@end

NS_ASSUME_NONNULL_END
