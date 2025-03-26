//
//  FSMetalPipelineMeta.h
//  FSPlayer
//
//  Created by debugly on 2023/6/26.
//

#import <Foundation/Foundation.h>
#import "FSMetalShaderTypes.h"

NS_ASSUME_NONNULL_BEGIN
NS_CLASS_AVAILABLE(10_13, 11_0)
@interface FSMetalPipelineMeta : NSObject

@property (nonatomic) BOOL hdr;
@property (nonatomic) BOOL fullRange;
@property (nonatomic) NSString* fragmentName;
@property (nonatomic) FSColorTransferFunc transferFunc;
@property (nonatomic) FSYUV2RGBColorMatrixType convertMatrixType;

+ (FSMetalPipelineMeta *)createWithCVPixelbuffer:(CVPixelBufferRef)pixelBuffer;
- (BOOL)metaMatchedCVPixelbuffer:(CVPixelBufferRef)pixelBuffer;

@end

NS_ASSUME_NONNULL_END
