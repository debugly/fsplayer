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
    FSSwPixelBufferPool _swPixelBufferPool; // Reused across software-decoded tiles.
    // 最近一次合成结果；视图独立持有需要复用的资源。
    FSMetalFBO *_compositedFBO; // 统一持有合成后的像素缓冲和纹理
}
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
    FSSwPixelBufferPoolRelease(&_swPixelBufferPool);
}

- (CVPixelBufferRef)compositedPixelBuffer
{
    return [_compositedFBO pixelBuffer];
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

- (id<MTLTexture>)compositeTileGrid:(NSArray<FSTilePiece *> *)tilePieces
                            canvasW:(int)canvasW
                            canvasH:(int)canvasH
                       textureCache:(CVMetalTextureCacheRef)textureCache
                       commandQueue:(id<MTLCommandQueue>)commandQueue
{
    if (tilePieces.count == 0 || canvasW <= 0 || canvasH <= 0) {
        return nil;
    }

    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    FSMetalFBO *fbo = [[FSMetalFBO alloc] init:_device size:CGSizeMake(canvasW, canvasH)];
    id<MTLRenderCommandEncoder> encoder = [fbo createRenderEncoder:commandBuffer];

    if (!encoder) {
        return nil;
    }

    double display_w = canvasW;
    double display_h = canvasH;

    // Keep converted tile buffers alive until GPU composition has completed.
    __attribute__((objc_precise_lifetime)) NSMutableArray *pixelBuffers =
        [NSMutableArray arrayWithCapacity:tilePieces.count];

    FSMetalRenderer *renderer = nil;
    // tile 像素格式（YUV/NV12...）-> BGRA
    for (FSTilePiece *piece in tilePieces) {
        if (piece.w <= 0 || piece.h <= 0) continue;

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

        AVFrame *frame = piece.avframe;
        CVPixelBufferRef pixelBuffer = NULL;
        if (frame && frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
            pixelBuffer = (CVPixelBufferRef)frame->data[3];
            if (pixelBuffer) CVPixelBufferRetain(pixelBuffer);
        } else if (frame) {
            CVPixelBufferPoolRef pool = FSSwPixelBufferPoolEnsure(&_swPixelBufferPool,
                                                                frame->width, frame->height, frame->format);
            pixelBuffer = FSCVPixelBufferCreateFromAVFrame(frame, pool);
        }
        if (!pixelBuffer) {
            [encoder endEncoding];
            return nil;
        }
        [pixelBuffers addObject:(__bridge_transfer id)pixelBuffer];
        if (!renderer) {
            [self logColorInfo:pixelBuffer];
            renderer = [[FSMetalRenderer alloc] initWithDevice:_device
                                              colorPixelFormat:MTLPixelFormatBGRA8Unorm];
            FSMetalPipelineMeta *meta = [FSMetalPipelineMeta createWithCVPixelbuffer:pixelBuffer];
            if (![renderer createRenderPipelineIfNeed:meta blend:NO]) {
                [encoder endEncoding];
                return nil;
            }
            renderer.vertexRatio = CGSizeMake(1.0, 1.0);
        }

        NSArray *textures = [FSMetalTextureUtils doGenerateTexture:pixelBuffer
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
        renderer.textureCrop = CGSizeMake(cropX, cropY);

        [encoder setViewport:tile_vp];
        [renderer uploadTextureWithEncoder:encoder textures:textures];
    }
    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    // FBO 已持有合成后的 BGRA 纹理，直接复用，无需再次包装像素缓冲。
    id<MTLTexture> texture = [fbo texture];
    if (!texture) {
        return nil;
    }

    // 每次合成保留独立 FBO；旧显示帧由视图持有其像素缓冲和纹理。
    _compositedFBO = fbo;

    return texture;
}

@end
