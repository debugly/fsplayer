//
//  FSMetalSubtitlePipeline.h
//  FSMediaPlayerKit
//
//  Created by Reach Matt on 2022/12/23.
//

@import MetalKit;

NS_ASSUME_NONNULL_BEGIN

typedef enum : NSUInteger {
    FSMetalSubtitleOutFormatDIRECT,
    FSMetalSubtitleOutFormatSWAP_RB
} FSMetalSubtitleOutFormat;

typedef enum : NSUInteger {
    FSMetalSubtitleInFormatBRGA,
    FSMetalSubtitleInFormatA8,
} FSMetalSubtitleInFormat;

API_AVAILABLE(macos(10.13),ios(11.0),tvos(12.0))
@interface FSMetalSubtitlePipeline : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device
                      inFormat:(FSMetalSubtitleInFormat)inFormat
                     outFormat:(FSMetalSubtitleOutFormat)outFormat;

- (BOOL)createRenderPipelineIfNeed;
- (void)updateSubtitleVertexIfNeed:(CGRect)rect;
- (void)drawTexture:(id)subTexture encoder:(id<MTLRenderCommandEncoder>)encoder;
- (void)drawTexture:(id)subTexture encoder:(id<MTLRenderCommandEncoder>)encoder colors:(void *)colors;

@end

NS_ASSUME_NONNULL_END
