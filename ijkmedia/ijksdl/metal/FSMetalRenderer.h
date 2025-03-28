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
NS_CLASS_AVAILABLE(10_13, 11_0)
@interface FSMetalRenderer : NSObject

@property (nonatomic, assign) float rotateDegrees;
@property (nonatomic, assign) int rotateType;//x:1,y:2,z:3
@property (nonatomic, assign) float autoZRotateDegrees;
@property (nonatomic, assign) CGSize vertexRatio;
@property (nonatomic, assign) CGSize textureCrop;
//非HDR视频设置无效
@property (nonatomic, assign) float hdrPercentage;

- (BOOL)isHDR;
- (instancetype)initWithDevice:(id<MTLDevice>)device
              colorPixelFormat:(MTLPixelFormat)colorPixelFormat;

- (BOOL)matchPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)updateColorAdjustment:(vector_float4)c;

- (BOOL)createRenderPipelineIfNeed:(CVPixelBufferRef)pixelBuffer;
- (void)uploadTextureWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                        textures:(NSArray*)textures;
@end

NS_ASSUME_NONNULL_END
