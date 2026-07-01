//
//  FSMetalView.m
//  FFmpegTutorial-macOS
//
//  Created by debugly on 2022/11/22.
//  Copyright © 2022 debugly's Awesome FFmpeg Tutotial. All rights reserved.
//

#import "FSMetalView.h"
#import <AVFoundation/AVUtilities.h>
#import <CoreImage/CIContext.h>
#import <mach/mach_time.h>

// Header shared between C code here, which executes Metal API commands, and .metal files, which
// uses these types as inputs to the shaders.
#import "FSMetalShaderTypes.h"
#import "FSMetalRenderer.h"
#import "FSMetalSubtitlePipeline.h"
#import "FSMetalOffscreenRendering.h"
#import "FSMetalPipelineMeta.h"
#import "FSMetalBlurFilter.h"
#import "FSMetalTileGridPipeline.h"
#import "ijksdl_vout_ios_gles2.h"
#import "FSMediaPlayback.h"
#import "FSDisplayLinkWrapper.h"
#import "FSMetalTextureUtils.h"

#if TARGET_OS_IOS || TARGET_OS_TV
typedef CGRect NSRect;
#endif

//TARGET_CPU_ARM64
#define USE_METAL_TEXTURE_CACHE 1

@interface FSMetalView ()

// The command queue used to pass commands to the device.
@property (nonatomic, strong) id<MTLCommandQueue>commandQueue;
#if USE_METAL_TEXTURE_CACHE
@property (nonatomic, assign) CVMetalTextureCacheRef pictureTextureCache;
#endif
@property (atomic, strong) FSMetalRenderer *picturePipeline;
// HEIC tile-grid 合成管线：把多个 tile 合成成一张完整画面缓存到 attach。
@property (atomic, strong) FSMetalTileGridPipeline *tileGridPipeline;
@property (atomic, strong) FSMetalSubtitlePipeline *subPipeline;
@property (nonatomic, strong) FSMetalOffscreenRendering *offscreenRendering;
@property (atomic, strong) FSOverlayAttach *currentAttach;
@property (nonatomic, strong) FSOverlayAttach *drawingAttach;
@property (atomic, strong) NSLock *renderSnapshotLock;
@property (assign) BOOL needCleanBackgroundColor;
@property (nonatomic, copy) dispatch_block_t refreshCurrentPicBlock;
#if TARGET_OS_IOS || TARGET_OS_TV
@property (atomic, assign) BOOL isEnterBackground;
#endif
@property (nonatomic, strong) FSDisplayLinkWrapper *displayLinkWrapper;
@property (atomic, assign) long previousTag;
// Whether the current display supports EDR/HDR and we have switched to HDR rendering mode.
@property (nonatomic, assign) BOOL hdrDirectDisplayActive HDR_API_AVAILABLE;
// 高斯模糊背景：复用字幕管线（BGRA/DIRECT）把模糊后的纹理铺满整个视图。
@property (atomic, strong) FSMetalSubtitlePipeline *backgroundPipeline;
@property (atomic, strong) FSMetalBlurFilter *blurFilter;
@property (atomic, strong) id<MTLTexture> backgroundTexture;
@property (atomic, assign) BOOL needRebuildBackgroundTexture;
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
@synthesize directDisplayHDRSupportted = _directDisplayHDRSupportted;
@synthesize allowHDRDirectDisplay = _allowHDRDirectDisplay;

@synthesize displayDelegate = _displayDelegate;

- (void)dealloc
{
    [_displayLinkWrapper invalidate];
    _displayLinkWrapper = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
#if USE_METAL_TEXTURE_CACHE
    if (_pictureTextureCache) {
        CFRelease(_pictureTextureCache);
        _pictureTextureCache = NULL;
    }
#endif
}

- (void)setupDisplayLink {
    if (_displayLinkWrapper) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    _displayLinkWrapper = [[FSDisplayLinkWrapper alloc] initWithCallback:^(CFTimeInterval timestamp) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self displayAttachWithTimestamp:timestamp];
    }];
#if TARGET_OS_OSX
    [_displayLinkWrapper updateWithWindow:self.window];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowDidChangeScreen:)
                                                  name:NSWindowDidChangeScreenNotification
                                                object:nil];
#endif
    [_displayLinkWrapper start];

#if TARGET_OS_OSX
    // Re-check HDR capability whenever screen parameters change (brightness, display connection).
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(screenParametersDidChange:)
                                                  name:NSApplicationDidChangeScreenParametersNotification
                                                object:nil];
#endif
}

#if TARGET_OS_OSX
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [_displayLinkWrapper updateWithWindow:self.window];
    [self updateHDRDisplayMode];
}

- (void)windowDidChangeScreen:(NSNotification *)notification {
    NSWindow *window = notification.object;
    if (window == self.window) {
        [_displayLinkWrapper updateWithWindow:window];
        [self updateHDRDisplayMode];
    }
}

- (void)screenParametersDidChange:(NSNotification *)notification {
    [self updateHDRDisplayMode];
}
#endif

#if TARGET_OS_IOS
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        if (@available(iOS 16.0, *)) {
            [self updateHDRDisplayMode];
        } else {
            // Fallback on earlier versions
        }
    }
}
#endif

/// Returns YES when the display supports EDR
- (BOOL)currentDisplaySupportsHDR HDR_API_AVAILABLE {
#if TARGET_OS_OSX
    NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
    // Use maximumPotentialExtendedDynamicRangeColorComponentValue (hardware capability),
    // NOT maximumExtendedDynamicRangeColorComponentValue (current OS allocation), because
    // the latter stays at 1.0 until the app has already opted the layer into EDR.
    if (@available(macOS 10.15, *)) {
        // maximumPotentialExtendedDynamicRangeColorComponentValue reflects hardware capability
        // regardless of whether the layer has already opted into EDR.
        return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0;
    }
    // macOS 10.14: the only alternative (maximumExtendedDynamicRangeColorComponentValue,
    // available since 10.11) always returns 1.0 until the layer is already opted into EDR,
    // making reliable pre-opt-in detection impossible. Fall back to NO.
    return NO;
#elif TARGET_OS_IOS
    // currentEDRHeadroom is iOS 16+. No public API exists on iOS 12–15 to detect EDR capability.
    if (@available(iOS 16.0, *)) {
        return UIScreen.mainScreen.currentEDRHeadroom > 1.0;
    }
    return NO;
#else
    return NO;
#endif
}

- (void)updateHDRDisplayModeForHDRContentAvailable:(BOOL)isHDRContent completion:(dispatch_block_t)completion
{
#if !TARGET_OS_TV
    if (@available(iOS 16.0, macOS 10.11, *)) {
        // Determine HDR content BEFORE creating the pipeline so colorPixelFormat is
        // already set to the correct value (RGBA16Float or BGRA8Unorm) when
        // FSMetalRenderer is initialised. This avoids the "build → format mismatch → nil → rebuild" cycle.
        [self updateHDRDisplayModeForHDRContent:isHDRContent completion:completion];
        return;
    }
#endif
    
    if (completion) {
        completion();
    }
}
/// Core implementation: switches pixel format, layer color space, and hdrDisplayEnabled
/// based on whether the display supports EDR AND the content is HDR.
/// If colorPixelFormat changes, nils the existing pipeline so it is rebuilt with the new format.
- (void)updateHDRDisplayModeForHDRContent:(BOOL)isHDRContent completion:(dispatch_block_t)completion HDR_API_AVAILABLE
{
    //content and device supported
    BOOL supportsHDR = [self currentDisplaySupportsHDR] && isHDRContent;
    
    if (supportsHDR != self.directDisplayHDRSupportted) {
        _directDisplayHDRSupportted = supportsHDR;
        ALOGI("content and display support HDR: %d", supportsHDR);
    }
    
    //and user allow direct display
    BOOL activeHDR = supportsHDR && _allowHDRDirectDisplay;
    if (self.hdrDirectDisplayActive == activeHDR) {
        if (completion) {
            completion();
        }
        return;
    }
    self.hdrDirectDisplayActive = activeHDR;
    
    //direct display status need update
    MTLPixelFormat newFormat = activeHDR ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
    BOOL formatChanged = (self.colorPixelFormat != newFormat);
   
    if (formatChanged) {
        // MTLRenderPipelineState bakes in colorAttachments[0].pixelFormat at creation time.
        // 字幕/背景管线也把像素格式烤进了 PSO，目标格式变化后必须一并重建，
        // 否则在新的渲染目标上 setRenderPipelineState: 会触发 Metal 断言崩溃。
        self.picturePipeline = nil;
        self.subPipeline = nil;
        // 背景管线只在 rebuildBackgroundTextureIfNeed 里重建，需置位让其下一帧用新格式重建。
        self.backgroundPipeline = nil;
        self.needRebuildBackgroundTexture = (self.backgroundImage != nil);
    }
 
#if !TARGET_OS_TV
    dispatch_async(dispatch_get_main_queue(), ^{
        CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
        metalLayer.wantsExtendedDynamicRangeContent = supportsHDR;
        // Update colorPixelFormat and metalLayer's colorspace
        self.colorPixelFormat = newFormat;
        if (activeHDR) {
            CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
            metalLayer.colorspace = cs;
            ALOGI("update layer colorspace:%@",cs);
            CGColorSpaceRelease(cs);
        } else {
            metalLayer.colorspace = nil;
            ALOGI("update layer colorspace:nil");
        }
        
        if (completion) {
            completion();
        }
    });
#else
    if (completion) {
        completion();
    }
#endif
}

/// Called from the main thread (screen change notifications, setAllowHDRDisplay:).
/// Uses renderSnapshotLock to synchronise with the render thread, which holds the same
/// lock for the entire setupPipelineIfNeed: → encode sequence in drawRect:.
- (void)updateHDRDisplayMode HDR_API_AVAILABLE {
    [self.renderSnapshotLock lock];
    if (self.picturePipeline) {
        [self updateHDRDisplayModeForHDRContentAvailable:[self.picturePipeline isHDRContent] completion:^{
            [self.renderSnapshotLock unlock];
        }];
    } else {
        [self.renderSnapshotLock unlock];
    }
}

- (void)setAllowHDRDirectDisplay:(BOOL)allowHDRDirectDisplay HDR_API_AVAILABLE {
    if (_allowHDRDirectDisplay == allowHDRDirectDisplay) {
        return;
    }
    _allowHDRDirectDisplay = allowHDRDirectDisplay;
    // Re-evaluate: if we just disabled, force SDR; if we just enabled, check display capability.
    [self updateHDRDisplayMode];
}

- (void)displayAttachWithTimestamp:(const CFTimeInterval)timestamp {
    [self.renderSnapshotLock lock];
    FSOverlayAttach *currentAttach = self.currentAttach;

    if (currentAttach.tag == self.previousTag) {
        [self.renderSnapshotLock unlock];
        return;
    }
    currentAttach.presentationTime = timestamp;
    [self.renderSnapshotLock unlock];
    
    self.drawingAttach = currentAttach;

    // Set colorPixelFormat (and build the pipeline) BEFORE [self draw] acquires the Metal
    // drawable. currentDrawable uses the current CAMetalLayer pixelFormat; if colorPixelFormat
    // changes after the drawable is acquired, pipeline and drawable formats diverge → crash.
    CVPixelBufferRef pipelineRef = currentAttach.videoPicture;
    if (!pipelineRef && currentAttach.tilePieces.count > 0) {
        pipelineRef = ((FSTilePiece *)currentAttach.tilePieces.firstObject).pixelBuffer;
    }
    if (!pipelineRef) {
        return;
    }
    
    [self.renderSnapshotLock lock];
    BOOL isHDRContent = [FSMetalPipelineMeta isHDRContentWithPixelBuffer:pipelineRef];
    [self updateHDRDisplayModeForHDRContentAvailable:isHDRContent completion:^{
        [self setupPipelineIfNeed:pipelineRef blend:currentAttach.hasAlpha];
        if (currentAttach.subTexture) {
            [self setupSubPipelineIfNeed];
        }
        [self.renderSnapshotLock unlock];
        //use current DisplayLink thread
        [self draw];
    }];
}

- (BOOL)prepareMetal
{
    _rotatePreference   = (FSRotatePreference){FSRotateNone, 0.0};
    _colorPreference    = (FSColorConvertPreference){1.0, 1.0, 1.0};
    _darPreference      = (FSDARPreference){0.0};
    _backgroundBlurIterations = 3;
    _backgroundBlurSigma = 30.0;
    _renderSnapshotLock = [[NSLock alloc]init];
    _allowHDRDirectDisplay    = YES;
    
    [self setupDisplayLink];
    
    self.device = MTLCreateSystemDefaultDevice();
    if (!self.device) {
        ALOGE("Can't Create Metal Device.");
        return NO;
    }
#if USE_METAL_TEXTURE_CACHE
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

#pragma mark - blurred background

- (CGImageRef)cgImageFromBackgroundImage:(UIImage *)image CF_RETURNS_NOT_RETAINED
{
    if (!image) {
        return NULL;
    }
#if TARGET_OS_OSX
    return [image CGImageForProposedRect:NULL context:nil hints:nil];
#else
    return image.CGImage;
#endif
}

// 惰性重建模糊纹理（渲染线程调用）。
- (void)rebuildBackgroundTextureIfNeed
{
    if (!self.needRebuildBackgroundTexture) {
        return;
    }
    self.needRebuildBackgroundTexture = NO;
    UIImage *image = self.backgroundImage;
    if (!image) {
        self.backgroundTexture = nil;
        return;
    }
    if (!self.blurFilter) {
        self.blurFilter = [[FSMetalBlurFilter alloc] initWithDevice:self.device];
    }
    CGImageRef cgImage = [self cgImageFromBackgroundImage:image];
    self.backgroundTexture = [self.blurFilter blurredTextureFromImage:cgImage
                                                               sigma:self.backgroundBlurSigma
                                                          iterations:self.backgroundBlurIterations
                                                        commandQueue:self.commandQueue];
    if (self.backgroundTexture && ![self setupBackgroundPipelineIfNeed]) {
        self.backgroundTexture = nil;
    }
}

- (BOOL)setupBackgroundPipelineIfNeed
{
    if (self.backgroundPipeline) {
        return YES;
    }
    
    FSMetalSubtitlePipeline *pipeline = [[FSMetalSubtitlePipeline alloc] initWithDevice:self.device
                                                                               inFormat:FSMetalSubtitleInFormatBRGA
                                                                              outFormat:FSMetalSubtitleOutFormatDIRECT
                                                                       colorPixelFormat:self.colorPixelFormat];
    if (![pipeline createRenderPipelineIfNeed]) {
        ALOGE("create backgroundRenderPipeline failed.");
        return NO;
    }
    self.backgroundPipeline = pipeline;
    return YES;
}

// 把模糊纹理铺满整个 drawable（拉伸填充；背景已模糊，形变不可见）。
- (void)encodeBackground:(id<MTLRenderCommandEncoder>)renderEncoder
            drawableSize:(CGSize)drawableSize
{
    [renderEncoder setViewport:(MTLViewport){0.0, 0.0, drawableSize.width, drawableSize.height, -1.0, 1.0}];
    [self.backgroundPipeline updateSubtitleVertexIfNeed:CGRectMake(-1.0, -1.0, 2.0, 2.0)];
    [self.backgroundPipeline drawTexture:self.backgroundTexture encoder:renderEncoder];
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
#if !TARGET_OS_TV
    if (@available(iOS 16.0, macOS 10.11, *)) {
        picturePipeline.hdrDisplay = self.directDisplayHDRSupportted;
    }
#endif
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
         drawableSize:(CGSize)drawableSize
                ratio:(CGSize)ratio
{
#if !TARGET_OS_TV
    if (@available(iOS 16.0, *)) {
        self.picturePipeline.hdrDisplay = self.directDisplayHDRSupportted;
    } else {
        // Fallback on earlier versions
    }
#endif
    self.picturePipeline.autoZRotateDegrees = attach.autoZRotate;
    self.picturePipeline.rotateType = self.rotatePreference.type;
    self.picturePipeline.rotateDegrees = self.rotatePreference.degrees;
    
    bool applyAdjust = _colorPreference.brightness != 1.0 || _colorPreference.saturation != 1.0 || _colorPreference.contrast != 1.0;
    [self.picturePipeline updateColorAdjustment:(vector_float4){_colorPreference.brightness,_colorPreference.saturation,_colorPreference.contrast,applyAdjust ? 1.0 : 0.0}];
    self.picturePipeline.vertexRatio = ratio;
    
    self.picturePipeline.textureCrop = CGSizeMake(1.0 * (attach.pixelW - attach.w) / attach.pixelW, 1.0 * (attach.pixelH - attach.h) / attach.pixelH);
    
    // Set the region of the drawable to draw into.
    [renderEncoder setViewport:(MTLViewport){0.0, 0.0, drawableSize.width, drawableSize.height, -1.0, 1.0}];
    //upload textures
    [self.picturePipeline uploadTextureWithEncoder:renderEncoder
                                          textures:attach.videoTextures];
}

- (void)encodeSubtitle:(id<MTLRenderCommandEncoder>)renderEncoder
          drawableSize:(CGSize)viewport
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
    BOOL hasTileGrid = (currentAttach.tilePieces.count > 0);

    [self rebuildBackgroundTextureIfNeed];

    //Clean Background Color
    if (!currentAttach.videoPicture && !hasTileGrid) {
        if (self.needCleanBackgroundColor) {
            id<MTLTexture> texture = drawable.texture;

            MTLRenderPassDescriptor *passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
            passDescriptor.colorAttachments[0].texture = texture;
            passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
            passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
            passDescriptor.colorAttachments[0].clearColor = self.clearColor;
            
            id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
            id <MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
            //无视频时，用高斯模糊背景填充，替代纯色背景。
            if (self.backgroundTexture) {
                [self encodeBackground:commandEncoder drawableSize:self.drawableSize];
            }
            [commandEncoder endEncoding];
            [commandBuffer presentDrawable:drawable];
            [commandBuffer commit];
            self.needCleanBackgroundColor = NO;
        }
        return;
    }
    
    [self.renderSnapshotLock lock];
    self.drawingAttach = nil;

    // tile-grid 先合成成单帧并缓存到 attach（只做一次），之后统一走单帧路径，
    // 旋转/缩放作用于整张合成图，避免逐 tile 旋转错乱。
    if (hasTileGrid && ![self ensureTileGridComposited:currentAttach]) {
        [self.renderSnapshotLock unlock];
        return;
    }
    
    //generate textures (single-frame path)
    if (!currentAttach.videoTextures) {
        CVMetalTextureCacheRef textureCache = NULL;
    #if USE_METAL_TEXTURE_CACHE
        textureCache = _pictureTextureCache;
    #endif
        currentAttach.videoTextures = [FSMetalTextureUtils doGenerateTexture:currentAttach.videoPicture textureCache:textureCache device:self.device];
    }
    
    if (self.displayDelegate && [self.displayDelegate respondsToSelector:@selector(videoRenderingDidDisplay:attach:)]) {
        [self.displayDelegate videoRenderingDidDisplay:self attach:currentAttach];
    }
    
    //draw textures
    CGSize drawableSize = self.drawableSize;
    
    CGSize ratio = [self computeNormalizedVerticesRatio:currentAttach drawableSize:drawableSize];
    
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
    
    //先铺高斯模糊背景，视频画面随后绘制在其上，黑边区域即显示模糊背景。
    //只有 AspectFit 会留出黑边，其它模式视频铺满全屏，无需绘制背景。
    if (self.backgroundTexture && _scalingMode == FSScalingModeAspectFit) {
        [self encodeBackground:renderEncoder drawableSize:drawableSize];
    }
    
    [self encodePicture:currentAttach
          renderEncoder:renderEncoder
           drawableSize:drawableSize
                  ratio:ratio];
    
    if (currentAttach.subTexture) {
        [self encodeSubtitle:renderEncoder
                drawableSize:drawableSize
                     texture:currentAttach.subTexture];
    }
    //[renderEncoder popDebugGroup];
    [renderEncoder endEncoding];
    //[commandBuffer presentDrawable:drawable];
    [commandBuffer presentDrawable:drawable atTime:currentAttach.presentationTime];
    // Finalize rendering here & push the command buffer to the GPU.
    [commandBuffer commit];
    self.previousTag = currentAttach.tag;
    
    [self.renderSnapshotLock unlock];
}

- (CGImageRef)_snapshotWithSubtitle:(BOOL)drawSub
{
    [self.renderSnapshotLock lock];
    
    FSOverlayAttach *attach = self.currentAttach;
    BOOL hasTileGrid = (attach.tilePieces.count > 0);
    CVPixelBufferRef pixelBuffer = attach.videoPicture;
    if (!pixelBuffer && !hasTileGrid) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }
    
    if (!self.offscreenRendering) {
        self.offscreenRendering = [FSMetalOffscreenRendering alloc];
    }
    
    // tile-grid 先合成成单帧并缓存到 attach，之后统一走单帧路径。
    if (hasTileGrid && ![self ensureTileGridComposited:attach]) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }
    
    float width  = attach.w;
    float height = attach.h;
    
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

    // FSMetalFBO render target is always BGRA8Unorm; HDR pipelines use RGBA16Float.
    // Use a temporary SDR pipeline for the snapshot so pixel formats match.
    // (Snapshots are saved as SDR image files, so tone-mapping is correct here.)
    FSMetalRenderer *savedPipeline = nil;
#if !TARGET_OS_TV
    if (@available(iOS 16.0, *)) {
        if (self.directDisplayHDRSupportted) {
            savedPipeline = self.picturePipeline;
            FSMetalRenderer *sdrPipeline = [[FSMetalRenderer alloc] initWithDevice:self.device colorPixelFormat:MTLPixelFormatBGRA8Unorm];
            if (![sdrPipeline createRenderPipelineIfNeed:attach.videoPicture blend:attach.hasAlpha]) {
                [self.renderSnapshotLock unlock];
                return NULL;
            }
            self.picturePipeline = sdrPipeline;
        }
    } else {
        // Fallback on earlier versions
    }
#endif

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    CGImageRef result = [self.offscreenRendering snapshot:viewport device:self.device commandBuffer:commandBuffer doUploadPicture:^(id<MTLRenderCommandEncoder> _Nonnull renderEncoder) {
        
        if (!attach.videoTextures) {
            CVMetalTextureCacheRef textureCache = NULL;
        #if USE_METAL_TEXTURE_CACHE
            textureCache = self.pictureTextureCache;
        #endif
            attach.videoTextures = [FSMetalTextureUtils doGenerateTexture:attach.videoPicture textureCache:textureCache device:self.device];
        }
        
        [self encodePicture:attach
              renderEncoder:renderEncoder
               drawableSize:viewport
                      ratio:CGSizeMake(1.0, 1.0)];
        
        if (drawSub && attach.subTexture) {
            [self encodeSubtitle:renderEncoder
                    drawableSize:viewport
                         texture:attach.subTexture];
        }
    }];
    if (savedPipeline) {
        self.picturePipeline = savedPipeline;
    }
    [self.renderSnapshotLock unlock];
    return result;
}

//not support heic tile grid
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
    BOOL hasTileGrid = (attach.tilePieces.count > 0);
    CVPixelBufferRef pixelBuffer = attach.videoPicture;
    if (!pixelBuffer && !hasTileGrid) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }
    
    if (!self.offscreenRendering) {
        self.offscreenRendering = [FSMetalOffscreenRendering alloc];
    }
    
    // tile-grid 先合成成单帧并缓存到 attach，之后统一走单帧路径。
    if (hasTileGrid && ![self ensureTileGridComposited:attach]) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }
    
    if (![self setupPipelineIfNeed:attach.videoPicture blend:attach.hasAlpha]) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }

    if (attach.subTexture && ![self setupSubPipelineIfNeed]) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }

    // FSMetalFBO render target is always BGRA8Unorm; HDR pipelines use RGBA16Float.
    // Use a temporary SDR pipeline for the snapshot so pixel formats match.
    FSMetalRenderer *savedPipeline = nil;
#if !TARGET_OS_TV
    if (@available(iOS 16.0, *)) {
        if (self.directDisplayHDRSupportted) {
            savedPipeline = self.picturePipeline;
            FSMetalRenderer *sdrPipeline = [[FSMetalRenderer alloc] initWithDevice:self.device colorPixelFormat:MTLPixelFormatBGRA8Unorm];
            if (![sdrPipeline createRenderPipelineIfNeed:attach.videoPicture blend:attach.hasAlpha]) {
                [self.renderSnapshotLock unlock];
                return NULL;
            }
            self.picturePipeline = sdrPipeline;
        }
    } else {
        // Fallback on earlier versions
    }
#endif

    CGSize drawableSize = self.drawableSize;
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    CGImageRef result = [self.offscreenRendering snapshot:drawableSize device:self.device commandBuffer:commandBuffer doUploadPicture:^(id<MTLRenderCommandEncoder> _Nonnull renderEncoder) {
        if (!attach.videoTextures) {
            CVMetalTextureCacheRef textureCache = NULL;
        #if USE_METAL_TEXTURE_CACHE
            textureCache = self.pictureTextureCache;
        #endif
            attach.videoTextures = [FSMetalTextureUtils doGenerateTexture:attach.videoPicture textureCache:textureCache device:self.device];
        }
        CGSize ratio = [self computeNormalizedVerticesRatio:attach drawableSize:drawableSize];
        [self encodePicture:attach
              renderEncoder:renderEncoder
               drawableSize:drawableSize
                      ratio:ratio];

        if (attach.subTexture) {
            [self encodeSubtitle:renderEncoder
                    drawableSize:drawableSize
                         texture:attach.subTexture];
        }
    }];
    if (savedPipeline) {
        self.picturePipeline = savedPipeline;
    }
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
    _displayLinkWrapper.paused = YES;
}

- (void)applicationWillEnterForeground {
    self.isEnterBackground = NO;
    _displayLinkWrapper.paused = NO;
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

    // HEIC tile-grid 模式允许 videoPicture 为 nil，只要 tilePieces 非空
    BOOL hasTiles = (attach.tilePieces.count > 0);
    if (!attach.videoPicture && !hasTiles) {
        ALOGW("FSMetalView: videoPicture is nil and no tile pieces\n");
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

#pragma mark HEIC tile-graid

// 合成成一张 BGRA 纹理并缓存到 attach 上，转成普通单帧。
// 合成交给 FSMetalTileGridPipeline；之后旋转/缩放/调色/快照都走单帧路径作用于整张图，
// 避免逐 tile 旋转导致画面错乱。合成只做一次：完成后 tilePieces 置空、videoPicture 被填充。
// 注意：必须在持有 renderSnapshotLock 时调用（与显示/快照共用纹理缓存，需串行）。
- (BOOL)ensureTileGridComposited:(FSOverlayAttach *)attach
{
    if (attach.tilePieces.count == 0) {
        // 已合成过，或本就不是 tile-grid。
        return YES;
    }

    if (!self.tileGridPipeline) {
        self.tileGridPipeline = [[FSMetalTileGridPipeline alloc] initWithDevice:self.device];
    }

    CVMetalTextureCacheRef textureCache = NULL;
#if USE_METAL_TEXTURE_CACHE
    textureCache = _pictureTextureCache;
#endif

    // 合成（或命中缓存）后直接拿到可显示的纹理，不再每帧重新生成纹理。
    id<MTLTexture> texture = [self.tileGridPipeline compositeTileGrid:attach
                                                        textureCache:textureCache
                                                        commandQueue:self.commandQueue];
    if (!texture) {
        return NO;
    }

    // 转成普通单帧：直接用合成纹理；videoPicture 仅用于建立 BGRA 显示管线（按像素格式选 shader）。
    // 合成结果即显示尺寸，pixelW/H 与 w/h 相等（采样时无需裁剪）。
    attach.videoTextures = @[texture];
    attach.videoPicture = CVPixelBufferRetain(self.tileGridPipeline.compositedPixelBuffer); // 由 attach dealloc 释放
    attach.pixelW = attach.w;
    attach.pixelH = attach.h;
    attach.tilePieces = nil; // 释放各 tile 的 pixelBuffer/textures
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

- (void)setBackgroundImage:(UIImage *)backgroundImage
{
    if (_backgroundImage == backgroundImage) {
        return;
    }
    _backgroundImage = backgroundImage;
    // 纹理在渲染线程惰性重建（那里 device / commandQueue 一定就绪）。
    self.needRebuildBackgroundTexture = YES;
    if (!backgroundImage) {
        self.backgroundTexture = nil;
    }
    // 让背景立刻刷新（即使暂停或无视频）。
    self.needCleanBackgroundColor = YES;
    [self setNeedsRefreshCurrentPic];
}

- (void)setBackgroundBlurIterations:(int)backgroundBlurIterations
{
    if (backgroundBlurIterations < 1) {
        backgroundBlurIterations = 1;
    }
    if (_backgroundBlurIterations == backgroundBlurIterations) {
        return;
    }
    _backgroundBlurIterations = backgroundBlurIterations;
    if (_backgroundImage) {
        self.needRebuildBackgroundTexture = YES;
        self.needCleanBackgroundColor = YES;
        [self setNeedsRefreshCurrentPic];
    }
}

- (void)setBackgroundBlurSigma:(float)backgroundBlurSigma
{
    if (backgroundBlurSigma <= 0) {
        backgroundBlurSigma = 30.0;
    }
    if (_backgroundBlurSigma == backgroundBlurSigma) {
        return;
    }
    _backgroundBlurSigma = backgroundBlurSigma;
    if (_backgroundImage) {
        self.needRebuildBackgroundTexture = YES;
        self.needCleanBackgroundColor = YES;
        [self setNeedsRefreshCurrentPic];
    }
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
