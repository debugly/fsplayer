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

#import "ijksdl_vout_ios_gles2.h"
#import "FSMediaPlayback.h"
#import "FSDisplayLinkWrapper.h"

#if TARGET_OS_IOS || TARGET_OS_TV
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
@property (nonatomic, strong) FSDisplayLinkWrapper *displayLinkWrapper;
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
    [_displayLinkWrapper invalidate];
    _displayLinkWrapper = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
#if TARGET_CPU_ARM64
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
}

#if TARGET_OS_OSX
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [_displayLinkWrapper updateWithWindow:self.window];
}

- (void)windowDidChangeScreen:(NSNotification *)notification {
    NSWindow *window = notification.object;
    if (window == self.window) {
        [_displayLinkWrapper updateWithWindow:window];
    }
}
#endif

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
         drawableSize:(CGSize)drawableSize
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

- (void)sendHDRAnimationNotifiOnMainThread:(int)state
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FSPlayerHDRAnimationStateChanged object:self userInfo:@{@"state":@(state)}];
    });
}

// 计算 canvas 在 drawable 中按 scalingMode + sar + rotate 贴合后的目标矩形 (viewport 坐标系, origin 左下)
- (MTLViewport)computeCanvasViewport:(CGSize)drawableSize
                               ratio:(CGSize)ratio
{
    // 这里复用 encodePicture 的思路：顶点用 [-ratio.w,+ratio.w] × [-ratio.h,+ratio.h]
    // 最终映射到 [0,drawable.w]×[0,drawable.h]。直接按 ratio 算 canvas 在屏幕的矩形。
    double cw = drawableSize.width  * ratio.width;
    double ch = drawableSize.height * ratio.height;
    double cx = (drawableSize.width  - cw) * 0.5;
    double cy = (drawableSize.height - ch) * 0.5;
    return (MTLViewport){cx, cy, cw, ch, -1.0, 1.0};
}

- (void)encodeTilePieces:(FSOverlayAttach *)attach
           renderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder
            drawableSize:(CGSize)drawableSize
                   ratio:(CGSize)ratio
           hdrPercentage:(float)hdrPercentage
{
    self.picturePipeline.hdrPercentage = hdrPercentage;
    self.picturePipeline.autoZRotateDegrees = attach.autoZRotate;
    self.picturePipeline.rotateType = self.rotatePreference.type;
    self.picturePipeline.rotateDegrees = self.rotatePreference.degrees;

    bool applyAdjust = _colorPreference.brightness != 1.0 || _colorPreference.saturation != 1.0 || _colorPreference.contrast != 1.0;
    [self.picturePipeline updateColorAdjustment:(vector_float4){_colorPreference.brightness,_colorPreference.saturation,_colorPreference.contrast,applyAdjust ? 1.0 : 0.0}];
    // tile 绘制：顶点全屏、不裁剪（每个 tile 视口就是它在 canvas 的对应位置）
    self.picturePipeline.vertexRatio = CGSizeMake(1.0, 1.0);
    
    // 先算出合并后区域在屏幕上的目标矩形
    MTLViewport display_vp = [self computeCanvasViewport:drawableSize ratio:ratio];
    
    //canvas=3584x2560   (pixelW,pixelH)
    //display=3464x2130 （w,h）
    
    double display_w = attach.w;
    double display_h = attach.h;
    
    CVMetalTextureCacheRef textureCache = NULL;
#if TARGET_CPU_ARM64
    textureCache = _pictureTextureCache;
#endif
    
    for (FSTilePiece *piece in attach.tilePieces) {
        if (!piece.pixelBuffer || piece.w <= 0 || piece.h <= 0) continue;
        if (!piece.textures) {
            piece.textures = [[self class] doGenerateTexture:piece.pixelBuffer
                                                textureCache:textureCache
                                                      device:self.device];
        }
        if (!piece.textures) continue;

        // 边缘处理：如果这个 Tile 位于最右边或最下面，它的物理尺寸可能包含了 Padding
        // 我们需要通过计算实际的显示区域，然后确定出一个 Viewport，和纹理的裁剪区域
        double valid_w = piece.w;
        if (piece.x + piece.w > display_w) {
            valid_w = display_w - piece.x;
        }
        
        double valid_h = piece.h;
        if (piece.y + piece.h > display_h) {
            valid_h = display_h - piece.y;
        }
        
        // tile 在 显示尺寸 上的归一化位置
        double nx = (double)piece.x / display_w;
        double ny = (double)piece.y / display_h;
        double nw = (double)valid_w / display_w;
        double nh = (double)valid_h / display_h;
        
        // 映射到显示到屏幕的区域
        // 注意 Metal viewport 的原点在左上（y 向下），drawable 坐标同向，直接计算即可
        MTLViewport tile_vp;
        tile_vp.originX = display_vp.originX + nx * display_vp.width;
        tile_vp.originY = display_vp.originY + ny * display_vp.height;
        tile_vp.width   = nw * display_vp.width;
        tile_vp.height  = nh * display_vp.height;
        tile_vp.znear   = -1.0;
        tile_vp.zfar    =  1.0;

        // 计算该 Tile 纹理内部的裁剪比例
        // textureCrop 的定义是：需要减去的百分比
        // 比如 Tile 宽 512，有效 392，则需剪掉 (512-392)/512
        float cropX = (float)(piece.w - valid_w) / piece.w;
        float cropY = (float)(piece.h - valid_h) / piece.h;
        self.picturePipeline.textureCrop = CGSizeMake(cropX, cropY);

        [renderEncoder setViewport:tile_vp];
        [self.picturePipeline uploadTextureWithEncoder:renderEncoder textures:piece.textures];
    }
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
            [commandEncoder endEncoding];
            [commandBuffer presentDrawable:drawable];
            [commandBuffer commit];
            self.needCleanBackgroundColor = NO;
        }
        return;
    }
    
    [self.renderSnapshotLock lock];
    self.drawingAttach = nil;

    // pipeline 需要一个参考 pixelBuffer（用第一个 tile 的）
    CVPixelBufferRef pipelineRef = currentAttach.videoPicture;
    if (!pipelineRef && hasTileGrid) {
        pipelineRef = ((FSTilePiece *)currentAttach.tilePieces.firstObject).pixelBuffer;
    }

    if (![self setupPipelineIfNeed:pipelineRef blend:currentAttach.hasAlpha]) {
        [self.renderSnapshotLock unlock];
        return;
    }
    
    if (currentAttach.subTexture && ![self setupSubPipelineIfNeed]) {
        [self.renderSnapshotLock unlock];
        return;
    }

    //generate textures (single-frame path)
    if (!hasTileGrid && !currentAttach.videoTextures) {
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

    if (hasTileGrid) {
        [self encodeTilePieces:currentAttach
                 renderEncoder:renderEncoder
                  drawableSize:drawableSize
                         ratio:ratio
                 hdrPercentage:hdrPer];
    } else {
        [self encodePicture:currentAttach
              renderEncoder:renderEncoder
               drawableSize:drawableSize
                      ratio:ratio
              hdrPercentage:hdrPer];
    }
    
    if (currentAttach.subTexture) {
        [self encodeSubtitle:renderEncoder
                drawableSize:drawableSize
                     texture:currentAttach.subTexture];
    }
    //[renderEncoder popDebugGroup];
    [renderEncoder endEncoding];
    //[commandBuffer presentDrawable:drawable];
    [commandBuffer presentDrawable:drawable];
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
    // pipeline 需要一个参考 pixelBuffer（用第一个 tile 的）
    CVPixelBufferRef pipelineRef = attach.videoPicture;
    if (!pipelineRef && hasTileGrid) {
        pipelineRef = ((FSTilePiece *)attach.tilePieces.firstObject).pixelBuffer;
    }
    if (![self setupPipelineIfNeed:pipelineRef blend:attach.hasAlpha]) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }
    
    if (drawSub && attach.subTexture && ![self setupSubPipelineIfNeed]) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }
    
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    CGImageRef result = [self.offscreenRendering snapshot:viewport device:self.device commandBuffer:commandBuffer doUploadPicture:^(id<MTLRenderCommandEncoder> _Nonnull renderEncoder) {
        
        if (hasTileGrid) {
            [self encodeTilePieces:attach
                     renderEncoder:renderEncoder
                      drawableSize:viewport
                             ratio:CGSizeMake(1.0, 1.0)
                     hdrPercentage:1.0];
        } else {
            if (!attach.videoTextures) {
                CVMetalTextureCacheRef textureCache = NULL;
            #if TARGET_CPU_ARM64
                textureCache = self.pictureTextureCache;
            #endif
                attach.videoTextures = [[self class] doGenerateTexture:attach.videoPicture textureCache:textureCache device:self.device];
            }
            
            [self encodePicture:attach
                  renderEncoder:renderEncoder
                   drawableSize:viewport
                          ratio:CGSizeMake(1.0, 1.0)
                  hdrPercentage:1.0];
        }
        if (drawSub && attach.subTexture) {
            [self encodeSubtitle:renderEncoder
                    drawableSize:viewport
                         texture:attach.subTexture];
        }
    }];
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
    
    // pipeline 需要一个参考 pixelBuffer（用第一个 tile 的）
    CVPixelBufferRef pipelineRef = attach.videoPicture;
    if (!pipelineRef && hasTileGrid) {
        pipelineRef = ((FSTilePiece *)attach.tilePieces.firstObject).pixelBuffer;
    }
    if (![self setupPipelineIfNeed:pipelineRef blend:attach.hasAlpha]) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }
    
    if (attach.subTexture && ![self setupSubPipelineIfNeed]) {
        [self.renderSnapshotLock unlock];
        return NULL;
    }
    
    CGSize drawableSize = self.drawableSize;
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    CGImageRef result = [self.offscreenRendering snapshot:drawableSize device:self.device commandBuffer:commandBuffer doUploadPicture:^(id<MTLRenderCommandEncoder> _Nonnull renderEncoder) {
        if (hasTileGrid) {
            [self encodeTilePieces:attach
                     renderEncoder:renderEncoder
                      drawableSize:drawableSize
                             ratio:CGSizeMake(1.0, 1.0)
                     hdrPercentage:1.0];
        } else {
            if (!attach.videoTextures) {
                CVMetalTextureCacheRef textureCache = NULL;
            #if TARGET_CPU_ARM64
                textureCache = self.pictureTextureCache;
            #endif
                attach.videoTextures = [[self class] doGenerateTexture:attach.videoPicture textureCache:textureCache device:self.device];
            }
            CGSize ratio = [self computeNormalizedVerticesRatio:attach drawableSize:drawableSize];
            [self encodePicture:attach
                  renderEncoder:renderEncoder
                   drawableSize:drawableSize
                          ratio:ratio
                  hdrPercentage:1.0];
        }
        
        if (attach.subTexture) {
            [self encodeSubtitle:renderEncoder
                    drawableSize:drawableSize
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
