//
//  FSMetalView.m
//  FFmpegTutorial-macOS
//
//  Created by debugly on 2022/11/22.
//  Copyright © 2022 debugly's Awesome FFmpeg Tutotial. All rights reserved.
//

#import "FSMetalView.h"
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVUtilities.h>
#import <CoreImage/CIContext.h>
#import <mach/mach_time.h>

// Header shared between C code here, which executes Metal API commands, and .metal files, which
// uses these types as inputs to the shaders.
#import "FSMetalShaderTypes.h"
#import "FSMetalRenderer.h"
#import "FSMetalSubtitlePipeline.h"
#import "FSMetalOffscreenRendering.h"

#import "ijksdl_vout_ios_gles2.h"
#import "FSMediaPlayback.h"

#if TARGET_OS_IPHONE
typedef CGRect NSRect;
#endif

@interface FSMetalView ()

// The command queue used to pass commands to the device.
@property (nonatomic, strong) id<MTLCommandQueue>commandQueue;
@property (nonatomic, assign) CVMetalTextureCacheRef pictureTextureCache;
@property (atomic, strong) FSMetalRenderer *picturePipeline;
@property (atomic, strong) FSMetalSubtitlePipeline *subPipeline;
@property (nonatomic, strong) FSMetalOffscreenRendering *offscreenRendering;
@property (atomic, strong) FSOverlayAttach *currentAttach;
@property (assign) int hdrAnimationFrameCount;
@property (atomic, strong) NSLock *pilelineLock;
@property (assign) BOOL needCleanBackgroundColor;
@property (nonatomic, copy) dispatch_block_t refreshCurrentPicBlock;

@end

@implementation FSMetalView

@synthesize scalingMode = _scalingMode;
// rotate preference
@synthesize rotatePreference = _rotatePreference;
// color conversion preference
@synthesize colorPreference = _colorPreference;
// user defined display aspect ratio
@synthesize darPreference = _darPreference;

@synthesize preventDisplay = _preventDisplay;
#if TARGET_OS_IOS
@synthesize scaleFactor = _scaleFactor;
#endif
@synthesize showHdrAnimation = _showHdrAnimation;

@synthesize displayDelegate = _displayDelegate;

- (void)dealloc
{
    CFRelease(_pictureTextureCache);
}

- (BOOL)prepareMetal
{
    _rotatePreference   = (FSRotatePreference){FSRotateNone, 0.0};
    _colorPreference    = (FSColorConvertPreference){1.0, 1.0, 1.0};
    _darPreference      = (FSDARPreference){0.0};
    _pilelineLock = [[NSLock alloc]init];
    
    self.device = MTLCreateSystemDefaultDevice();
    if (!self.device) {
        NSLog(@"No Support Metal.");
        return NO;
    }
    
    CVReturn ret = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, self.device, NULL, &_pictureTextureCache);
    if (ret != kCVReturnSuccess) {
        NSLog(@"Create MetalTextureCache Failed:%d.",ret);
        self.device = nil;
        return NO;
    }
    // Create the command queue
    self.commandQueue = [self.device newCommandQueue];
    self.autoResizeDrawable = YES;
    // important;then use draw method drive rendering.
    self.enableSetNeedsDisplay = NO;
    self.paused = YES;
    //set default bg color.
    [self setBackgroundColor:0 g:0 b:0];
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        if (![self prepareMetal]) {
            return nil;
        }
    }
    return self;
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        if (![self prepareMetal]) {
            return nil;
        }
    }
    return self;
}

- (void)setShowHdrAnimation:(BOOL)showHdrAnimation
{
    if (_showHdrAnimation != showHdrAnimation) {
        _showHdrAnimation = showHdrAnimation;
        self.hdrAnimationFrameCount = 0;
    }
}

- (CGSize)computeNormalizedVerticesRatio:(FSOverlayAttach *)attach drawableSize:(CGSize)drawableSize
{
    if (_scalingMode == FSScalingModeFill) {
        return CGSizeMake(1.0, 1.0);
    }
    
    int frameWidth = attach.w;
    int frameHeight = attach.h;
    
    //keep video AVRational
    if (attach.sarNum > 0 && attach.sarDen > 0) {
        frameWidth = 1.0 * attach.sarNum / attach.sarDen * frameWidth;
    }
    
    int zDegrees = 0;
    if (_rotatePreference.type == FSRotateZ) {
        zDegrees += _rotatePreference.degrees;
    }
    zDegrees += attach.autoZRotate;
    
    float darRatio = self.darPreference.ratio;
    
    //when video's z rotate degrees is 90 odd multiple
    if (abs(zDegrees) / 90 % 2 == 1) {
        //need swap user's ratio
        if (darRatio > 0.001) {
            darRatio = 1.0 / darRatio;
        }
        //need swap display size
        int tmp = drawableSize.width;
        drawableSize.width = drawableSize.height;
        drawableSize.height = tmp;
    }
    
    //apply user dar
    if (darRatio > 0.001) {
        if (1.0 * attach.w / attach.h > darRatio) {
            frameHeight = frameWidth * 1.0 / darRatio;
        } else {
            frameWidth = frameHeight * darRatio;
        }
    }
    
    float wRatio = drawableSize.width / frameWidth;
    float hRatio = drawableSize.height / frameHeight;
    float ratio  = 1.0f;
    
    if (_scalingMode == FSScalingModeAspectFit) {
        ratio = FFMIN(wRatio, hRatio);
    } else if (_scalingMode == FSScalingModeAspectFill) {
        ratio = FFMAX(wRatio, hRatio);
    }
    float nW = (frameWidth * ratio / drawableSize.width);
    float nH = (frameHeight * ratio / drawableSize.height);
    return CGSizeMake(nW, nH);
}

- (BOOL)setupSubPipelineIfNeed
{
    if (self.subPipeline) {
        return YES;
    }
    
    FSMetalSubtitlePipeline *subPipeline = [[FSMetalSubtitlePipeline alloc] initWithDevice:self.device inFormat:FSMetalSubtitleInFormatBRGA outFormat:FSMetalSubtitleOutFormatDIRECT];
    
    BOOL created = [subPipeline createRenderPipelineIfNeed];
    
    if (!created) {
        ALOGE("create subRenderPipeline failed.");
        subPipeline = nil;
    }
    
    [self.pilelineLock lock];
    self.subPipeline = subPipeline;
    [self.pilelineLock unlock];
    
    return subPipeline != nil;
}

- (BOOL)setupPipelineIfNeed:(CVPixelBufferRef)pixelBuffer
{
    if (!pixelBuffer) {
        return NO;
    }
    
    if (self.picturePipeline) {
        if ([self.picturePipeline matchPixelBuffer:pixelBuffer]) {
            return YES;
        }
        ALOGI("pixel format not match,need rebuild pipeline");
    }
    
    FSMetalRenderer *picturePipeline = [[FSMetalRenderer alloc] initWithDevice:self.device colorPixelFormat:self.colorPixelFormat];
    BOOL created = [picturePipeline createRenderPipelineIfNeed:pixelBuffer];
    
    if (!created) {
        ALOGI("create RenderPipeline failed.");
        picturePipeline = nil;
    }
    
    [self.pilelineLock lock];
    self.picturePipeline = picturePipeline;
    [self.pilelineLock unlock];
    
    return picturePipeline != nil;
}

- (void)encodePicture:(FSOverlayAttach *)attach
        renderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder
             viewport:(CGSize)viewport
                ratio:(CGSize)ratio
        hdrPercentage:(float)hdrPercentage
{
    [self.pilelineLock lock];
    self.picturePipeline.hdrPercentage = hdrPercentage;
    self.picturePipeline.autoZRotateDegrees = attach.autoZRotate;
    self.picturePipeline.rotateType = self.rotatePreference.type;
    self.picturePipeline.rotateDegrees = self.rotatePreference.degrees;
    
    bool applyAdjust = _colorPreference.brightness != 1.0 || _colorPreference.saturation != 1.0 || _colorPreference.contrast != 1.0;
    [self.picturePipeline updateColorAdjustment:(vector_float4){_colorPreference.brightness,_colorPreference.saturation,_colorPreference.contrast,applyAdjust ? 1.0 : 0.0}];
    self.picturePipeline.vertexRatio = ratio;
    
    self.picturePipeline.textureCrop = CGSizeMake(1.0 * (attach.pixelW - attach.w) / attach.pixelW, 1.0 * (attach.pixelH - attach.h) / attach.pixelH);
    
    // Set the region of the drawable to draw into.
    [renderEncoder setViewport:(MTLViewport){0.0, 0.0, viewport.width, viewport.height, -1.0, 1.0}];
    //upload textures
    [self.picturePipeline uploadTextureWithEncoder:renderEncoder
                                          textures:attach.videoTextures];
    [self.pilelineLock unlock];
}

- (void)encodeSubtitle:(id<MTLRenderCommandEncoder>)renderEncoder
              viewport:(CGSize)viewport
               texture:(id<MTLTexture>)subTexture
{
    [self.pilelineLock lock];
    // Set the region of the drawable to draw into.
    [renderEncoder setViewport:(MTLViewport){0.0, 0.0, viewport.width, viewport.height, -1.0, 1.0}];
    //upload textures
    
    float wRatio = viewport.width / subTexture.width;
    float hRatio = viewport.height / subTexture.height;
    
    CGRect subRect;
    //aspect fit
    if (wRatio < hRatio) {
        float nH = (subTexture.height * wRatio / viewport.height);
        subRect = CGRectMake(-1, -nH, 2.0, 2.0 * nH);
    } else {
        float nW = (subTexture.width * hRatio / viewport.width);
        subRect = CGRectMake(-nW, -1, 2.0 * nW, 2.0);
    }
    
    [self.subPipeline updateSubtitleVertexIfNeed:subRect];
    [self.subPipeline drawTexture:subTexture encoder:renderEncoder];
    [self.pilelineLock unlock];
}

- (void)sendHDRAnimationNotifiOnMainThread:(int)state
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FSPlayerHDRAnimationStateChanged object:self userInfo:@{@"state":@(state)}];
    });
}

/// Called whenever the view needs to render a frame.
- (void)drawRect:(NSRect)dirtyRect
{
    FSOverlayAttach * attach = self.currentAttach;
    if (attach.videoTextures.count == 0) {
        if (self.needCleanBackgroundColor) {
            id<CAMetalDrawable> drawable = self.currentDrawable;
            if (drawable) {
                id<MTLTexture> texture = drawable.texture;

                MTLRenderPassDescriptor *passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
                passDescriptor.colorAttachments[0].texture = texture;
                passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
                passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
                passDescriptor.colorAttachments[0].clearColor = self.clearColor;
                
                id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
                id <MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
            
                [commandEncoder endEncoding];
                [commandBuffer presentDrawable:drawable];
                [commandBuffer commit];
                self.needCleanBackgroundColor = NO;
            }
        }
        return;
    }
    
    if (![self setupPipelineIfNeed:attach.videoPicture]) {
        return;
    }
    
    if (attach.subTexture && ![self setupSubPipelineIfNeed]) {
        return;
    }
    CGSize viewport = self.drawableSize;
    
    CGSize ratio = [self computeNormalizedVerticesRatio:attach drawableSize:viewport];
    
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    
    // Obtain a renderPassDescriptor generated from the view's drawable textures.
    MTLRenderPassDescriptor *renderPassDescriptor = self.currentRenderPassDescriptor;
    //MTLRenderPassDescriptor描述一系列attachments的值，类似GL的FrameBuffer；同时也用来创建MTLRenderCommandEncoder
    if(!renderPassDescriptor) {
        ALOGE("renderPassDescriptor can't be nil");
        return;
    }
    // Create a render command encoder.
    id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    
    //[renderEncoder pushDebugGroup:@"encodePicture"];
    
    float hdrPer = 1.0;
    if (self.showHdrAnimation && [self.picturePipeline isHDR]) {
#define _C(c) (attach.fps > 0 ? (int)ceil(attach.fps * c / 24.0) : c)
        int delay = _C(100);
        int maxCount = _C(100);
#undef _C
        int frameCount = ++self.hdrAnimationFrameCount - delay;
        if (frameCount >= 0) {
            if (frameCount <= maxCount) {
                if (frameCount == 0) {
                    [self sendHDRAnimationNotifiOnMainThread:1];
                } else if (frameCount == maxCount) {
                    [self sendHDRAnimationNotifiOnMainThread:2];
                }
                hdrPer = 0.5 + 0.5 * frameCount / maxCount;
            }
        } else {
            hdrPer = 0.5;
        }
    }
    
    [self encodePicture:attach
          renderEncoder:renderEncoder
               viewport:viewport
                  ratio:ratio
          hdrPercentage:hdrPer];
    
    if (attach.subTexture) {
        [self encodeSubtitle:renderEncoder
                    viewport:viewport
                     texture:attach.subTexture];
    }
    //[renderEncoder popDebugGroup];
    [renderEncoder endEncoding];
    // Schedule a present once the framebuffer is complete using the current drawable.
    id <CAMetalDrawable> currentDrawable = self.currentDrawable;
    if (!currentDrawable) {
        ALOGE("wtf?currentDrawable is nil!");
        return;
    }
    [commandBuffer presentDrawable:currentDrawable];
    // Finalize rendering here & push the command buffer to the GPU.
    [commandBuffer commit];
}

- (CGImageRef)_snapshotWithSubtitle:(BOOL)drawSub
{
    FSOverlayAttach *attach = self.currentAttach;
    
    CVPixelBufferRef pixelBuffer = attach.videoPicture;
    if (!pixelBuffer) {
        return NULL;
    }
    
    if (!self.offscreenRendering) {
        self.offscreenRendering = [FSMetalOffscreenRendering alloc];
    }
    
    float width  = (float)CVPixelBufferGetWidth(pixelBuffer);
    float height = (float)CVPixelBufferGetHeight(pixelBuffer);
    
    //keep video AVRational
    if (attach.sarNum > 0 && attach.sarDen > 0) {
        width = 1.0 * attach.sarNum / attach.sarDen * width;
    }
    
    float darRatio = self.darPreference.ratio;
    
    int zDegrees = 0;
    if (_rotatePreference.type == FSRotateZ) {
        zDegrees += _rotatePreference.degrees;
    }
    zDegrees += attach.autoZRotate;
    //when video's z rotate degrees is 90 odd multiple
    if (abs(zDegrees) / 90 % 2 == 1) {
        int tmp = width;
        width = height;
        height = tmp;
    }
    
    //apply user dar
    if (darRatio > 0.001) {
        if (1.0 * width / height > darRatio) {
            height = width * 1.0 / darRatio;
        } else {
            width = height * darRatio;
        }
    }
    
    CGSize viewport = CGSizeMake(floorf(width), floorf(height));
    
    if (![self setupPipelineIfNeed:attach.videoPicture]) {
        return NULL;
    }
    
    if (drawSub && attach.subTexture && ![self setupSubPipelineIfNeed]) {
        return NULL;
    }
    
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    return [self.offscreenRendering snapshot:viewport device:self.device commandBuffer:commandBuffer doUploadPicture:^(id<MTLRenderCommandEncoder> _Nonnull renderEncoder) {
        
        [self encodePicture:attach
              renderEncoder:renderEncoder
                   viewport:viewport
                      ratio:CGSizeMake(1.0, 1.0)
              hdrPercentage:1.0];
        
        if (drawSub && attach.subTexture) {
            [self encodeSubtitle:renderEncoder
                        viewport:viewport
                         texture:attach.subTexture];
        }
    }];
}

- (CGImageRef)_snapshotOrigin:(FSOverlayAttach *)attach
{
    CVPixelBufferRef pixelBuffer = CVPixelBufferRetain(attach.videoPicture);
    //[CIImage initWithCVPixelBuffer:options:] failed because its pixel format f420 is not supported.
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (!ciImage) {
        return NULL;
    }
    static CIContext *context = nil;
    if (!context) {
        context = [CIContext contextWithOptions:NULL];
    }
    CGRect rect = CGRectMake(0,0,
                             CVPixelBufferGetWidth(pixelBuffer),
                             CVPixelBufferGetHeight(pixelBuffer));
    CGImageRef imageRef = [context createCGImage:ciImage fromRect:rect];
    CVPixelBufferRelease(pixelBuffer);
    return imageRef ? (CGImageRef)CFAutorelease(imageRef) : NULL;
}

- (CGImageRef)_snapshotScreen
{
    FSOverlayAttach *attach = self.currentAttach;
    
    CVPixelBufferRef pixelBuffer = attach.videoPicture;
    if (!pixelBuffer) {
        return NULL;
    }
    
    if (!self.offscreenRendering) {
        self.offscreenRendering = [FSMetalOffscreenRendering alloc];
    }
    
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
   
    if (![self setupPipelineIfNeed:attach.videoPicture]) {
        return NULL;
    }
    
    if (attach.subTexture && ![self setupSubPipelineIfNeed]) {
        return NULL;
    }
    
    CGSize viewport = self.drawableSize;
    return [self.offscreenRendering snapshot:viewport device:self.device commandBuffer:commandBuffer doUploadPicture:^(id<MTLRenderCommandEncoder> _Nonnull renderEncoder) {
        CVPixelBufferRef pixelBuffer = attach.videoPicture;
        if (pixelBuffer) {
            CGSize ratio = [self computeNormalizedVerticesRatio:attach drawableSize:viewport];
            [self encodePicture:attach
                  renderEncoder:renderEncoder
                       viewport:viewport
                          ratio:ratio
                  hdrPercentage:1.0];
        }
        
        if (attach.subTexture) {
            [self encodeSubtitle:renderEncoder
                        viewport:viewport
                         texture:attach.subTexture];
        }
    }];
}

- (CGImageRef)snapshot:(FSSnapshotType)aType
{
    switch (aType) {
        case FSSnapshotTypeOrigin:
            return [self _snapshotOrigin:self.currentAttach];
        case FSSnapshotTypeScreen:
            return [self _snapshotScreen];
        case FSSnapshotTypeEffect_Origin:
            return [self _snapshotWithSubtitle:NO];
        case FSSnapshotTypeEffect_Subtitle_Origin:
            return [self _snapshotWithSubtitle:YES];
    }
}

#if TARGET_OS_IOS || TARGET_OS_TV
- (UIImage *)snapshot
{
    CGImageRef cgImg = [self snapshot:FSSnapshotTypeScreen];
    return [[UIImage alloc]initWithCGImage:cgImg];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    
    if (!CGSizeEqualToSize(self.drawableSize, self.preferredDrawableSize)) {
        [self setNeedsRefreshCurrentPic];
    }
}

#else

- (void)resizeWithOldSuperviewSize:(NSSize)oldSize
{
    [super resizeWithOldSuperviewSize:oldSize];
    [self setNeedsRefreshCurrentPic];
}

#endif

- (void)setNeedsRefreshCurrentPic
{
    if (self.refreshCurrentPicBlock) {
        self.refreshCurrentPicBlock();
    } else {
        [self draw];
    }
}

mp_format * mp_get_metal_format(uint32_t cvpixfmt);

+ (NSArray<id<MTLTexture>> *)doGenerateTexture:(CVPixelBufferRef)pixelBuffer
                                  textureCache:(CVMetalTextureCacheRef)textureCache
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
        CVMetalTextureRef textureRef = NULL; // CoreVideo的Metal纹理
        CVReturn status = CVMetalTextureCacheCreateTextureFromImage(NULL, textureCache, pixelBuffer, NULL, format, width, height, i, &textureRef);
        if (status == kCVReturnSuccess) {
            id<MTLTexture> texture = CVMetalTextureGetTexture(textureRef); // 转成Metal用的纹理
            if (texture != nil) {
                [result addObject:texture];
            }
            CFRelease(textureRef);
        }
    }
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    return result;
}

- (void)registerRefreshCurrentPicObserver:(dispatch_block_t)block
{
    self.refreshCurrentPicBlock = block;
}

- (BOOL)displayAttach:(FSOverlayAttach *)attach
{
    //hold the attach as current.
    self.currentAttach = attach;
    
    if (!attach.videoPicture) {
        ALOGW("FSMetalView: videoPicture is nil\n");
        return NO;
    }
    
    attach.videoTextures = [[self class] doGenerateTexture:attach.videoPicture textureCache:_pictureTextureCache];
    
    if (self.preventDisplay) {
        return YES;
    }
    
    if (CGSizeEqualToSize(CGSizeZero, self.drawableSize)) {
        return NO;
    }
    
    //not dispatch to main thread, use current sub thread (ff_vout) draw
    [self draw];
    
    if (self.displayDelegate) {
        [self.displayDelegate videoRenderingDidDisplay:self attach:attach];
    }
    
    return YES;
}

#pragma mark - override setter methods

- (void)setScalingMode:(FSScalingMode)scalingMode
{
    if (_scalingMode != scalingMode) {
        _scalingMode = scalingMode;
    }
}

- (void)setRotatePreference:(FSRotatePreference)rotatePreference
{
    if (_rotatePreference.type != rotatePreference.type || _rotatePreference.degrees != rotatePreference.degrees) {
        _rotatePreference = rotatePreference;
    }
}

- (void)setColorPreference:(FSColorConvertPreference)colorPreference
{
    if (_colorPreference.brightness != colorPreference.brightness || _colorPreference.saturation != colorPreference.saturation || _colorPreference.contrast != colorPreference.contrast) {
        _colorPreference = colorPreference;
    }
}

- (void)setDarPreference:(FSDARPreference)darPreference
{
    if (_darPreference.ratio != darPreference.ratio) {
        _darPreference = darPreference;
    }
}

- (void)setBackgroundColor:(uint8_t)r g:(uint8_t)g b:(uint8_t)b
{
    self.clearColor = (MTLClearColor){r/255.0, g/255.0, b/255.0, 1.0f};
    self.needCleanBackgroundColor = YES;
    [self setNeedsRefreshCurrentPic];
}

- (id)context
{
    return self.device;
}

- (NSString *)name
{
    return @"Metal";
}

#if TARGET_OS_OSX
- (NSView *)hitTest:(NSPoint)point
{
    for (NSView *sub in [self subviews]) {
        NSPoint pointInSelf = [self convertPoint:point fromView:self.superview];
        NSPoint pointInSub = [self convertPoint:pointInSelf toView:sub];
        if (NSPointInRect(pointInSub, sub.bounds)) {
            return sub;
        }
    }
    return nil;
}

- (BOOL)acceptsFirstResponder
{
    return NO;
}

- (BOOL)mouseDownCanMoveWindow
{
    return YES;
}
#else
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    return NO;
}
#endif

@end
