//
//  FSMetalPipelineMeta.h
//  FSPlayer
//
//  Created by debugly on 2023/6/26.
//

#import <Foundation/Foundation.h>
#import "FSMetalShaderTypes.h"
#import <CoreVideo/CVPixelBuffer.h>

NS_ASSUME_NONNULL_BEGIN

static inline CFTypeRef _Nullable FSMetalCopyBufferAttachment(CVBufferRef buffer, CFStringRef key) CF_RETURNS_RETAINED
{
    if (@available(macOS 12.0, iOS 15.0, tvOS 15.0, *)) {
        return CVBufferCopyAttachment(buffer, key, NULL);
    }

    // Older systems only provide the borrowed attachment API.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CFTypeRef attachment = CVBufferGetAttachment(buffer, key, NULL);
#pragma clang diagnostic pop
    return attachment ? CFRetain(attachment) : NULL;
}

@interface FSMetalPipelineMeta : NSObject

@property (nonatomic) BOOL hdrContent;
@property (nonatomic) BOOL fullRange;
@property (nonatomic) NSString* fragmentName;
@property (nonatomic) FSColorTransferFunc transferFunc;
@property (nonatomic) FSYUV2RGBColorMatrixType convertMatrixType;

+ (FSMetalPipelineMeta *)createWithCVPixelbuffer:(CVPixelBufferRef)pixelBuffer;
- (BOOL)metaMatchedCVPixelbuffer:(CVPixelBufferRef)pixelBuffer;

/// Lightweight check: returns YES when the pixel buffer carries HDR content
/// (BT.2020 color matrix). Does not allocate a full FSMetalPipelineMeta.
+ (BOOL)isHDRContentWithPixelBuffer:(CVPixelBufferRef)pixelBuffer;

- (NSString *)description:(BOOL)displayHDR;
@end

NS_ASSUME_NONNULL_END
