//
//  FSMetalView.m
//  FFmpegTutorial-macOS
//
//  Created by debugly on 2022/11/22.
//  Copyright © 2022 debugly's Awesome FFmpeg Tutorial. All rights reserved.
//

#import "FSMetalView.h"
#import <AVFoundation/AVFoundation.h>
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
#import "FSMediaPlayback.h"
#import "FSDisplayLinkWrapper.h"
#import "FSMetalTextureUtils.h"
#import "../apple/ijk_cvpixelbuffer.h"
#import "ijksdl/ijksdl_gpu.h"

#if TARGET_OS_IOS || TARGET_OS_TV
typedef CGRect NSRect;
#endif

// 每个 FSMetalView 独立持有转换结果和绘制状态；不持有原始输入 attach。
@interface FSMetalRenderFrame : NSObject <FSVideoRenderFrame>
@property(nonatomic) CVPixelBufferRef videoPicture; // owned
@property(nonatomic, strong) NSArray *videoTextures;
@property(nonatomic, strong) NSArray *videoCVTextures; // owns +1 CVMetalTexture refs
@property(nonatomic) SDL_TextureOverlay *overlay; // owned
@property(nonatomic) int pixelW;
@property(nonatomic) int pixelH;
@property(nonatomic) long tag;
@property(nonatomic) int w;
@property(nonatomic) int h;
@property(nonatomic) int sarNum;
@property(nonatomic) int sarDen;
@property(nonatomic) int autoZRotate;
@property(nonatomic) BOOL hasAlpha;
@property(nonatomic, readonly) id subTexture;
- (instancetype)initWithSource:(FSOverlayAttach *)source;
// Caller serializes preparation with rendering/snapshots; cache is borrowed.
- (BOOL)prepareTexturesWithDevice:(id<MTLDevice>)device
                     textureCache:(CVMetalTextureCacheRef)textureCache;
@end

@implementation FSMetalRenderFrame

- (instancetype)initWithSource:(FSOverlayAttach *)source
{
    if ((self = [super init])) {
        _w = source.w;
        _h = source.h;
        _sarNum = source.sarNum;
        _sarDen = source.sarDen;
        _autoZRotate = source.autoZRotate;
        _hasAlpha = source.hasAlpha;
        _overlay = SDL_TextureOverlay_Retain(source.overlay);
    }
    return self;
}

- (BOOL)prepareTexturesWithDevice:(id<MTLDevice>)device
                     textureCache:(CVMetalTextureCacheRef)textureCache
{
    if (self.videoTextures.count > 0) {
        return YES;
    }
    NSMutableArray *cvTextures = nil;
    NSArray *textures = [FSMetalTextureUtils doGenerateTexture:self.videoPicture
                                                  textureCache:textureCache
                                                        device:device
                                                 outCVTextures:&cvTextures];
    if (textures.count == 0) {
        return NO;
    }
    for (id item in self.videoCVTextures) CFRelease((__bridge CVMetalTextureRef)item);
    self.videoCVTextures = cvTextures;
    self.videoTextures = textures;
    return YES;
}

- (id)subTexture
{
    return self.overlay ? (__bridge id)self.overlay->getTexture(self.overlay) : nil;
}

- (void)dealloc {
    SDL_TextureOverlay_Release(&_overlay);
    if (_videoPicture) CVPixelBufferRelease(_videoPicture);
    for (id item in _videoCVTextures) CFRelease((__bridge CVMetalTextureRef)item);
}

@end

@interface FSMetalView ()

// The command queue used to pass commands to the device.
@property (nonatomic, strong) id<MTLCommandQueue>commandQueue;
@property (nonatomic, assign) CVMetalTextureCacheRef pictureTextureCache;
@property (nonatomic, strong) FSMetalPipelineMeta *pipelineMeta;
@property (atomic, strong) FSMetalRenderer *picturePipeline;
// HEIC tile-grid 合成管线：结果缓存于本视图的 FSMetalRenderFrame。
@property (atomic, strong) FSMetalTileGridPipeline *tileGridPipeline;
@property (atomic, strong) FSMetalSubtitlePipeline *subPipeline;
@property (nonatomic, strong) FSMetalOffscreenRendering *offscreenRendering;
@property (atomic, strong) FSMetalRenderFrame *currentFrame;
@property (nonatomic, strong) FSMetalRenderFrame *drawingFrame;
@property (atomic, strong) NSLock *renderSnapshotLock;
@property (assign) BOOL needCleanBackgroundColor;
@property (nonatomic, copy) dispatch_block_t refreshCurrentPicBlock;
#if TARGET_OS_IOS || TARGET_OS_TV
@property (atomic, assign) BOOL isEnterBackground;
#endif
@property (nonatomic, strong) FSDisplayLinkWrapper *displayLinkWrapper;
@property (atomic, assign) long previousTag;
// YES when the current display supports EDR/HDR and HDR content is rendered natively
// (no tone-mapping to SDR). Updated automatically when the display changes.
// HDR direct display is unavailable on tvOS
@property(nonatomic, readonly) BOOL directDisplayHDRSupported HDR_API_AVAILABLE;
// Whether the current display supports EDR/HDR and we have switched to HDR rendering mode.
@property (nonatomic, assign) BOOL hdrDirectDisplayActive HDR_API_AVAILABLE;
// 高斯模糊背景：复用字幕管线（BGRA/DIRECT）把模糊后的纹理铺满整个视图。
@property (atomic, strong) FSMetalSubtitlePipeline *backgroundPipeline;
@property (atomic, strong) FSMetalBlurFilter *blurFilter;
@property (atomic, strong) id<MTLTexture> backgroundTexture;
@property (atomic, assign) BOOL needRebuildBackgroundTexture;
@property (nonatomic, assign) BOOL screenSupportsHDR;
@property (nonatomic) MTLClearColor requestedBackgroundColor;
@property (atomic) BOOL automaticBackgroundTransparencyActive;
@property (atomic) BOOL backgroundTransparencyApplied;
@property (nonatomic) BOOL picturePipelineHasAlpha;
#if !TARGET_OS_TV
// 画中画内容层（AVSampleBufferDisplayLayer）；见 -preparePictureInPicture。
@property (nonatomic, strong, nullable) AVSampleBufferDisplayLayer *pictureInPictureDisplayLayer;
// 承载内容层的普通容器视图（贴在渲染视图下方、同尺寸）。不能直接把内容层挂到
// CAMetalLayer 上：AVKit 会给内容层建 host view 并按父层坐标算几何，CAMetalLayer
// 下会算出 NaN，AppKit 校验几何时直接崩（Invalid view geometry: x is NaN）。
@property (nonatomic, strong, nullable) UIView *pictureInPictureContainerView;
@property (nonatomic, assign) BOOL pictureInPictureStopping;
#if TARGET_OS_OSX
// 仅记录本次退出中由我们隐藏的占位视图；弱引用不延长 AVKit 视图的生命周期。
@property (nonatomic, strong) NSHashTable<NSView *> *pictureInPictureHiddenPlaceholders;
#endif
// 预热帧计数：prepare 之后先喂几帧让 layer 有内容（层此时 opacity=0，不可见），
// 之后只在画中画真正运行时持续喂帧，避免白白占用 GPU 合成。
@property (nonatomic, assign) NSUInteger pictureInPictureWarmFrames;
// 内容层的播放时间轴：AVKit 用它推算画中画窗口里的当前进度/时长。由 FSPlayer 在
// 播放/暂停/seek/结束时通过 -updatePictureInPictureTimebaseWithTime:rate: 驱动。
@property (nonatomic, assign) CMTimebaseRef pictureInPictureTimebase;
#endif
@end

@implementation FSMetalView
{
    // Pool reused when converting software-decoded AVFrames into CVPixelBuffers on the
    // render thread (moved here from the retired SDL_VoutOverlay conversion).
    FSSwPixelBufferPool _swPixelBufferPool;
}

@synthesize scalingMode = _scalingMode;
// rotate preference
@synthesize xRotateDegrees = _xRotateDegrees;
@synthesize yRotateDegrees = _yRotateDegrees;
@synthesize zRotateDegrees = _zRotateDegrees;
// color conversion preference
@synthesize colorPreference = _colorPreference;
// user defined display aspect ratio
@synthesize darPreference = _darPreference;

@synthesize preventDisplay = _preventDisplay;
#if TARGET_OS_IOS
@synthesize scaleFactor = _scaleFactor;
#endif
@synthesize allowHDRDirectDisplay = _allowHDRDirectDisplay;

@synthesize displayDelegate = _displayDelegate;

#pragma mark - Initialization & Lifecycle

- (void)dealloc
{
    // 先停掉 display link，确保没有回调仍在向 textureCache 生成/释放纹理。
    // CVDisplayLinkStop 会等待正在执行的回调返回（回调内已用 @autoreleasepool 及时释放纹理）。
    [_displayLinkWrapper invalidate];
    _displayLinkWrapper = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];

#if !TARGET_OS_TV
    // 画中画容器视图是我们加在父视图上的，跟着视图一起回收。
    [_pictureInPictureContainerView removeFromSuperview];
    if (_pictureInPictureTimebase) {
        CMTimebaseSetRate(_pictureInPictureTimebase, 0.0);
        CFRelease(_pictureInPictureTimebase);
        _pictureInPictureTimebase = NULL;
    }
#endif

    // 释放顺序很关键：所有持有 CVMetalTexture（其 backing 属于 _pictureTextureCache）
    // 的对象必须在 CFRelease(cache) 之前先释放，否则纹理 finalize 时会回调进已释放的
    // cache，造成崩溃。ARC 默认在 dealloc 方法体结束后才释放 strong ivar，太晚了，
    // 因此这里显式提前置空。
    _currentFrame = nil;
    _drawingFrame = nil;
    _tileGridPipeline = nil;
    _picturePipeline = nil;
    _subPipeline = nil;
    _backgroundPipeline = nil;
    _backgroundTexture = nil;

    if (_pictureTextureCache) {
        // 释放前 flush，回收 cache 内已无引用的纹理，避免残留纹理在 cache 释放后 finalize。
        CVMetalTextureCacheFlush(_pictureTextureCache, 0);
        CFRelease(_pictureTextureCache);
        _pictureTextureCache = NULL;
    }
    if (_swPixelBufferPool.pool) {
        FSSwPixelBufferPoolRelease(&_swPixelBufferPool);
    }
}

- (BOOL)prepareMetal
{
    _xRotateDegrees     = 0.0;
    _yRotateDegrees     = 0.0;
    _zRotateDegrees     = 0.0;
    _colorPreference    = (FSColorConvertPreference){1.0, 1.0, 1.0};
    _darPreference      = (FSDARPreference){0.0};
    _backgroundBlurIterations = 3;
    _backgroundBlurSigma = 30.0;
    _renderSnapshotLock = [[NSLock alloc]init];
    _allowHDRDirectDisplay    = YES;
#if !TARGET_OS_TV
    if (@available(iOS 16.0, macOS 10.11, *)) {
        _screenSupportsHDR = [self currentDisplaySupportsHDR];
    }
#endif
    
    [self setupDisplayLink];
    
    self.device = MTLCreateSystemDefaultDevice();
    if (!self.device) {
        ALOGE("Can't Create Metal Device.");
        return NO;
    }
    CVReturn ret = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, self.device, NULL, &_pictureTextureCache);
    if (ret != kCVReturnSuccess) {
        //cache 创建失败不影响播放,纹理生成会自动回退 CPU 上传
        ALOGE("Create MetalTextureCache Failed:%d, fallback to CPU texture upload.",ret);
        _pictureTextureCache = NULL;
    }
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

- (void)setupDisplayLink {
    if (_displayLinkWrapper) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    _displayLinkWrapper = [[FSDisplayLinkWrapper alloc] initWithCallback:^(CFTimeInterval timestamp) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        // 每帧独立的自动释放池：本次回调里生成的 CVMetalTexture/MTLTexture 等自动释放对象
        // 在回调结束时立即在 CVDisplayLink 线程释放，而不是堆积到线程退出时才 drain。
        // 否则切换播放源销毁 view 时，线程退出 drain 的纹理会回调进正在被主线程
        // CFRelease 的 textureCache，造成并发释放崩溃（bufferBackingNotInUse @ 0x0）。
        @autoreleasepool {
            [self displayCurrentFrameWithTimestamp:timestamp];
        }
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

#pragma mark - HDR / EDR Display Mode Support

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

/// Core implementation: switches pixel format, layer color space, and hdrDisplayEnabled
/// based on whether the display supports EDR AND the content is HDR.
/// If colorPixelFormat changes, nils the existing pipeline so it is rebuilt with the new format.
- (void)updateHDRDisplayModeForHDRContent:(BOOL)isHDRContent HDR_API_AVAILABLE
{
    // Fast path: Check if we actually need to change display mode before hopping to the main thread.
    [self.renderSnapshotLock lock];
    BOOL supportsHDR = _screenSupportsHDR && isHDRContent;
    
    if (supportsHDR != self.directDisplayHDRSupported) {
        _directDisplayHDRSupported = supportsHDR;
        ALOGI("content and display support HDR: %d", supportsHDR);
    }
    
    BOOL activeHDR = supportsHDR && _allowHDRDirectDisplay;
    BOOL activeReady = (self.hdrDirectDisplayActive == activeHDR);
    self.hdrDirectDisplayActive = activeHDR;
    
    [self.renderSnapshotLock unlock];
    
    if (activeReady) {
        return;
    }
    
    void (^updateBlock)(void) = ^{
        [self.renderSnapshotLock lock];
        
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
        CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
        metalLayer.wantsExtendedDynamicRangeContent = activeHDR;
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
#endif
        
        [self.renderSnapshotLock unlock];
    };
    
    if ([NSThread isMainThread]) {
        updateBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), updateBlock);
    }
}

/// Called from the main thread (screen change notifications, setAllowHDRDisplay:).
/// Uses renderSnapshotLock to synchronise with the render thread, which holds the same
/// lock for the entire setupPipelineIfNeed: → encode sequence in drawRect:.
- (void)updateHDRDisplayMode HDR_API_AVAILABLE {
#if !TARGET_OS_TV
    BOOL displaySupportsHDR = [self currentDisplaySupportsHDR];
    [self.renderSnapshotLock lock];
    _screenSupportsHDR = displaySupportsHDR;
    BOOL isHDRContent = [self.pipelineMeta hdrContent];
    [self.renderSnapshotLock unlock];
    
    if (@available(iOS 16.0, macOS 10.11, *)) {
        [self updateHDRDisplayModeForHDRContent:isHDRContent];
    }
#endif
}

#if !TARGET_OS_TV
- (BOOL)allowHDRDirectDisplay HDR_API_AVAILABLE {
    [self.renderSnapshotLock lock];
    BOOL value = _allowHDRDirectDisplay;
    [self.renderSnapshotLock unlock];
    return value;
}

- (void)setAllowHDRDirectDisplay:(BOOL)allowHDRDirectDisplay HDR_API_AVAILABLE {
    [self.renderSnapshotLock lock];
    if (_allowHDRDirectDisplay == allowHDRDirectDisplay) {
        [self.renderSnapshotLock unlock];
        return;
    }
    _allowHDRDirectDisplay = allowHDRDirectDisplay;
    [self.renderSnapshotLock unlock];
    
    // Re-evaluate: if we just disabled, force SDR; if we just enabled, check display capability.
    [self updateHDRDisplayMode];
    [self setNeedsRefreshCurrentPic];
}
#endif

- (CGSize)computeNormalizedVerticesRatio:(FSMetalRenderFrame *)frame drawableSize:(CGSize)drawableSize
{
    if (_scalingMode == FSScalingModeFill) {
        return CGSizeMake(1.0, 1.0);
    }

    int frameWidth = frame.w;
    int frameHeight = frame.h;

    //keep video AVRational
    if (frame.sarNum > 0 && frame.sarDen > 0) {
        frameWidth = 1.0 * frame.sarNum / frame.sarDen * frameWidth;
    }
    
    int zDegrees = 0;
    zDegrees += (int)self.zRotateDegrees;
    zDegrees += frame.autoZRotate;

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
        if (1.0 * frame.w / frame.h > darRatio) {
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

#pragma mark - Blurred Background & Gaussian Filter

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

#pragma mark - Pipeline & Upload Textures

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
        if ([self.picturePipeline matchPixelBuffer:pixelBuffer] && self.picturePipelineHasAlpha == blend) {
            return YES;
        }
        ALOGI("pixel format not match,need rebuild pipeline");
    }
    
    FSMetalRenderer *picturePipeline = [[FSMetalRenderer alloc] initWithDevice:self.device colorPixelFormat:self.colorPixelFormat];
#if !TARGET_OS_TV
    if (@available(iOS 16.0, macOS 10.11, *)) {
        picturePipeline.hdrDisplay = self.hdrDirectDisplayActive;
    }
#endif
    FSMetalPipelineMeta *meta = [FSMetalPipelineMeta createWithCVPixelbuffer:pixelBuffer];
    BOOL created = [picturePipeline createRenderPipelineIfNeed:meta blend:blend];

    if (!created) {
        ALOGE("create RenderPipeline failed.");
        picturePipeline = nil;
    }
    self.pipelineMeta = meta;
    self.picturePipeline = picturePipeline;
    self.picturePipelineHasAlpha = blend;
    return picturePipeline != nil;
}

- (void)encodePicture:(FSMetalRenderFrame *)frame
        renderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder
         drawableSize:(CGSize)drawableSize
                ratio:(CGSize)ratio
{
#if !TARGET_OS_TV
    if (@available(iOS 16.0, *)) {
        self.picturePipeline.hdrDisplay = self.hdrDirectDisplayActive;
    } else {
        // Fallback on earlier versions
    }
#endif
    self.picturePipeline.autoZRotateDegrees = frame.autoZRotate;
    self.picturePipeline.xRotateDegrees = self.xRotateDegrees;
    self.picturePipeline.yRotateDegrees = self.yRotateDegrees;
    self.picturePipeline.zRotateDegrees = self.zRotateDegrees;
    
    bool applyAdjust = _colorPreference.brightness != 1.0 || _colorPreference.saturation != 1.0 || _colorPreference.contrast != 1.0;
    [self.picturePipeline updateColorAdjustment:(vector_float4){_colorPreference.brightness,_colorPreference.saturation,_colorPreference.contrast,applyAdjust ? 1.0 : 0.0}];
    self.picturePipeline.vertexRatio = ratio;
    self.picturePipeline.textureCrop = CGSizeMake(1.0 * (frame.pixelW - frame.w) / frame.pixelW, 1.0 * (frame.pixelH - frame.h) / frame.pixelH);

    // Set the region of the drawable to draw into.
    [renderEncoder setViewport:(MTLViewport){0.0, 0.0, drawableSize.width, drawableSize.height, -1.0, 1.0}];
    //upload textures
    [self.picturePipeline uploadTextureWithEncoder:renderEncoder
                                          textures:frame.videoTextures];
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

// 合成成一张 BGRA 纹理，由当前视图的 FSMetalRenderFrame 持有。
// 合成交给 FSMetalTileGridPipeline；之后旋转/缩放/调色/快照都走单帧路径作用于整张图，
// 避免逐 tile 旋转导致画面错乱；输入 tilePieces 保持不变。
// 注意：必须在持有 renderSnapshotLock 时调用（与显示/快照共用纹理缓存，需串行）。
- (BOOL)ensureTileGridComposited:(FSMetalRenderFrame *)frame attach:(FSOverlayAttach *)attach
{
    if (frame.videoPicture || attach.tilePieces.count == 0) {
        // 已合成过，或本就不是 tile-grid。
        return YES;
    }

    if (!self.tileGridPipeline) {
        self.tileGridPipeline = [[FSMetalTileGridPipeline alloc] initWithDevice:self.device];
    }

    // 合成（或命中缓存）后直接拿到可显示的纹理，不再每帧重新生成纹理。
    id<MTLTexture> texture = [self.tileGridPipeline compositeTileGrid:attach.tilePieces
                                                              canvasW:attach.w
                                                              canvasH:attach.h
                                                         textureCache:self.pictureTextureCache
                                                         commandQueue:self.commandQueue];
    if (!texture) {
        return NO;
    }

    // 转成普通单帧：直接用合成纹理；videoPicture 仅用于建立 BGRA 显示管线（按像素格式选 shader）。
    // 合成结果即显示尺寸，pixelW/H 与 w/h 相等（采样时无需裁剪）。
    frame.videoTextures = @[texture];
    frame.videoPicture = CVPixelBufferRetain(self.tileGridPipeline.compositedPixelBuffer); // 由 FSMetalRenderFrame dealloc 释放
    frame.pixelW = frame.w;
    frame.pixelH = frame.h;
    return YES;
}

#pragma mark - Display Link & Core Rendering Flow

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

- (BOOL)refreshAttach:(SDL_TextureOverlay *)overlay
{
    [self.renderSnapshotLock lock];
    FSMetalRenderFrame *frame = self.currentFrame;
    if (!frame.videoPicture) {
        [self.renderSnapshotLock unlock];
        return NO;
    }
    if (frame.overlay != overlay) {
        SDL_TextureOverlay *replacement = SDL_TextureOverlay_Retain(overlay);
        SDL_TextureOverlay *previous = frame.overlay;
        frame.overlay = replacement;
        SDL_TextureOverlay_Release(&previous);
    }
    [self.renderSnapshotLock unlock];
    return YES;
}

// Produce a +1 retained CVPixelBuffer from a decoded AVFrame. VideoToolbox frames
// already carry the buffer in data[3] (zero copy, just retained); software frames are
// converted via the shared FSCVPixelBufferCreateFromAVFrame, reusing a per-view pool
// (recreated on dimension/format change) to avoid a per-frame allocation.
// Returns NULL on unsupported formats. Caller owns the returned buffer.
- (CVPixelBufferRef)pixelBufferFromAVFrame:(struct AVFrame *)frame CF_RETURNS_RETAINED
{
    if (!frame) {
        return NULL;
    }
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        CVPixelBufferRef pb = (CVPixelBufferRef)frame->data[3];
        return pb ? (CVPixelBufferRef)CVPixelBufferRetain(pb) : NULL;
    }

    if (frame->width <= 0 || frame->height <= 0) {
        return NULL;
    }

    CVPixelBufferPoolRef pool = FSSwPixelBufferPoolEnsure(&_swPixelBufferPool,
                                                          frame->width, frame->height, frame->format);
    return FSCVPixelBufferCreateFromAVFrame(frame, pool);
}

- (BOOL)displayAttach:(FSOverlayAttach *)source
{
    FSMetalRenderFrame *frame = [[FSMetalRenderFrame alloc] initWithSource:source];
    //call form (ff_vout thread)

    frame.tag = self.previousTag + 1;

    // HEIC tile-grid 模式允许 videoPicture 为 nil，只要 tilePieces 非空
    if (source.tilePieces.count > 0) {
        [self.renderSnapshotLock lock];
        // 将 tile-grid 合成单帧（BGRA），转换结果仅保存在本视图的 FSMetalRenderFrame。
        BOOL composited = [self ensureTileGridComposited:frame attach:source];
        [self.renderSnapshotLock unlock];
        if (!composited) {
            frame = nil;
            goto end;
        }
    } else if (!source.avframe && !frame.videoPicture) {
        ALOGD("FSMetalView: displayAttach nil frame\n");
        frame = nil;
        goto end;
    }
    
    // Derive a per-view CVPixelBuffer from the source AVFrame.
    // VideoToolbox frames wrap the pixel
    // buffer in data[3]; software frames are converted (planes copied, color/DoVi
    // side data stamped as CVBuffer attachments) so the rest of the Metal pipeline —
    // texture cache, colorspace detection, snapshots — keeps working unchanged.
    if (!frame.videoPicture && source.avframe) {
        CVPixelBufferRef pb = [self pixelBufferFromAVFrame:source.avframe];
        if (pb) {
            frame.videoPicture = pb; // +1 retained; balanced by FSMetalRenderFrame dealloc
            // Derive pixelW/H from the actual buffer, not frame->width: VideoToolbox
            // buffers are padded to coded width, and the crop calc in the picture
            // pipeline needs the buffer's real (padded) dimensions.
            frame.pixelW = (int)CVPixelBufferGetWidth(pb);
            frame.pixelH = (int)CVPixelBufferGetHeight(pb);
        }
    }

    if (self.displayDelegate && frame.videoPicture && [self.displayDelegate respondsToSelector:@selector(videoRenderingWillDisplay:videoFrame:)]) {
        CVPixelBufferRef oldBuffer = frame.videoPicture;
        CVPixelBufferRef newBuffer = [self.displayDelegate videoRenderingWillDisplay:self videoFrame:oldBuffer];
        if (newBuffer != oldBuffer) {
            // Delegate returns a borrowed buffer. Retain before releasing the old one.
            if (newBuffer) {
                CVPixelBufferRetain(newBuffer);
            }
            frame.videoPicture = newBuffer;
            // Tile-grid may already have textures for oldBuffer; regenerate them for the replacement.
            frame.videoTextures = nil;
            for (id item in frame.videoCVTextures) {
                CFRelease((__bridge CVMetalTextureRef)item);
            }
            frame.videoCVTextures = nil;
            CVPixelBufferRelease(oldBuffer);
            if (newBuffer) {
                frame.pixelW = (int)CVPixelBufferGetWidth(newBuffer);
                frame.pixelH = (int)CVPixelBufferGetHeight(newBuffer);
            }
        }
    }

#if !TARGET_OS_TV
    // 画中画内容层复用同一份 pixel buffer（解码后只转换一次）。
    if (frame.videoPicture && [self shouldFeedPictureInPicture]) {
        [self enqueuePictureInPictureSampleBuffer:frame.videoPicture
                                     displayWidth:frame.w
                                    displayHeight:frame.h];
    }
#endif

    if (self.preventDisplay || !frame.videoPicture) {
        frame = nil;
        goto end;
    }

end:
    [self.renderSnapshotLock lock];
    self.currentFrame = frame;
    [self.renderSnapshotLock unlock];
    return frame != nil;
}

- (void)displayCurrentFrameWithTimestamp:(const CFTimeInterval)timestamp {
#if !TARGET_OS_TV
    if (self.pictureInPictureActive && !self.pictureInPictureStopping) {
        return;
    }
#endif
    [self.renderSnapshotLock lock];
    FSMetalRenderFrame *currentAttach = self.currentFrame;

    if (!currentAttach || currentAttach.tag == self.previousTag) {
        [self.renderSnapshotLock unlock];
        return;
    }

    [self.renderSnapshotLock unlock];

    self.drawingFrame = currentAttach;

    // Layer/view changes must happen on the main thread, outside renderSnapshotLock.
    [self updateBackgroundTransparencyForFrame:currentAttach force:NO];

    if (!currentAttach.videoPicture) {
        return;
    }

#if !TARGET_OS_TV
    BOOL isHDRContent = [FSMetalPipelineMeta isHDRContentWithPixelBuffer:currentAttach.videoPicture];
    // 内部可能同步到主线程并再次获取 renderSnapshotLock，必须在锁外调用。
    if (@available(iOS 16.0, macOS 10.11, *)) {
        [self updateHDRDisplayModeForHDRContent:isHDRContent];
    }
#endif

    [self.renderSnapshotLock lock];
    // 用合成后的 videoPicture（tile-grid 为 BGRA，普通帧即原缓冲）建立显示管线。
    [self setupPipelineIfNeed:currentAttach.videoPicture blend:currentAttach.hasAlpha];
    if (currentAttach.subTexture) {
        [self setupSubPipelineIfNeed];
    }
    [self.renderSnapshotLock unlock];
    //use current DisplayLink thread
    [self draw];
}

#if !TARGET_OS_TV

#pragma mark - Picture in Picture

- (BOOL)preparePictureInPicture
{
    // 挂载 layer 必须在主线程，这里兼容后台线程调用。
    if (![NSThread isMainThread]) {
        __block BOOL prepared = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            prepared = [self preparePictureInPicture];
        });
        return prepared;
    }
    if (self.pictureInPictureDisplayLayer) {
        [self updatePictureInPictureLayerFrame];
        if (CGRectIsEmpty(self.pictureInPictureDisplayLayer.frame) && !CGRectIsEmpty(self.frame)) {
             self.pictureInPictureDisplayLayer.frame = self.bounds;
        }
        return YES;
    }
    if (@available(iOS 15.0, macOS 12.0, *)) {
        if (!self.superview) {
            ALOGW("FSMetalView: picture in picture needs a superview first\n");
            return NO;
        }
        AVSampleBufferDisplayLayer *layer = [[AVSampleBufferDisplayLayer alloc] init];
        layer.videoGravity = AVLayerVideoGravityResizeAspect;
        // 层本身透明：opacity 为 0 时不可见，因此透明背景（Alpha 视频）特性不受影响。
        layer.backgroundColor = [UIColor clearColor].CGColor;
        layer.opacity = 0.0;
        // 给内容层挂一个 controlTimebase：AVKit 据此推算画中画窗口的当前进度与总时长
        // （配合 FSPlayer 返回的 timeRangeForPlayback）。没有它时画中画窗口不显示时长/进度条。
        // 时间与速率由 FSPlayer 通过 -updatePictureInPictureTimebaseWithTime:rate: 驱动。
        if (!self.pictureInPictureTimebase) {
            CMTimebaseRef timebase = NULL;
            if (CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &timebase) == noErr && timebase) {
                CMTimebaseSetTime(timebase, kCMTimeZero);
                CMTimebaseSetRate(timebase, 0.0);
                self.pictureInPictureTimebase = timebase; // 本对象持有 +1，dealloc 释放
            }
        }
        if (self.pictureInPictureTimebase) {
            layer.controlTimebase = self.pictureInPictureTimebase; // 层另持一份引用
        }
        // 用一个普通容器视图承载内容层：AVKit 会给内容层建 host view 并按父层坐标算它自己的
        // frame，挂在 CAMetalLayer 下会算出 NaN（AppKit 直接 “Invalid view geometry: x is
        // NaN” 崩掉）。容器贴在渲染视图下面，屏幕上被 Metal 层盖住，看不出两份画面。
        UIView *container = [[UIView alloc] initWithFrame:self.frame];
#if TARGET_OS_OSX
        container.wantsLayer = YES;
#else
        container.userInteractionEnabled = NO;
#endif
        container.layer.backgroundColor = [UIColor clearColor].CGColor;
#if TARGET_OS_OSX
        [self.superview addSubview:container positioned:NSWindowBelow relativeTo:self];
#else
        [self.superview insertSubview:container belowSubview:self];
#endif
        [container.layer addSublayer:layer];
        self.pictureInPictureContainerView = container;
        self.pictureInPictureDisplayLayer = layer;
        [self updatePictureInPictureLayerFrame];
        self.pictureInPictureFeedEnabled = YES;
        // 先喂一帧“当前画面”：AVKit 建 host view 时要靠这一帧拿到视频尺寸算几何，
        // 内容层完全没画面时它算出的是 NaN，AppKit 校验几何直接崩。
        [self.renderSnapshotLock lock];
        FSMetalRenderFrame *lastRenderFrame = self.currentFrame;
        CVPixelBufferRef lastFrame = lastRenderFrame.videoPicture;
        int lastW = lastRenderFrame ? lastRenderFrame.w : 0;
        int lastH = lastRenderFrame ? lastRenderFrame.h : 0;
        if (lastFrame) {
            CFRetain(lastFrame);
        }
        [self.renderSnapshotLock unlock];
        if (lastFrame) {
            [self enqueuePictureInPictureSampleBuffer:lastFrame displayWidth:lastW displayHeight:lastH];
            CFRelease(lastFrame);
            // 首帧入队后已有 clean aperture；启动前用实际视频比例确定源层几何。
            [self updatePictureInPictureLayerFrame];
        }
        // 再喂几帧，让内容层进入可渲染状态，画中画启动时才不会黑屏。
        self.pictureInPictureWarmFrames = 3;
        ALOGI("FSMetalView: picture in picture content layer prepared, size:%.0fx%.0f\n", self.bounds.size.width, self.bounds.size.height);
        return YES;
    }
    ALOGW("FSMetalView: picture in picture requires iOS 15.0/macOS 12.0 or later\n");
    return NO;
}

- (nullable CALayer *)pictureInPictureContentLayer
{
    return self.pictureInPictureDisplayLayer;
}

- (void)setPictureInPictureActive:(BOOL)pictureInPictureActive
{
    if (_pictureInPictureActive == pictureInPictureActive) {
        return;
    }
#if TARGET_OS_OSX
    if (pictureInPictureActive) {
        // 在切换可见层之前更新；active=YES 后普通布局会让位给 PiP 面板尺寸修正。
        [self updatePictureInPictureLayerFrame];
    }
    if (!pictureInPictureActive && self.pictureInPictureStopping) {
        [self logPictureInPictureStopGeometry:@"didStop"];
    }
#endif
    _pictureInPictureActive = pictureInPictureActive;
    self.pictureInPictureStopping = NO;
    AVSampleBufferDisplayLayer *layer = self.pictureInPictureDisplayLayer;
    if (!layer) {
        return;
    }
    if (pictureInPictureActive) {
        // 再补一帧：启动瞬间画中画窗口立刻有画面
        self.pictureInPictureWarmFrames = 1;
    }
    // PiP 激活时，隐藏渲染层的 opacity，避免挡住 AVKit 占位图，但保留 FSMetalView 存活状态以持续喂帧
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.opacity = pictureInPictureActive ? 1.0 : 0.0;
    self.layer.opacity = pictureInPictureActive ? 0.0 : 1.0;
    [CATransaction commit];
#if TARGET_OS_OSX
    if (pictureInPictureActive) {
        // macOS 坑：AVKit 把内容层搬进 PiP 面板后，只按视频原生尺寸布局一次、且忽略
        // videoGravity，导致画中画窗口按 1:1 显示、只露出左上一块。反向修正 AVKit
        // 面板里的宿主视图，使其跟随窗口大小。PiP 窗口是异步出现的，故延迟多次重试，
        // 并监听窗口 resize 持续修正。
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(pictureInPictureHostWindowDidResize:)
                                                     name:NSWindowDidResizeNotification
                                                   object:nil];
        [self schedulePictureInPictureWindowLayoutFixes];
    } else {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSWindowDidResizeNotification
                                                      object:nil];
    }
    if (!pictureInPictureActive) {
        [self updatePictureInPictureLayerFrame];
        for (NSView *placeholder in self.pictureInPictureHiddenPlaceholders) {
            placeholder.hidden = NO;
        }
        [self.pictureInPictureHiddenPlaceholders removeAllObjects];
    }
#endif
    ALOGI("FSMetalView: picture in picture %s\n", pictureInPictureActive ? "activated" : "deactivated");
}

- (void)pictureInPictureWillStop
{
#if TARGET_OS_OSX
    [self logPictureInPictureStopGeometry:@"willStop-before"];
    // AVKit 的收起动画镜像源层，必须在动画开始前恢复播放器内的视频显示尺寸。
    // 先恢复 Metal 底图，避免源层几何变化及收起动画期间露出窗口底色。
    // PiP 仍持续喂帧，直到 didStop 才隐藏内容层。
    self.pictureInPictureStopping = YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.opacity = 1.0;
    [self updatePictureInPictureLayerFrame];
    // AVKit 后续布局会重置占位视图的位置，退出期间直接隐藏它。
    [self parkOffscreenPictureInPictureHostViewsInRoot:[self findPictureInPictureWindow].contentView];
    [CATransaction commit];
    // 暂停时没有新帧触发刷新，也要把保留的当前帧画回播放器。
    [self.renderSnapshotLock lock];
    self.previousTag = ~self.currentFrame.tag;
    [self.renderSnapshotLock unlock];
    [self displayCurrentFrameWithTimestamp:CACurrentMediaTime()];
    [self samplePictureInPictureStopGeometry:0];
#endif
}

- (void)updatePictureInPictureLayerFrame
{
    AVSampleBufferDisplayLayer *layer = self.pictureInPictureDisplayLayer;
    if (!layer) {
        return;
    }
#if TARGET_OS_OSX
    // 画中画激活期间，源层尺寸由 resizePictureInPictureSourceLayerTo: 按 PiP 面板大小控制，
    // willStop 后恢复播放器内的视频显示尺寸，供 AVKit 收起动画使用。
    if (self.pictureInPictureActive && !self.pictureInPictureStopping) {
        return;
    }
#endif
    UIView *container = self.pictureInPictureContainerView;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (container && !CGRectEqualToRect(container.frame, self.frame)) {
        container.frame = self.frame;
    }
    // AVKit can move the display layer into its own host. Only lay out our inline source.
    CALayer *containerLayer = container.layer;
    if (containerLayer && layer.superlayer == containerLayer) {
        CGRect target = containerLayer.bounds;
#if TARGET_OS_OSX
        // 启动和返回使用同一视频区域，避免启动瞬间把 view 的留黑边区域带入镜像。
        target = [self pictureInPictureInlineVideoRect:target];
#endif
        if (!CGRectEqualToRect(layer.frame, target)) {
            layer.frame = target;
        }
    }
    [CATransaction commit];
}

#if TARGET_OS_OSX

- (CGRect)pictureInPictureInlineVideoRect:(CGRect)bounds
{
    // 与 AVKit 使用同一份 sample buffer 格式，包含 clean aperture 与像素宽高比。
    // 整个 view 可能比视频宽；把它当源层尺寸会产生透明边，再被较窄的镜像宿主裁切。
    [self.renderSnapshotLock lock];
    CVPixelBufferRef buffer = self.currentFrame.videoPicture;
    if (buffer) CVPixelBufferRetain(buffer);
    [self.renderSnapshotLock unlock];
    if (!buffer) {
        return bounds;
    }
    CMVideoFormatDescriptionRef format = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, buffer, &format);
    CVPixelBufferRelease(buffer);
    if (status != noErr || !format) {
        return bounds;
    }
    CGSize size = CMVideoFormatDescriptionGetPresentationDimensions(format, true, true);
    CFRelease(format);
    if (size.width <= 0 || size.height <= 0 || !isfinite(size.width) || !isfinite(size.height)) {
        return bounds;
    }
    return AVMakeRectWithAspectRatioInsideRect(size, bounds);
}

- (void)logPictureInPictureStopGeometry:(NSString *)phase
{
    CALayer *source = self.pictureInPictureDisplayLayer;
    CALayer *presentation = source.presentationLayer;
    NSLog(@"[PiP-STOP] t=%.6f phase=%@ active=%d stopping=%d source=%@ bounds=%@ presentation=%@ super=%@ container=%@ metalOpacity=%.2f",
          CACurrentMediaTime(), phase, self.pictureInPictureActive, self.pictureInPictureStopping,
          NSStringFromRect(source.frame), NSStringFromRect(source.bounds),
          presentation ? NSStringFromRect(presentation.frame) : @"nil",
          NSStringFromClass(source.superlayer.class),
          NSStringFromRect(self.pictureInPictureContainerView.frame), self.layer.opacity);
    NSWindow *window = [self findPictureInPictureWindow];
    NSLog(@"[PiP-STOP] window=%@ content=%@", NSStringFromRect(window.frame),
          NSStringFromRect(window.contentView.bounds));
    if (window.contentView) {
        [self dumpViewTree:window.contentView depth:0];
    }
}

- (void)samplePictureInPictureStopGeometry:(NSUInteger)sample
{
    [self logPictureInPictureStopGeometry:[NSString stringWithFormat:@"animation-%lu", (unsigned long)sample]];
    if (!self.pictureInPictureStopping || sample >= 40) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf samplePictureInPictureStopGeometry:sample + 1];
    });
}

// macOS 画中画窗口尺寸修正。
// AVKit 把我们的 AVSampleBufferDisplayLayer 搬进它自建的 PiP 面板，用一个
// AVPictureInPictureCALayerHostView 承载，但只在面板初次出现时按视频原生尺寸布局一次，
// 之后不跟随窗口，也不按 videoGravity 缩放——于是画中画按 1:1 显示、只露出左上一块，
// 放大窗口才看到更多。下面反向修正该宿主视图，使其 autoresizing 跟随窗口。
// 依赖 AVKit 私有视图类名，属脆弱绕法；类名匹配失败时安全退出（恢复为原生 1:1 行为）。

- (void)schedulePictureInPictureWindowLayoutFixes
{
    // PiP 面板(PIPPanel)异步出现，且 4K/HDR 解码较重时 AVKit 要 ~2.5s 才建出内容视图树，
    // 固定短延迟(<1s)会全部跑在空视图树上而白做。改为有界轮询：每 0.2s 一次、最多 ~8s，
    // 直到成功找到并修正 DisplayLayer 视图后再多做 2 次收尾；退出 PiP 则停止。
    [self retryPictureInPictureWindowLayoutFix:0 appliedCount:0];
}

- (void)retryPictureInPictureWindowLayoutFix:(int)attempt appliedCount:(int)appliedCount
{
    if (!self.pictureInPictureActive || self.pictureInPictureStopping) {
        return;
    }
    BOOL applied = [self performPictureInPictureWindowLayoutFix];
    int newApplied = applied ? appliedCount + 1 : appliedCount;
    // 成功修正后再收尾 2 次（覆盖 AVKit 启动阶段可能的再次布局），然后停；
    // 一直没成功则最多重试 40 次(~8s)。之后的窗口 resize 由通知持续兜住。
    BOOL keepGoing = (newApplied > 0 && newApplied < 3) || (newApplied == 0 && attempt < 40);
    if (keepGoing) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self retryPictureInPictureWindowLayoutFix:attempt + 1 appliedCount:newApplied];
        });
    }
}

- (void)pictureInPictureHostWindowDidResize:(NSNotification *)notification
{
    if (!self.pictureInPictureActive) {
        return;
    }
    // 只在 AVKit 的 PiP 窗口 resize 时处理（忽略 App 自己的窗口）。
    NSWindow *window = notification.object;
    NSString *cls = NSStringFromClass([window class]);
    if ([cls localizedCaseInsensitiveContainsString:@"pip"] ||
        [cls localizedCaseInsensitiveContainsString:@"pictureinpicture"]) {
        if (self.pictureInPictureStopping) {
            // 返回动画会放大面板；只维护占位视图避让，不能再把源层改为面板尺寸。
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [self parkOffscreenPictureInPictureHostViewsInRoot:window.contentView];
            [CATransaction commit];
        } else {
            [self performPictureInPictureWindowLayoutFix];
        }
    }
}

// 返回 YES 表示本次确实找到并修正了至少一个承载视频的 DisplayLayer 视图。
- (BOOL)performPictureInPictureWindowLayoutFix
{
    if (!self.pictureInPictureActive || self.pictureInPictureStopping) {
        return NO;
    }
    NSWindow *pipWindow = [self findPictureInPictureWindow];
    NSView *contentView = pipWindow.contentView;
    if (!contentView) {
        return NO;
    }
    // 真实层级（实测）：
    //   contentView(跟随窗口)
    //     AVPictureInPictureSampleBufferDisplayLayerView   ← 卡在初始尺寸，不跟随窗口
    //       AVPictureInPictureSampleBufferDisplayLayerHostView(CALayerHost) ← 同样卡住，承载镜像内容
    //         AVPictureInPictureCALayerHostView            ← 停在上方的黑色占位视图
    // 承载视频的两层类名都含 "DisplayLayer"，黑色占位是 "CALayerHostView"（不含 "DisplayLayer"）。
    int fixed = [self fillPictureInPictureDisplayViews:contentView];
    [self parkOffscreenPictureInPictureHostViewsInRoot:contentView];
    // 关键：AVKit 只是用 CALayerHost 镜像我们的源层(contentLayer)，并不缩放镜像；把承载视图改小
    // 只会把原生尺寸的镜像裁掉。真正有效的是把源层本身缩放到 PiP 面板大小，镜像随之变小填满窗口。
    // 用面板 content view 的点尺寸，避免像素/点换算歧义。
    [self resizePictureInPictureSourceLayerTo:contentView.bounds.size];
    if (fixed > 0) {
        NSView *dv = [self firstDisplayLayerViewIn:contentView];
        NSLog(@"[PiP-DIAG] applied fix: fixedViews=%d contentView=%@ displayView=%@ sourceLayer=%@",
              fixed, NSStringFromRect(contentView.bounds),
              dv ? NSStringFromRect(dv.frame) : @"(none)",
              NSStringFromRect(self.pictureInPictureDisplayLayer.frame));
    }
    return fixed > 0;
}

// 把源 AVSampleBufferDisplayLayer 缩放到给定尺寸。AVKit 镜像的是这个层，缩小它，
// 画中画窗口里的镜像才会跟着缩小、按 videoGravity 填满窗口。
// 注意：
// 1) 只缩放内容层本身，不要动承载它的容器视图(pictureInPictureContainerView)——
//    容器贴在原播放器窗口里，改它的 frame 会让原窗口上的 PiP 占位图/按钮跟着偏移。
// 2) 镜像只取内容层的“尺寸”、不关心它在容器里的“位置”，因此把缩小后的层在容器里居中摆放：
//    PiP 窗口镜像照常填满，AVKit 画在原窗口上的“正在画中画”占位图也回到中间（放左下角
//    会导致占位图偏到左下）。
- (void)resizePictureInPictureSourceLayerTo:(CGSize)size
{
    if (size.width < 1 || size.height < 1) {
        return;
    }
    AVSampleBufferDisplayLayer *layer = self.pictureInPictureDisplayLayer;
    if (!layer) {
        return;
    }
    CGSize containerSize = self.pictureInPictureContainerView ? self.pictureInPictureContainerView.bounds.size : self.bounds.size;
    CGRect r = CGRectMake((containerSize.width - size.width) / 2.0,
                          (containerSize.height - size.height) / 2.0,
                          size.width, size.height);
    if (!CGRectEqualToRect(layer.frame, r)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layer.frame = r;
        [CATransaction commit];
    }
}

// 递归让所有承载视频的 DisplayLayer 视图填满各自父视图并开启 autoresize；返回修正的视图数。
// 先改父、再递归子，保证子视图读到的 superview.bounds 已是修正后的尺寸。
- (int)fillPictureInPictureDisplayViews:(NSView *)view
{
    int count = 0;
    for (NSView *sub in view.subviews) {
        NSString *cls = NSStringFromClass([sub class]);
        if ([cls containsString:@"DisplayLayer"]) {
            sub.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            NSRect target = sub.superview.bounds;
            if (!NSEqualRects(sub.frame, target)) {
                sub.frame = target;
            }
            sub.needsLayout = YES;
            // 同步 CALayerHost 宿主层几何 + contentsGravity，让镜像内容按新尺寸缩放而非裁切。
            if (sub.layer) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                if (!NSEqualRects(sub.layer.frame, target)) {
                    sub.layer.frame = target;
                }
                sub.layer.contentsGravity = kCAGravityResizeAspect;
                [CATransaction commit];
            }
            count++;
        }
        count += [self fillPictureInPictureDisplayViews:sub];
    }
    return count;
}

- (nullable NSView *)firstDisplayLayerViewIn:(NSView *)view
{
    for (NSView *sub in view.subviews) {
        if ([NSStringFromClass([sub class]) containsString:@"DisplayLayer"]) {
            return sub;
        }
        NSView *found = [self firstDisplayLayerViewIn:sub];
        if (found) {
            return found;
        }
    }
    return nil;
}

- (nullable NSWindow *)findPictureInPictureWindow
{
    for (NSWindow *w in [NSApplication sharedApplication].windows) {
        NSString *cls = NSStringFromClass([w class]);
        if ([cls localizedCaseInsensitiveContainsString:@"pip"] ||
            [cls localizedCaseInsensitiveContainsString:@"pictureinpicture"]) {
            return w;
        }
    }
    return nil;
}

// 一次性诊断：打印所有窗口与 PiP 面板子视图树（类名 + frame）+ 内容层几何。
- (void)dumpPictureInPictureHierarchy
{
    NSLog(@"[PiP-DIAG] ===== windows =====");
    for (NSWindow *w in [NSApplication sharedApplication].windows) {
        NSLog(@"[PiP-DIAG] window class=%@ frame=%@ visible=%d",
              NSStringFromClass([w class]), NSStringFromRect(w.frame), w.isVisible);
    }
    NSWindow *pipWindow = [self findPictureInPictureWindow];
    if (pipWindow.contentView) {
        NSLog(@"[PiP-DIAG] ----- PiP window(%@) view tree -----", NSStringFromClass([pipWindow class]));
        [self dumpViewTree:pipWindow.contentView depth:0];
    } else {
        NSLog(@"[PiP-DIAG] no PiP window matched (class name not containing pip/pictureinpicture)");
    }
    AVSampleBufferDisplayLayer *layer = self.pictureInPictureDisplayLayer;
    NSLog(@"[PiP-DIAG] contentLayer bounds=%@ frame=%@ gravity=%@ superlayer=%@",
          NSStringFromRect(layer.bounds), NSStringFromRect(layer.frame),
          layer.videoGravity, NSStringFromClass([layer.superlayer class]));
}

- (void)dumpViewTree:(NSView *)view depth:(int)depth
{
    NSMutableString *indent = [NSMutableString string];
    for (int i = 0; i < depth; i++) { [indent appendString:@"  "]; }
    NSLog(@"[PiP-DIAG] %@%@ frame=%@ autoresize=%lu layer=%@ bounds=%@ hidden=%d",
          indent, NSStringFromClass([view class]), NSStringFromRect(view.frame),
          (unsigned long)view.autoresizingMask,
          NSStringFromClass([view.layer class]),
          view.layer ? NSStringFromRect(view.layer.bounds) : @"(nil)", view.isHidden);
    for (NSView *sub in view.subviews) {
        [self dumpViewTree:sub depth:depth + 1];
    }
}

- (void)parkOffscreenPictureInPictureHostViewsInRoot:(NSView *)root
{
    for (NSView *sub in root.subviews) {
        NSString *cls = NSStringFromClass([sub class]);
        // 仅针对黑色占位视图 AVPictureInPictureCALayerHostView（含 "CALayerHostView" 且不含
        // "DisplayLayer"，以区别于上面承载视频的 DisplayLayerHostView）。它停在窗口上方、
        // origin.y > 0，窗口放大时会滑进可视区，这里把它移出视图范围。
        if ([cls containsString:@"CALayerHostView"] &&
            ![cls containsString:@"DisplayLayer"] &&
            (self.pictureInPictureStopping || sub.frame.origin.y > 0)) {
            if (self.pictureInPictureStopping) {
                // 日志确认 AVKit 会在 willStop 后把 y=718 重置为 y=350，
                // 而且没有后续窗口 resize 通知；隐藏不依赖这一几何布局。
                if (!sub.isHidden) {
                    if (!self.pictureInPictureHiddenPlaceholders) {
                        self.pictureInPictureHiddenPlaceholders = [NSHashTable weakObjectsHashTable];
                    }
                    [self.pictureInPictureHiddenPlaceholders addObject:sub];
                    sub.hidden = YES;
                }
            } else {
                CGRect f = sub.frame;
                f.origin.y = root.bounds.size.height + 10;
                if (!CGRectEqualToRect(sub.frame, f)) {
                    sub.frame = f;
                }
            }
        }
        [self parkOffscreenPictureInPictureHostViewsInRoot:sub];
    }
}

#endif



/// 是否需要把当前帧喂给画中画内容层：预热期或画中画运行期间。
- (BOOL)shouldFeedPictureInPicture
{
    if (!self.pictureInPictureDisplayLayer || !self.pictureInPictureFeedEnabled) {
        return NO;
    }
    if (self.pictureInPictureActive) {
        return YES;
    }
    if (self.pictureInPictureWarmFrames > 0) {
        self.pictureInPictureWarmFrames--;
        return YES;
    }
    return NO;
}

- (void)updatePictureInPictureTimebaseWithTime:(NSTimeInterval)time rate:(float)rate
{
    CMTimebaseRef timebase = self.pictureInPictureTimebase;
    if (!timebase) {
        return;
    }
    // 设定锚点时间后，timebase 会按给定 rate 自行随墙钟推进，画中画进度条自动前进，
    // 无需逐帧更新；只在播放/暂停/seek/结束等状态变化时同步即可。
    if (time >= 0 && isfinite(time)) {
        CMTimebaseSetTime(timebase, CMTimeMakeWithSeconds(time, 600));
    }
    CMTimebaseSetRate(timebase, rate);
}

/// 用 Metal 渲染的同一个 CVPixelBuffer 生成 CMSampleBuffer 喂给画中画层。
/// displayW/displayH 为该帧的有效显示尺寸（disp_w/disp_h），用于裁掉解码缓冲的
/// 对齐 padding。时间戳取宿主时钟 + DisplayImmediately（等价于直播源），层内不再
/// 排队缓冲，画中画窗口延迟 ≈ 一帧。
- (void)enqueuePictureInPictureSampleBuffer:(CVPixelBufferRef)pixelBuffer
                               displayWidth:(int)displayW
                              displayHeight:(int)displayH
{
    AVSampleBufferDisplayLayer *layer = self.pictureInPictureDisplayLayer;
    if (!layer || !pixelBuffer) {
        return;
    }
    if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        ALOGW("FSMetalView: picture in picture layer failed:%@, flush\n", layer.error);
        [layer flush];
    }

    // VideoToolbox 解码缓冲区常有对齐 padding（如编码宽 1088 对齐自显示宽 1080，macOS 上
    // 对齐更激进，编码宽可能远大于显示宽）。若缓冲没有附加 clean aperture，
    // AVSampleBufferDisplayLayer 会把 padding 区域一同当作视频显示，导致画面不完整。
    // 有效画面在缓冲的左上角（padding 在右/下）。
    int validW = displayW;
    int validH = displayH;

    size_t bufferW = CVPixelBufferGetWidth(pixelBuffer);
    size_t bufferH = CVPixelBufferGetHeight(pixelBuffer);
    if (validW > 0 && validH > 0 && (validW < (int)bufferW || validH < (int)bufferH)) {
        CFDictionaryRef cleanAperture = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferCleanApertureKey, NULL);
        if (!cleanAperture) {
            // clean aperture 的 offset 是“裁剪区中心相对编码帧中心”的偏移：0 表示居中裁剪。
            // 有效画面在左上角，必须把裁剪区中心向左上推 padding 的一半（负偏移），否则会
            // 左/上切掉真实画面、右/下带进 padding（画面不完整/错位）。
            NSDictionary *dict = @{
                (id)kCVImageBufferCleanApertureWidthKey: @(validW),
                (id)kCVImageBufferCleanApertureHeightKey: @(validH),
                (id)kCVImageBufferCleanApertureHorizontalOffsetKey: @((validW - (int)bufferW) / 2.0),
                (id)kCVImageBufferCleanApertureVerticalOffsetKey: @((validH - (int)bufferH) / 2.0)
            };
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferCleanApertureKey, (__bridge CFDictionaryRef)dict, kCVAttachmentMode_ShouldPropagate);
        } else {
            CFRelease(cleanAperture);
        }
    }

    CMVideoFormatDescriptionRef formatDesc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);
    if (status != noErr || formatDesc == NULL) {
        ALOGW("FSMetalView: picture in picture create format desc failed:%d\n", (int)status);
        return;
    }
    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer, formatDesc, &timing, &sampleBuffer);
    if (status == noErr && sampleBuffer) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
        if (attachments && CFArrayGetCount(attachments) > 0) {
            CFMutableDictionaryRef attachment = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        }
        [layer enqueueSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    } else {
        ALOGW("FSMetalView: picture in picture create sample buffer failed:%d\n", (int)status);
    }
    CFRelease(formatDesc);
}

#endif


- (void)drawRect:(NSRect)dirtyRect
{
#if !TARGET_OS_TV
    // PiP 退出动画期间恢复 inline 渲染，作为动画下方的完整底图。
    if (self.pictureInPictureActive && !self.pictureInPictureStopping) {
        return;
    }
#endif
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

    FSMetalRenderFrame *currentFrame = self.drawingFrame;

    [self rebuildBackgroundTextureIfNeed];

    //Clean Background Color
    if (!currentFrame.videoPicture) {
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

    if (![currentFrame prepareTexturesWithDevice:self.device textureCache:self.pictureTextureCache]) {
        [self.renderSnapshotLock unlock];
        return;
    }
    
    if (self.displayDelegate && [self.displayDelegate respondsToSelector:@selector(videoRenderingDidDisplay:attach:)]) {
        [self.displayDelegate videoRenderingDidDisplay:self attach:currentFrame];
    }
    
    //draw textures
    CGSize drawableSize = self.drawableSize;

    CGSize ratio = [self computeNormalizedVerticesRatio:currentFrame drawableSize:drawableSize];

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
    
    [self encodePicture:currentFrame
          renderEncoder:renderEncoder
           drawableSize:drawableSize
                  ratio:ratio];
    
    if (currentFrame.subTexture) {
        [self encodeSubtitle:renderEncoder
                drawableSize:drawableSize
                     texture:currentFrame.subTexture];
    }
    //[renderEncoder popDebugGroup];
    [renderEncoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    // Extend the lifetime of currentAttach until the GPU finishes rendering.
    // This prevents the underlying CVPixelBuffer from being returned to the pool
    // and recycled/overwritten by the decoder too early, especially at high playback speeds.
    __block FSMetalRenderFrame *keepAliveAttach = currentFrame;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull buf) {
        keepAliveAttach = nil;
    }];
    // Finalize rendering here & push the command buffer to the GPU.
    [commandBuffer commit];
    self.previousTag = currentFrame.tag;

    [self.renderSnapshotLock unlock];
}

#pragma mark - snapshot

- (CGImageRef)_snapshotWithSubtitle:(BOOL)drawSub
{
    [self.renderSnapshotLock lock];

    FSMetalRenderFrame *currentFrame = self.currentFrame;
    CVPixelBufferRef pixelBuffer = currentFrame.videoPicture;
    if (!pixelBuffer) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }
    
    if (!self.offscreenRendering) {
        self.offscreenRendering = [FSMetalOffscreenRendering alloc];
    }
    float width  = currentFrame.w;
    float height = currentFrame.h;
    
    //keep video AVRational
    if (currentFrame.sarNum > 0 && currentFrame.sarDen > 0) {
        width = 1.0 * currentFrame.sarNum / currentFrame.sarDen * width;
    }
    
    float darRatio = self.darPreference.ratio;
    
    int zDegrees = 0;
    zDegrees += (int)self.zRotateDegrees;
    zDegrees += currentFrame.autoZRotate;
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
    if (![self setupPipelineIfNeed:currentFrame.videoPicture blend:currentFrame.hasAlpha]) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }

    if (drawSub && currentFrame.subTexture && ![self setupSubPipelineIfNeed]) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }

    // FSMetalFBO render target is always BGRA8Unorm; HDR pipelines use RGBA16Float.
    // Use a temporary SDR pipeline for the snapshot so pixel formats match.
    // (Snapshots are saved as SDR image files, so tone-mapping is correct here.)
    FSMetalRenderer *savedPipeline = nil;
#if !TARGET_OS_TV
    if (@available(iOS 16.0, *)) {
        if (self.directDisplayHDRSupported) {
            savedPipeline = self.picturePipeline;
            FSMetalRenderer *sdrPipeline = [[FSMetalRenderer alloc] initWithDevice:self.device colorPixelFormat:MTLPixelFormatBGRA8Unorm];
            FSMetalPipelineMeta *meta = [FSMetalPipelineMeta createWithCVPixelbuffer:currentFrame.videoPicture];
            if (![sdrPipeline createRenderPipelineIfNeed:meta blend:currentFrame.hasAlpha]) {
                [self.renderSnapshotLock unlock];
                return NULL;
            }
            self.pipelineMeta = meta;
            self.picturePipeline = sdrPipeline;
        }
    } else {
        // Fallback on earlier versions
    }
#endif

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    CGImageRef result = [self.offscreenRendering snapshot:viewport device:self.device commandBuffer:commandBuffer doUploadPicture:^(id<MTLRenderCommandEncoder> _Nonnull renderEncoder) {

        [self encodePicture:currentFrame
              renderEncoder:renderEncoder
               drawableSize:viewport
                      ratio:CGSizeMake(1.0, 1.0)];

        if (drawSub && currentFrame.subTexture) {
            [self encodeSubtitle:renderEncoder
                    drawableSize:viewport
                         texture:currentFrame.subTexture];
        }
    }];
    if (savedPipeline) {
        self.picturePipeline = savedPipeline;
    }
    [self.renderSnapshotLock unlock];
    return result;
}

//not support heic tile grid
- (CGImageRef)_snapshotOrigin:(FSMetalRenderFrame *)attach
{
    if (!attach.videoPicture) {
        return NULL;
    }
    CVPixelBufferRef pixelBuffer = CVPixelBufferRetain(attach.videoPicture);
    //[CIImage initWithCVPixelBuffer:options:] failed because its pixel format f420 is not supported.
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (!ciImage) {
        CVPixelBufferRelease(pixelBuffer);
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

    FSMetalRenderFrame *currentFrame = self.currentFrame;
    CVPixelBufferRef pixelBuffer = currentFrame.videoPicture;
    if (!pixelBuffer) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }

    if (![currentFrame prepareTexturesWithDevice:self.device textureCache:self.pictureTextureCache]) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }

    if (!self.offscreenRendering) {
        self.offscreenRendering = [FSMetalOffscreenRendering alloc];
    }

    if (![self setupPipelineIfNeed:currentFrame.videoPicture blend:currentFrame.hasAlpha]) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }

    if (currentFrame.subTexture && ![self setupSubPipelineIfNeed]) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }

    // FSMetalFBO render target is always BGRA8Unorm; HDR pipelines use RGBA16Float.
    // Use a temporary SDR pipeline for the snapshot so pixel formats match.
    FSMetalRenderer *savedPipeline = nil;
#if !TARGET_OS_TV
    if (@available(iOS 16.0, *)) {
        if (self.directDisplayHDRSupported) {
            savedPipeline = self.picturePipeline;
            FSMetalRenderer *sdrPipeline = [[FSMetalRenderer alloc] initWithDevice:self.device colorPixelFormat:MTLPixelFormatBGRA8Unorm];
            FSMetalPipelineMeta *meta = [FSMetalPipelineMeta createWithCVPixelbuffer:currentFrame.videoPicture];
            if (![sdrPipeline createRenderPipelineIfNeed:meta  blend:currentFrame.hasAlpha]) {
                [self.renderSnapshotLock unlock];
                return NULL;
            }
            self.pipelineMeta = meta;
            self.picturePipeline = sdrPipeline;
        }
    } else {
        // Fallback on earlier versions
    }
#endif

    CGSize drawableSize = self.drawableSize;
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    CGImageRef result = [self.offscreenRendering snapshot:drawableSize device:self.device commandBuffer:commandBuffer doUploadPicture:^(id<MTLRenderCommandEncoder> _Nonnull renderEncoder) {
        CGSize ratio = [self computeNormalizedVerticesRatio:currentFrame drawableSize:drawableSize];
        [self encodePicture:currentFrame
              renderEncoder:renderEncoder
               drawableSize:drawableSize
                      ratio:ratio];

        if (currentFrame.subTexture) {
            [self encodeSubtitle:renderEncoder
                    drawableSize:drawableSize
                         texture:currentFrame.subTexture];
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
            return [self _snapshotOrigin:self.currentFrame];
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
#else

#endif

#pragma mark - Property Setters & Informational Getters

- (void)setScalingMode:(FSScalingMode)scalingMode
{
    if (_scalingMode != scalingMode) {
        _scalingMode = scalingMode;
        [self setNeedsRefreshCurrentPic];
    }
}

- (void)setXRotateDegrees:(float)xRotateDegrees
{
    if (_xRotateDegrees != xRotateDegrees) {
        _xRotateDegrees = xRotateDegrees;
        [self setNeedsRefreshCurrentPic];
    }
}

- (void)setYRotateDegrees:(float)yRotateDegrees
{
    if (_yRotateDegrees != yRotateDegrees) {
        _yRotateDegrees = yRotateDegrees;
        [self setNeedsRefreshCurrentPic];
    }
}

- (void)setZRotateDegrees:(float)zRotateDegrees
{
    if (_zRotateDegrees != zRotateDegrees) {
        _zRotateDegrees = zRotateDegrees;
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
    [self setBackgroundColor:r g:g b:b transparent:NO];
}

- (void)setBackgroundColor:(uint8_t)r g:(uint8_t)g b:(uint8_t)b transparent:(BOOL)transparent
{
    [self.renderSnapshotLock lock];
    _requestedBackgroundColor = (MTLClearColor){r/255.0, g/255.0, b/255.0, transparent ? 0.0 : 1.0};
    FSMetalRenderFrame *frame = self.currentFrame;
    [self.renderSnapshotLock unlock];
    [self updateBackgroundTransparencyForFrame:frame force:YES];
    [self setNeedsRefreshCurrentPic];
}

- (void)setAutoTransparentBackgroundColor:(BOOL)enabled
{
    [self.renderSnapshotLock lock];
    BOOL changed = _autoTransparentBackgroundColor != enabled;
    _autoTransparentBackgroundColor = enabled;
    FSMetalRenderFrame *frame = self.currentFrame;
    [self.renderSnapshotLock unlock];
    if (!changed) return;
    [self updateBackgroundTransparencyForFrame:frame force:NO];
    [self setNeedsRefreshCurrentPic];
}

- (void)updateBackgroundTransparencyForFrame:(FSMetalRenderFrame *)frame force:(BOOL)force
{
    [self.renderSnapshotLock lock];
    BOOL automatic = _autoTransparentBackgroundColor && frame.hasAlpha;
    BOOL transparent = _requestedBackgroundColor.alpha == 0.0 || automatic;
    BOOL unchanged = self.automaticBackgroundTransparencyActive == automatic &&
                     self.backgroundTransparencyApplied == transparent;
    [self.renderSnapshotLock unlock];
    if (!force && unchanged) return;

    void (^update)(void) = ^{
        [self.renderSnapshotLock lock];
        // Recheck settings in case the caller changed them while the render thread waited.
        BOOL autoTransparent = self->_autoTransparentBackgroundColor && frame.hasAlpha;
        MTLClearColor color = self->_requestedBackgroundColor;
        BOOL isTransparent = color.alpha == 0.0 || autoTransparent;
        // Transparent drawables use premultiplied alpha: RGB must also be zero.
        color = isTransparent ? (MTLClearColor){0.0, 0.0, 0.0, 0.0} : color;
        color.alpha = isTransparent ? 0.0 : 1.0;
        self.clearColor = color;
        self.automaticBackgroundTransparencyActive = autoTransparent;
        self.backgroundTransparencyApplied = isTransparent;
        self.needCleanBackgroundColor = YES;
        [self.renderSnapshotLock unlock];

        self.layer.opaque = !isTransparent;
#if !TARGET_OS_OSX
        self.opaque = !isTransparent;
        self.backgroundColor = isTransparent ? UIColor.clearColor :
            [UIColor colorWithRed:color.red green:color.green blue:color.blue alpha:1.0];
#endif
    };
    if ([NSThread isMainThread]) {
        update();
    } else {
        dispatch_sync(dispatch_get_main_queue(), update);
    }
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

#pragma mark - OS Event Notifications & Layout
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

- (void)resizeWithOldSuperviewSize:(NSSize)oldSize
{
    [super resizeWithOldSuperviewSize:oldSize];
    [self setNeedsRefreshCurrentPic];
    [self updatePictureInPictureLayerFrame];
}

#else

- (void)layoutSubviews
{
    [super layoutSubviews];
    
    if (!CGSizeEqualToSize(self.drawableSize, self.preferredDrawableSize)) {
        [self setNeedsRefreshCurrentPic];
    }
#if !TARGET_OS_TV
    [self updatePictureInPictureLayerFrame];
#endif
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    return NO;
}

- (void)applicationDidEnterBackground {
    self.isEnterBackground = YES;
    _displayLinkWrapper.paused = YES;
}

- (void)applicationWillEnterForeground {
    self.isEnterBackground = NO;
    _displayLinkWrapper.paused = NO;
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

@end
