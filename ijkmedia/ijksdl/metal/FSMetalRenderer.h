//
//  FSMetalRenderer.h
//  FFmpegTutorial-macOS
//
//  Created by debugly on 2022/11/23.
//  Copyright © 2022 debugly's Awesome FFmpeg Tutorial. All rights reserved.
//

@import MetalKit;
#import "FSMetalShaderTypes.h"

@class FSMetalPipelineMeta;

NS_ASSUME_NONNULL_BEGIN

@interface FSMetalRenderer : NSObject

@property (nonatomic, assign) float xRotateDegrees;
@property (nonatomic, assign) float yRotateDegrees;
@property (nonatomic, assign) float zRotateDegrees;
@property (nonatomic, assign) float autoZRotateDegrees;
@property (nonatomic, assign) CGSize vertexRatio;
@property (nonatomic, assign) CGSize textureCrop;
// Selects the linear output color space when rendering HDR to an EDR drawable.
@property (nonatomic, assign) FSHDRDisplayMode hdrDisplayMode;

- (instancetype)initWithDevice:(id<MTLDevice>)device
              colorPixelFormat:(MTLPixelFormat)colorPixelFormat;

- (BOOL)matchPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)updateColorAdjustment:(vector_float4)c;

- (BOOL)createRenderPipelineIfNeed:(FSMetalPipelineMeta *)pipelineMeta blend:(BOOL)blend;
- (void)uploadTextureWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                        textures:(NSArray*)textures;
@end

NS_ASSUME_NONNULL_END
