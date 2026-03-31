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

#if TARGET_OS_OSX
#import <CoreVideo/CVDisplayLink.h>
#else
#import <QuartzCore/QuartzCore.h>
typedef CGRect NSRect;
#endif

@interface FSMetalView ()

// The command queue used to pass commands to the device.
@property (nonatomic, strong) id<MTLCommandQueue>commandQueue;
#if TARGET_CPU_ARM64
@property (nonatomic, assign) CVMetalTextureCacheRef pictureTextureCache;
#endif
@property (atomic, strong) FSMetalRenderer *picturePipeline;
@property (atomic, strong) FSMetalSubtitlePipeline *subPipeline;
@property (nonatomic, strong) FSMetalOffscreenRendering *offscreenRendering;
@property (atomic, strong) FSOverlayAttach *currentAttach;
@property (nonatomic, strong) FSOverlayAttach *drawingAttach;
@property (assign) int hdrAnimationFrameCount;
@property (atomic, strong) NSLock *renderSnapshotLock;
@property (assign) BOOL needCleanBackgroundColor;
@property (nonatomic, copy) dispatch_block_t refreshCurrentPicBlock;
#if TARGET_OS_IOS || TARGET_OS_TV
@property (atomic, assign) BOOL isEnterBackground;
#endif
#if TARGET_OS_OSX
@property (nonatomic, assign) CVDisplayLinkRef displayLink;
#else
@property (nonatomic, strong) CADisplayLink *displayLink;
#endif
@property (nonatomic, assign) CFTimeInterval presentationTime;
@property (atomic, assign) long previousTag;
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
    [[NSNotificationCenter defaultCenter] removeObserver:self];
#if TARGET_CPU_ARM64
    if (_pictureTextureCache) {
        CFRelease(_pictureTextureCache);
        _pictureTextureCache = NULL;
    }
#endif
#if TARGET_OS_OSX
    if (_displayLink) {
        CVDisplayLinkStop(_displayLink);
        CVDisplayLinkRelease(_displayLink);
        _displayLink = NULL;
    }
#else
    if (_displayLink) {
        [_displayLink invalidate];
        _displayLink = nil;
    }
#endif
}

#if TARGET_OS_OSX
// ----------------------------------------------------------------
// 核心回调：由系统高优先级线程触发（通常是 60Hz 或 120Hz）
// ----------------------------------------------------------------
static CVReturn MyDisplayLinkCallback(CVDisplayLinkRef displayLink,
                                      const CVTimeStamp *inNow,
                                      const CVTimeStamp *inOutputTime,
                                      CVOptionFlags flagsIn,
                                      CVOptionFlags *flagsOut,
                                      void *displayLinkContext) {
    
    FSMetalView *renderer = (__bridge FSMetalView *)displayLinkContext;
    CFTimeInterval timestamp = inOutputTime->hostTime * 1e-9;
    // 执行同步刷新逻辑
    [renderer displayAttachWithTimestamp:timestamp];
    
    return kCVReturnSuccess;
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if (self.window) {
        NSNumber * screenNumber = [[self.window screen] deviceDescription][@"NSScreenNumber"];
        if (screenNumber && _displayLink) {
            CGDirectDisplayID displayID = (CGDirectDisplayID)[screenNumber unsignedIntValue];
            CVDisplayLinkSetCurrentCGDisplay(_displayLink, displayID);
        }
    }
}

- (void)setupDisplayLink {
    // 1. 创建基于当前活跃显示器的 DisplayLink
    CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
    
    // 2. 设置回调
    CVDisplayLinkSetOutputCallback(_displayLink, MyDisplayLinkCallback, (__bridge void *)self);
    
    // 3. 关联到主显示器（初始状态）
    CGDirectDisplayID displayID = CGMainDisplayID();
    CVDisplayLinkSetCurrentCGDisplay(_displayLink, displayID);
    
    // 4. 启动渲染循环
    CVDisplayLinkStart(_displayLink);
}

// ----------------------------------------------------------------
// 多显示器支持：当窗口拖动到外接显示器时，刷新率可能改变
// ----------------------------------------------------------------
- (void)registerScreenNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowDidChangeScreen:)
                                                 name:NSWindowDidChangeScreenNotification
                                               object:nil];
}

- (void)windowDidChangeScreen:(NSNotification *)notification {
    NSWindow *window = notification.object;
    NSNumber *screenNumber = [[window screen] deviceDescription][@"NSScreenNumber"];
    if (screenNumber && _displayLink) {
        CGDirectDisplayID displayID = (CGDirectDisplayID)[screenNumber unsignedIntValue];
        CVDisplayLinkSetCurrentCGDisplay(_displayLink, displayID);
    }
}
#else

- (void)setupDisplayLink {
    if (_displayLink) {
        return;
    }
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkFired:)];
    if (@available(iOS 15.0,tvOS 15.0, *)) {
        _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(1, 60, 30);
    } else {
        _displayLink.preferredFramesPerSecond = 30;
    }
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)displayLinkFired:(CADisplayLink *)displayLink {
    [self displayAttachWithTimestamp:displayLink.targetTimestamp];
}

#endif
- (void)displayAttachWithTimestamp:(const CFTimeInterval)timestamp {
    [self.renderSnapshotLock lock];
    FSOverlayAttach *currentAttach = self.currentAttach;

    if (currentAttach.tag == self.previousTag) {
        [self.renderSnapshotLock unlock];
        return;
    }
    
    [self.renderSnapshotLock unlock];
    self.presentationTime = timestamp;
    self.drawingAttach = currentAttach;
    //use current DisplayLink thread
    [self draw];
}

- (BOOL)prepareMetal
{
    _rotatePreference   = (FSRotatePreference){FSRotateNone, 0.0};
    _colorPreference    = (FSColorConvertPreference){1.0, 1.0, 1.0};
    _darPreference      = (FSDARPreference){0.0};
    _renderSnapshotLock = [[NSLock alloc]init];
    
    [self setupDisplayLink];
    
    self.device = MTLCreateSystemDefaultDevice();
    if (!self.device) {
        ALOGE("Can't Create Metal Device.");
        return NO;
    }
#if TARGET_CPU_ARM64
    CVReturn ret = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, self.device, NULL, &_pictureTextureCache);
    if (ret != kCVReturnSuccess) {
        ALOGE("Create MetalTextureCache Failed:%d.",ret);
        self.device = nil;
        return NO;
    }
#endif
    // default is kCAGravityResize,the content will be filled to new bounds when change view's frame by Implicit Animation
#if TARGET_OS_OSX
    //#76 设置了 kCAGravityCenter 之后发现 macOS 外接1倍屏会出现画面显示到中央，无法填充满的问题，Retina屏幕没有问题
    //self.layer.contentsGravity = kCAGravityCenter;
#else
    self.contentMode = UIViewContentModeCenter;
#endif
    
    // Create the command queue
    self.commandQueue = [self.device newCommandQueue];
    self.autoResizeDrawable = YES;
    // important;then use draw method drive rendering.
    self.enableSetNeedsDisplay = NO;
    self.paused = YES;
    //set default bg color.
    [self setBackgroundColor:0 g:0 b:0];
    
#if TARGET_OS_IOS || TARGET_OS_TV
    self.isEnterBackground = UIApplication.sharedApplication.applicationState == UIApplicationStateBackground;
    
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(applicationDidEnterBackground)
                                               name:UIApplicationDidEnterBackgroundNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(applicationWillEnterForeground)
                                               name:UIApplicationWillEnterForegroundNotification
                                             object:nil];
#endif
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        [self prepareMetal];
    }
    return self;
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        [self prepareMetal];
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
    
    self.subPipeline = subPipeline;
    
    return subPipeline != nil;
}

- (BOOL)setupPipelineIfNeed:(CVPixelBufferRef)pixelBuffer blend:(BOOL)blend
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
    BOOL created = [picturePipeline createRenderPipelineIfNeed:pixelBuffer blend:blend];
    
    if (!created) {
        ALOGE("create RenderPipeline failed.");
        picturePipeline = nil;
    }
    
    self.picturePipeline = picturePipeline;
    
    return picturePipeline != nil;
}

- (void)encodePicture:(FSOverlayAttach *)attach
        renderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder
             viewport:(CGSize)viewport
                ratio:(CGSize)ratio
        hdrPercentage:(float)hdrPercentage
{
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
}

- (void)encodeSubtitle:(id<MTLRenderCommandEncoder>)renderEncoder
              viewport:(CGSize)viewport
               texture:(id<MTLTexture>)subTexture
{
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
}

- (void)sendHDRAnimationNotifiOnMainThread:(int)state
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FSPlayerHDRAnimationStateChanged object:self userInfo:@{@"state":@(state)}];
    });
}

// [self draw] drived
- (void)drawRect:(NSRect)dirtyRect
{
#if TARGET_OS_IOS || TARGET_OS_TV
    if (self.isEnterBackground) {
        return;
    }
#endif
    
    id<CAMetalDrawable> drawable = self.currentDrawable;
    // 拿不到 Drawable 直接放弃这一帧，不要强行 commit
    if (!drawable) {
        return;
    }
    
    FSOverlayAttach *currentAttach = self.drawingAttach;
    
    //Clean Background Color
    if (!currentAttach.videoPicture) {
        if (self.needCleanBackgroundColor) {
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
        return;
    }
    
    [self.renderSnapshotLock lock];
    self.drawingAttach = nil;
    
    if (![self setupPipelineIfNeed:currentAttach.videoPicture blend:currentAttach.hasAlpha]) {
        [self.renderSnapshotLock unlock];
        return;
    }
    
    if (currentAttach.subTexture && ![self setupSubPipelineIfNeed]) {
        [self.renderSnapshotLock unlock];
        return;
    }
    
    //generate textures
    if (!currentAttach.videoTextures) {
        CVMetalTextureCacheRef textureCache = NULL;
    #if TARGET_CPU_ARM64
        textureCache = _pictureTextureCache;
    #endif
        currentAttach.videoTextures = [[self class] doGenerateTexture:currentAttach.videoPicture textureCache:textureCache device:self.device];
    }
    
    if (self.displayDelegate && [self.displayDelegate respondsToSelector:@selector(videoRenderingDidDisplay:attach:)]) {
        [self.displayDelegate videoRenderingDidDisplay:self attach:currentAttach];
    }
    
    //draw textures
    CGSize viewport = self.drawableSize;
    
    CGSize ratio = [self computeNormalizedVerticesRatio:currentAttach drawableSize:viewport];
    
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    
    // Obtain a renderPassDescriptor generated from the view's drawable textures.
    MTLRenderPassDescriptor *renderPassDescriptor = self.currentRenderPassDescriptor;
    //MTLRenderPassDescriptor描述一系列attachments的值，类似GL的FrameBuffer；同时也用来创建MTLRenderCommandEncoder
    if(!renderPassDescriptor) {
        ALOGE("renderPassDescriptor can't be nil");
        [self.renderSnapshotLock unlock];
        return;
    }
    
    // Create a render command encoder.
    id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    
    //[renderEncoder pushDebugGroup:@"encodePicture"];
    
    float hdrPer = 1.0;
    if (self.showHdrAnimation && [self.picturePipeline isHDR]) {
#define _C(c) (currentAttach.fps > 0 ? (int)ceil(currentAttach.fps * c / 24.0) : c)
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
    
    [self encodePicture:currentAttach
          renderEncoder:renderEncoder
               viewport:viewport
                  ratio:ratio
          hdrPercentage:hdrPer];
    
    if (currentAttach.subTexture) {
        [self encodeSubtitle:renderEncoder
                    viewport:viewport
                     texture:currentAttach.subTexture];
    }
    //[renderEncoder popDebugGroup];
    [renderEncoder endEncoding];
    //[commandBuffer presentDrawable:drawable];
    [commandBuffer presentDrawable:drawable atTime:self.presentationTime];
    // Finalize rendering here & push the command buffer to the GPU.
    [commandBuffer commit];
    self.previousTag = currentAttach.tag;
    
    [self.renderSnapshotLock unlock];
}

- (CGImageRef)_snapshotWithSubtitle:(BOOL)drawSub
{
    [self.renderSnapshotLock lock];
    
    FSOverlayAttach *attach = self.currentAttach;
    
    CVPixelBufferRef pixelBuffer = attach.videoPicture;
    if (!pixelBuffer) {
        [self.renderSnapshotLock unlock];
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
    
    if (![self setupPipelineIfNeed:attach.videoPicture blend:attach.hasAlpha]) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }
    
    if (drawSub && attach.subTexture && ![self setupSubPipelineIfNeed]) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }
    
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    CGImageRef result = [self.offscreenRendering snapshot:viewport device:self.device commandBuffer:commandBuffer doUploadPicture:^(id<MTLRenderCommandEncoder> _Nonnull renderEncoder) {
        
        if (!attach.videoTextures) {
            attach.videoTextures = [[self class] doGenerateTexture:attach.videoPicture textureCache:self.pictureTextureCache device:self.device];
        }
        
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
    [self.renderSnapshotLock unlock];
    return result;
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
    [self.renderSnapshotLock lock];
    
    FSOverlayAttach *attach = self.currentAttach;
    
    CVPixelBufferRef pixelBuffer = attach.videoPicture;
    if (!pixelBuffer) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }
    
    if (!self.offscreenRendering) {
        self.offscreenRendering = [FSMetalOffscreenRendering alloc];
    }
    
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
   
    if (![self setupPipelineIfNeed:attach.videoPicture blend:attach.hasAlpha]) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }
    
    if (attach.subTexture && ![self setupSubPipelineIfNeed]) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }
    
    CGSize viewport = self.drawableSize;
    CGImageRef result = [self.offscreenRendering snapshot:viewport device:self.device commandBuffer:commandBuffer doUploadPicture:^(id<MTLRenderCommandEncoder> _Nonnull renderEncoder) {
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
    [self.renderSnapshotLock unlock];
    return result;
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

- (void)applicationDidEnterBackground {
    self.isEnterBackground = YES;
    if (_displayLink) {
        _displayLink.paused = YES;
    }
}

- (void)applicationWillEnterForeground {
    self.isEnterBackground = NO;
    if (_displayLink) {
        _displayLink.paused = NO;
    }
}

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
#if TARGET_CPU_ARM64
        CVMetalTextureRef textureRef = NULL;
        CVReturn status = CVMetalTextureCacheCreateTextureFromImage(NULL, textureCache, pixelBuffer, NULL, format, width, height, i, &textureRef);
        if (status == kCVReturnSuccess) {
            id<MTLTexture> texture = CVMetalTextureGetTexture(textureRef); // 转成Metal用的纹理
            if (texture != nil) {
                [result addObject:texture];
            }
            CFRelease(textureRef);
        }
#else
        //YUV420P 下面一半显示一层红色条纹，上面一半连续多个绿色方块 (Intel Iris Graphics 6100 1536MB,macOS 10.14,A1502)
        //NV12 的 UV 像素上下拉伸（在shader里采样时乘以2可以和y对上，下半部分不对，数据错乱）(MacBook Pro 13-inch, 2017 Intel Iris Plus Graphics 640 1536 MB,macOS 13.6.1)
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

- (void)registerRefreshCurrentPicObserver:(dispatch_block_t)block
{
    self.refreshCurrentPicBlock = block;
}

- (BOOL)displayAttach:(FSOverlayAttach *)attach
{
    //call form (ff_vout thread)
    
    attach.tag = self.previousTag + 1;
    
    if (self.displayDelegate && attach.videoPicture && [self.displayDelegate respondsToSelector:@selector(videoRenderingWillDisplay:videoFrame:)]) {
        attach.videoPicture = [self.displayDelegate videoRenderingWillDisplay:self videoFrame:attach.videoPicture];
    }
    
    if (!attach.videoPicture) {
        ALOGW("FSMetalView: videoPicture is nil\n");
        return NO;
    }
    
    if (self.preventDisplay) {
        return YES;
    }
    
    [self.renderSnapshotLock lock];
    self.currentAttach = attach;
    [self.renderSnapshotLock unlock];
    
    return YES;
}

#pragma mark - override setter methods

- (void)setScalingMode:(FSScalingMode)scalingMode
{
    if (_scalingMode != scalingMode) {
        _scalingMode = scalingMode;
        [self setNeedsRefreshCurrentPic];
    }
}

- (void)setRotatePreference:(FSRotatePreference)rotatePreference
{
    if (_rotatePreference.type != rotatePreference.type || _rotatePreference.degrees != rotatePreference.degrees) {
        _rotatePreference = rotatePreference;
        [self setNeedsRefreshCurrentPic];
    }
}

- (void)setColorPreference:(FSColorConvertPreference)colorPreference
{
    if (_colorPreference.brightness != colorPreference.brightness || _colorPreference.saturation != colorPreference.saturation || _colorPreference.contrast != colorPreference.contrast) {
        _colorPreference = colorPreference;
        [self setNeedsRefreshCurrentPic];
    }
}

- (void)setDarPreference:(FSDARPreference)darPreference
{
    if (_darPreference.ratio != darPreference.ratio) {
        _darPreference = darPreference;
        [self setNeedsRefreshCurrentPic];
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
    return @"MetalN";
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
