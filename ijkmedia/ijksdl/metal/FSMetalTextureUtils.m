//
//  FSMetalTextureUtils.m
//  FSPlayer
//
//  Created by debugly on 2026/6/18.
//

#import "FSMetalTextureUtils.h"
#import "FSMetalShaderTypes.h"
#include "../ijksdl_log.h"

mp_format * mp_get_metal_format(uint32_t cvpixfmt);

@implementation FSMetalTextureUtils

/// CPU 上传单个平面。non-planar 格式必须用 GetBaseAddress 系列，
/// GetBaseAddressOfPlane 对 non-planar buffer 返回 NULL。
+ (id<MTLTexture>)uploadPlane:(CVPixelBufferRef)pixelBuffer
                        plane:(int)plane
                       planar:(bool)planar
                       format:(MTLPixelFormat)format
                        width:(size_t)width
                       height:(size_t)height
                       device:(id<MTLDevice>)device
{
    void *data;
    size_t stride;
    if (planar) {
        data   = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane);
        stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane);
    } else {
        data   = CVPixelBufferGetBaseAddress(pixelBuffer);
        stride = CVPixelBufferGetBytesPerRow(pixelBuffer);
    }

    if (!data || stride == 0) {
        ALOGE("upload texture failed: no base address, plane:%d planar:%d\n", plane, planar);
        return nil;
    }

    MTLTextureDescriptor *textureDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                           width:width
                                                                                          height:height
                                                                                       mipmapped:NO];
    id<MTLTexture> texture = [device newTextureWithDescriptor:textureDesc];
    if (!texture) {
        ALOGE("upload texture failed: create texture, plane:%d format:%d\n", plane, (int)format);
        return nil;
    }
    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
               mipmapLevel:0
                 withBytes:data
               bytesPerRow:stride];
    return texture;
}

+ (NSArray<id<MTLTexture>> *)doGenerateTexture:(CVPixelBufferRef)pixelBuffer
                                  textureCache:(CVMetalTextureCacheRef)textureCache
                                        device:(id<MTLDevice>)device
{
    if (!pixelBuffer) {
        return nil;
    }

    NSMutableArray *result = [NSMutableArray array];

    OSType type = CVPixelBufferGetPixelFormatType(pixelBuffer);
    mp_format *ft = mp_get_metal_format(type);

    if (ft == NULL) {
        ALOGE("generate texture failed: unsupported pixel format:%4s\n", (char *)&type);
        return nil;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    const bool planar = CVPixelBufferIsPlanar(pixelBuffer);
    const int planes  = planar ? (int)CVPixelBufferGetPlaneCount(pixelBuffer) : 1;
    if (planes != ft->planes) {
        ALOGE("generate texture failed: plane count mismatch, buffer:%d table:%d format:%4s\n",
              planes, ft->planes, (char *)&type);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        return nil;
    }

    for (int i = 0; i < ft->planes; i++) {
        size_t width  = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, i)  : CVPixelBufferGetWidth(pixelBuffer);
        size_t height = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, i) : CVPixelBufferGetHeight(pixelBuffer);
        MTLPixelFormat format = ft->formats[i];
        id<MTLTexture> texture = nil;
        if (textureCache) {
            CVMetalTextureRef textureRef = NULL;
            CVReturn status = CVMetalTextureCacheCreateTextureFromImage(NULL, textureCache, pixelBuffer, NULL, format, width, height, i, &textureRef);
            if (status == kCVReturnSuccess) {
                texture = CVMetalTextureGetTexture(textureRef);
                if (texture == nil) {
                    ALOGE("wrap texture failed: null texture, plane:%d format:%4s\n", i, (char *)&type);
                }
                CFRelease(textureRef);
            } else {
                ALOGE("wrap texture failed:%d, plane:%d mtlformat:%d format:%4s\n",
                      status, i, (int)format, (char *)&type);
            }
        }
        // 纹理 cache 不可用或失败时回退到 CPU 上传
        if (texture == nil) {
            texture = [self uploadPlane:pixelBuffer
                                  plane:i
                                 planar:planar
                                 format:format
                                  width:width
                                 height:height
                                 device:device];
        }

        if (texture == nil) {
            // 任一平面失败就整帧丢弃，宁可掉帧
            CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
            return nil;
        }
        [result addObject:texture];
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    return result;
}

@end
