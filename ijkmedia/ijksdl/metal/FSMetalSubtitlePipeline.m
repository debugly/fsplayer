//
//  FSMetalSubtitlePipeline.m
//  FSPlayer
//
//  Created by debugly on 2022/12/23.
//

#import "FSMetalSubtitlePipeline.h"
#import "FSMathUtilities.h"
#import "FSMetalShaderTypes.h"

@interface FSMetalSubtitlePipeline()
{
    id<MTLDevice> _device;
    FSMetalSubtitleOutFormat _outFormat;
    FSMetalSubtitleInFormat _inFormat;
}

// The render pipeline generated from the vertex and fragment shaders in the .metal shader file.
@property (nonatomic, strong) id<MTLRenderPipelineState> renderPipeline;
@property (nonatomic, strong) id<MTLBuffer> vertices;
@property (nonatomic, strong) id<MTLBuffer> mvp;
@property (nonatomic, assign) CGRect lastRect;

@end

@implementation FSMetalSubtitlePipeline

- (instancetype)initWithDevice:(id<MTLDevice>)device
                     inFormat:(FSMetalSubtitleInFormat)inFormat
                     outFormat:(FSMetalSubtitleOutFormat)outFormat
{
    self = [super init];
    if (self) {
        NSAssert(device, @"device can't be nil!");
        _device = device;
        _inFormat = inFormat;
        _outFormat = outFormat;
    }
    return self;
}

- (BOOL)createRenderPipelineIfNeed
{
    if (self.renderPipeline) {
        return YES;
    }
    
    NSBundle* bundle = [NSBundle bundleForClass:[self class]];
    NSURL * libURL = [bundle URLForResource:@"default" withExtension:@"metallib"];
    
    NSError *error;
    
    id<MTLLibrary> defaultLibrary = [_device newLibraryWithURL:libURL error:&error];
    
    NSParameterAssert(defaultLibrary);
    // Load all the shader files with a .metal file extension in the project.
    //id<MTLLibrary> defaultLibrary = [device newDefaultLibrary];
    id<MTLFunction> vertexFunction = [defaultLibrary newFunctionWithName:@"subVertexShader"];
    NSAssert(vertexFunction, @"can't find subVertexShader Function!");
    NSString *fsh = nil;
    if (_inFormat == FSMetalSubtitleInFormatBRGA) {
        if (_outFormat == FSMetalSubtitleOutFormatDIRECT) {
            fsh = @"subtileDIRECTFragment";
        } else if (_outFormat == FSMetalSubtitleOutFormatSWAP_RB) {
            fsh = @"subtileSWAPRGFragment";
        } else {
            NSAssert(fsh, @"FSMetalSubtitleOutFormat is wrong!");
        }
    } else if (_inFormat == FSMetalSubtitleInFormatA8) {
        fsh = @"subtilePaletteA8Fragment";
    } else {
        NSAssert(fsh, @"FSMetalSubtitle OutFormat or InFormat is wrong!");
    }
    
    id<MTLFunction> fragmentFunction = [defaultLibrary newFunctionWithName:fsh];
    NSAssert(vertexFunction, @"can't find subtileRGBAFragment Function!");
    
    // Configure a pipeline descriptor that is used to create a pipeline state.
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineStateDescriptor.vertexFunction = vertexFunction;
    pipelineStateDescriptor.fragmentFunction = fragmentFunction;
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    
    //important! set subtitle need blending.
    //https://developer.apple.com/documentation/metal/mtlblendfactor/oneminussourcealpha
    pipelineStateDescriptor.colorAttachments[0].blendingEnabled = YES;
    MTLBlendFactor bfactor = _inFormat == FSMetalSubtitleInFormatA8 ? MTLBlendFactorSourceAlpha : MTLBlendFactorOne;
    bfactor = MTLBlendFactorOne;
    //ass字幕已经做了预乘，所以这里选择 MTLBlendFactorOne，而不是 MTLBlendFactorSourceAlpha
    pipelineStateDescriptor.colorAttachments[0].sourceRGBBlendFactor = bfactor;
    pipelineStateDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pipelineStateDescriptor.colorAttachments[0].sourceAlphaBlendFactor = bfactor;
    pipelineStateDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    
    id<MTLRenderPipelineState> pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor
                                                                                      error:&error]; // 创建图形渲染管道，耗性能操作不宜频繁调用
    // Pipeline State creation could fail if the pipeline descriptor isn't set up properly.
    //  If the Metal API validation is enabled, you can find out more information about what
    //  went wrong.  (Metal API validation is enabled by default when a debug build is run
    //  from Xcode.)
    NSAssert(pipelineState, @"Failed to create pipeline state: %@", error);
    self.renderPipeline = pipelineState;
    return YES;
}

- (void)updateSubtitleVertexIfNeed:(CGRect)rect
{
    if (CGRectEqualToRect(self.lastRect, rect)) {
        return;
    }
    
    self.lastRect = rect;
    
    float x = rect.origin.x;
    float y = rect.origin.y;
    float w = rect.size.width;
    float h = rect.size.height;
    /*
     triangle strip
       ^+
     V3|V4
     --|--->+
     V1|V2
     -->V1V2V3
     -->V2V3V4
     */

    FSVertex quadVertices[4] =
    {   //顶点坐标；          纹理坐标；
        { { x,     y },     { 0.f, 1.f } },
        { { x + w, y },     { 1.f, 1.f } },
        { { x, y + h },     { 0.f, 0.f } },
        { { x + w, y + h }, { 1.f, 0.f } },
    };
    
    self.vertices = [_device newBufferWithBytes:quadVertices
                                         length:sizeof(quadVertices)
                                        options:MTLResourceStorageModeShared]; // 创建顶点缓存
}

- (void)drawTexture:(id)subTexture encoder:(id<MTLRenderCommandEncoder>)encoder
{
    [encoder setFragmentTexture:subTexture atIndex:FSFragmentTextureIndexTextureY];

    // Pass in the parameter data.
    [encoder setVertexBuffer:self.vertices
                      offset:0
                     atIndex:FSVertexInputIndexVertices];
 
    // 设置渲染管道，以保证顶点和片元两个shader会被调用
    [encoder setRenderPipelineState:self.renderPipeline];
    
    // Draw the triangle.
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4]; // 绘制
}

- (void)drawTexture:(id<MTLTexture>)subTexture encoder:(id<MTLRenderCommandEncoder>)encoder colors:(nonnull void *)colors
{
    if (colors) {
        struct SubtitlePaletteFragmentData data = {0};
        data.w = (uint32_t)subTexture.width;
        data.h = (uint32_t)subTexture.height;
        memcpy(data.colors, colors, sizeof(uint32_t) * 256);
        
        id <MTLBuffer>buffer = [_device newBufferWithBytes:&data
                                                    length:sizeof(data)
                                                   options:MTLResourceStorageModeShared];
        buffer.label = @"colors";
        [encoder setFragmentBuffer:buffer
                            offset:0
                           atIndex:1];
    }
    
    [self drawTexture:subTexture encoder:encoder];
}

@end

