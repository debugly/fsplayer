//
//  FSMetalTileGridPipeline.m
//  FSPlayer
//
//  Created by debugly on 2026/6/16.
//

#import "FSMetalTileGridPipeline.h"
#import "FSMetalRenderer.h"
#import "FSMetalPipelineMeta.h"
#import "FSMetalFBO.h"
#import "FSMetalTextureUtils.h"
#import "FSVideoRenderingProtocol.h"
#import "../apple/ijk_cvpixelbuffer.h"
#include "../ijksdl_log.h"

@interface FSMetalTileGridPipeline ()
{
    id<MTLDevice> _device;
    // 最近一次合成结果，调用方将其交给 attach 持有；刷新直接复用 attach。
    CVPixelBufferRef _cachedComposite;     // 纹理的后备缓冲
    id<MTLTexture> _cachedTexture;         // 可直接采样显示的合成纹理
    NSArray *_cachedCVTextures;            // 对应的 CVMetalTextureRef 包装引用
}
// tile 像素格式（YUV/NV12...）-> BGRA 的转换管线，像素格式变化时重建。
@property (nonatomic, strong) FSMetalRenderer *renderer;
@end

@implementation FSMetalTileGridPipeline

- (instancetype)initWithDevice:(id<MTLDevice>)device
{
    self = [super init];
    if (self) {
        NSAssert(device, @"device can't be nil!");
        _device = device;
    }
    return self;
}

- (void)dealloc
{
    if (_cachedComposite) {
        CVPixelBufferRelease(_cachedComposite);
        _cachedComposite = NULL;
    }
    if (_cachedCVTextures) {
        for (id item in _cachedCVTextures) {
            CVMetalTextureRef texRef = (__bridge CVMetalTextureRef)item;
            if (texRef) {
                CFRelease(texRef);
            }
        }
        _cachedCVTextures = nil;
    }
}

- (CVPixelBufferRef)compositedPixelBuffer
{
    return _cachedComposite;
}

// 一次性打印 tile 的颜色元数据，用于排查色差（range/matrix/transfer/colorspace）。
- (void)logColorInfo:(CVPixelBufferRef)pb
{
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    char fcc[5] = {0};
    fcc[0] = (fmt >> 24) & 0xFF; fcc[1] = (fmt >> 16) & 0xFF;
    fcc[2] = (fmt >> 8) & 0xFF;  fcc[3] = fmt & 0xFF;

    CFStringRef matrix    = CVBufferGetAttachment(pb, kCVImageBufferYCbCrMatrixKey, NULL);
    CFStringRef primaries = CVBufferGetAttachment(pb, kCVImageBufferColorPrimariesKey, NULL);
    CFStringRef transfer  = CVBufferGetAttachment(pb, kCVImageBufferTransferFunctionKey, NULL);
    // CVImageBufferGetColorSpace 仅 macOS 可用；iOS 上 colorspace 以 attachment 形式存放。
    CGColorSpaceRef cs    = (CGColorSpaceRef)CVBufferGetAttachment(pb, kCVImageBufferCGColorSpaceKey, NULL);
    CFStringRef csName    = cs ? CGColorSpaceGetName(cs) : NULL;

    ALOGD("HEIC TileGrid fmt=%s(0x%08x) matrix=%s primaries=%s transfer=%s colorspace=%s\n",
          fcc, (unsigned)fmt,
          matrix    ? [(__bridge NSString *)matrix    UTF8String] : "(nil)",
          primaries ? [(__bridge NSString *)primaries UTF8String] : "(nil)",
          transfer  ? [(__bridge NSString *)transfer  UTF8String] : "(nil)",
          csName    ? [(__bridge NSString *)csName    UTF8String] : "(nil)");
}

- (BOOL)setupRendererIfNeed:(CVPixelBufferRef)refPixelBuffer hasAlpha:(BOOL)hasAlpha
{
    if (self.renderer && [self.renderer matchPixelBuffer:refPixelBuffer]) {
        return YES;
    }
    // 目标是 BGRA FBO，所以 colorPixelFormat 固定为 BGRA8Unorm。
    FSMetalRenderer *renderer = [[FSMetalRenderer alloc] initWithDevice:_device
                                                      colorPixelFormat:MTLPixelFormatBGRA8Unorm];
    FSMetalPipelineMeta *meta = [FSMetalPipelineMeta createWithCVPixelbuffer:refPixelBuffer];
    if (![renderer createRenderPipelineIfNeed:meta blend:hasAlpha]) {
        ALOGE("create tile grid renderer failed.");
        return NO;
    }
    self.renderer = renderer;
    return YES;
}

- (id<MTLTexture>)compositeTileGrid:(FSOverlayAttach *)attach
                       textureCache:(CVMetalTextureCacheRef)textureCache
                       commandQueue:(id<MTLCommandQueue>)commandQueue
{
    if (attach.tilePieces.count == 0) {
        return nil;
    }

    int canvasW = attach.w;
    int canvasH = attach.h;
    if (canvasW <= 0 || canvasH <= 0) {
        return nil;
    }

    // Only a new attach reaches composition; refreshAttach: reuses its existing texture.
    for (FSTilePiece *piece in attach.tilePieces) {
        if (!piece.pixelBuffer && piece.avframe) {
            AVFrame *frame = piece.avframe;
            if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
                CVPixelBufferRef pb = (CVPixelBufferRef)frame->data[3];
                piece.pixelBuffer = pb ? CVPixelBufferRetain(pb) : NULL;
            } else {
                piece.pixelBuffer = FSCVPixelBufferCreateFromAVFrame(frame, NULL);
            }
        }
        if (!piece.pixelBuffer) return nil;
    }
    CVPixelBufferRef ref = ((FSTilePiece *)attach.tilePieces.firstObject).pixelBuffer;

    [self logColorInfo:ref];
    
    if (![self setupRendererIfNeed:ref hasAlpha:attach.hasAlpha]) {
        return nil;
    }

    // 每次合成独占一份 pixelBuffer，FBO 不复用，避免覆盖已缓存的画面。
    FSMetalFBO *fbo = [[FSMetalFBO alloc] init:_device size:CGSizeMake(canvasW, canvasH)];
    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [fbo createRenderEncoder:commandBuffer];
    if (!encoder) {
        return nil;
    }

    // 合成阶段：不旋转、不调色、铺满整图、顶点不缩放（旋转/调色留给显示阶段作用于整张图）。
    self.renderer.autoZRotateDegrees = 0;
    self.renderer.xRotateDegrees = 0;
    self.renderer.yRotateDegrees = 0;
    self.renderer.zRotateDegrees = 0;
    [self.renderer updateColorAdjustment:(vector_float4){1.0, 1.0, 1.0, 0.0}];
    self.renderer.vertexRatio = CGSizeMake(1.0, 1.0);

    double display_w = canvasW;
    double display_h = canvasH;

    // 渲染各 tile 到一张大图上，由于后续不会再渲染，所以中间过程无需缓存。
    for (FSTilePiece *piece in attach.tilePieces) {
        if (!piece.pixelBuffer || piece.w <= 0 || piece.h <= 0) continue;

        // 边缘处理：位于最右/最下的 Tile 物理尺寸可能含 Padding，
        // 取实际显示区域并据此确定 Viewport 与纹理裁剪区域。
        double valid_w = piece.w;
        if (piece.x + piece.w > display_w) {
            valid_w = display_w - piece.x;
        }
        double valid_h = piece.h;
        if (piece.y + piece.h > display_h) {
            valid_h = display_h - piece.y;
        }
        if (valid_w <= 0 || valid_h <= 0) continue;

        NSArray *textures = [FSMetalTextureUtils doGenerateTexture:piece.pixelBuffer
                                                      textureCache:textureCache
                                                            device:_device];
        if (!textures) continue;

        // FBO 视口原点左上、y 向下，和 tile 在 canvas 的像素位置一致。
        MTLViewport tile_vp;
        tile_vp.originX = piece.x;
        tile_vp.originY = piece.y;
        tile_vp.width   = valid_w;
        tile_vp.height  = valid_h;
        tile_vp.znear   = -1.0;
        tile_vp.zfar    =  1.0;

        // textureCrop 为需要减去的百分比：比如 Tile 宽 512、有效 392，则剪掉 (512-392)/512。
        float cropX = (float)(piece.w - valid_w) / piece.w;
        float cropY = (float)(piece.h - valid_h) / piece.h;
        self.renderer.textureCrop = CGSizeMake(cropX, cropY);

        [encoder setViewport:tile_vp];
        [self.renderer uploadTextureWithEncoder:encoder textures:textures];
    }
    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    // 从合成后的 BGRA 缓冲生成一张可采样显示的纹理（与显示路径采样方式一致）。
    CVPixelBufferRef composed = [fbo pixelBuffer];
    NSMutableArray *cvTextures = nil;
    id<MTLTexture> texture = [FSMetalTextureUtils doGenerateTexture:composed textureCache:textureCache device:_device outCVTextures:&cvTextures].firstObject;
    if (!texture) {
        return nil;
    }

    // 保存本次合成结果，供调用方交给 attach；替换时释放上次结果。
    if (_cachedComposite) {
        CVPixelBufferRelease(_cachedComposite);
    }
    if (_cachedCVTextures) {
        for (id item in _cachedCVTextures) {
            CVMetalTextureRef texRef = (__bridge CVMetalTextureRef)item;
            if (texRef) {
                CFRelease(texRef);
            }
        }
        _cachedCVTextures = nil;
    }
    _cachedComposite = CVPixelBufferRetain(composed);
    _cachedTexture = texture;
    _cachedCVTextures = cvTextures;

    return texture;
}

@end
