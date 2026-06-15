//
//  FSMetalRenderer.h
//  FFmpegTutorial-macOS
//
//  Created by debugly on 2022/11/23.
//  Copyright © 2022 debugly's Awesome FFmpeg Tutotial. All rights reserved.
//

@import MetalKit;
#import "FSMetalShaderTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface FSMetalRenderer : NSObject

@property (nonatomic, assign) float rotateDegrees;
@property (nonatomic, assign) int rotateType;//x:1,y:2,z:3
@property (nonatomic, assign) float autoZRotateDegrees;
@property (nonatomic, assign) CGSize vertexRatio;
@property (nonatomic, assign) CGSize textureCrop;
// When YES, output linear light values for an EDR/HDR display instead of tone-mapping to SDR.
// Only has effect when the content is HDR (isHDR == YES).
@property (nonatomic, assign) BOOL hdrDisplay;

- (BOOL)isHDRContent;
- (instancetype)initWithDevice:(id<MTLDevice>)device
              colorPixelFormat:(MTLPixelFormat)colorPixelFormat;

- (BOOL)matchPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)updateColorAdjustment:(vector_float4)c;

- (BOOL)createRenderPipelineIfNeed:(CVPixelBufferRef)pixelBuffer blend:(BOOL)blend;
- (void)uploadTextureWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                        textures:(NSArray*)textures;
@end

NS_ASSUME_NONNULL_END
