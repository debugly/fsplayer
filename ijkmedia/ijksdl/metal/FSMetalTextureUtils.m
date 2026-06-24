//
//  FSMetalTextureUtils.m
//  FSPlayer
//
//  Created by debugly on 2026/6/18.
//

#import "FSMetalTextureUtils.h"
#import "FSMetalShaderTypes.h"

#define USE_METAL_TEXTURE_CACHE 1

mp_format * mp_get_metal_format(uint32_t cvpixfmt);

@implementation FSMetalTextureUtils

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
    
    NSAssert(ft != NULL, @"wrong pixel format type.");
    
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    const bool planar = CVPixelBufferIsPlanar(pixelBuffer);
    const int planes  = (int)CVPixelBufferGetPlaneCount(pixelBuffer);
    assert(planar && planes == ft->planes || ft->planes == 1);
    
    for (int i = 0; i < ft->planes; i++) {
        size_t width  = CVPixelBufferGetWidthOfPlane(pixelBuffer, i);
        size_t height = CVPixelBufferGetHeightOfPlane(pixelBuffer, i);
        MTLPixelFormat format = ft->formats[i];
#if USE_METAL_TEXTURE_CACHE
        CVMetalTextureRef textureRef = NULL;
        CVReturn status = CVMetalTextureCacheCreateTextureFromImage(NULL, textureCache, pixelBuffer, NULL, format, width, height, i, &textureRef);
        if (status == kCVReturnSuccess) {
            id<MTLTexture> texture = CVMetalTextureGetTexture(textureRef);
            if (texture != nil) {
                [result addObject:texture];
            }
            CFRelease(textureRef);
        }
#else
        MTLTextureDescriptor *textureDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                               width:width
                                                                                              height:height
                                                                                           mipmapped:NO];
        void *data = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, i);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, i);

        id<MTLTexture> texture = [device newTextureWithDescriptor:textureDesc];
        [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                           mipmapLevel:0
                             withBytes:data
                           bytesPerRow:stride];
        [result addObject:texture];
#endif
    }
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    return result;
}

@end
