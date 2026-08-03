/*
 * FSVideoRenderingProtocol.h
 *
 * Copyright (c) 2017 Bilibili
 * Copyright (c) 2017 raymond <raymondzheng1412@gmail.com>
 * Copyright (c) 2019 debugly <qianlongxu@gmail.com>
 *
 * This file is part of FSPlayer.
 *
 * FSPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * FSPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FSPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#ifndef FSVideoRenderingProtocol_h
#define FSVideoRenderingProtocol_h

#import <TargetConditionals.h>
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#import <CoreGraphics/CGImage.h>
typedef NSFont UIFont;
typedef NSColor UIColor;
typedef NSImage UIImage;
typedef NSView UIView;
#else
#import <UIKit/UIKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FSScalingMode) {
    FSScalingModeAspectFit,  // Uniform scale until one dimension fits
    FSScalingModeAspectFill, // Uniform scale until the movie fills the visible bounds. One dimension may have clipped contents
    FSScalingModeFill        // Non-uniform scale. Both render dimensions will exactly match the visible bounds
};

typedef struct SDL_TextureOverlay SDL_TextureOverlay;

// HEIC tile grid: 单个 tile 的 CVPixelBuffer + 位置信息
@interface FSTilePiece : NSObject
@property(nonatomic) CVPixelBufferRef _Nullable pixelBuffer;    // 持有 (owned, Retain/Release by this class)
@property(nonatomic) int x;         // canvas 上左上角
@property(nonatomic) int y;
@property(nonatomic) int w;         // tile 尺寸
@property(nonatomic) int h;
@property(nonatomic) NSArray * _Nullable textures;              // 首次使用时生成并缓存
@end

@interface FSOverlayAttach : NSObject

//{w,h} is video frame normal size not alignmetn,maybe not equal to {pixelW,pixelH}.
@property(nonatomic) int w;
@property(nonatomic) int h;
//cvpixebuffer pixel memory size;
@property(nonatomic) int pixelW;
@property(nonatomic) int pixelH;

@property(nonatomic) float fps;
@property(nonatomic) int sarNum;
@property(nonatomic) int sarDen;
//degrees
@property(nonatomic) int autoZRotate;
@property(nonatomic) int hasAlpha;

@property(nonatomic) CVPixelBufferRef _Nullable videoPicture;
@property(nonatomic) NSArray * _Nullable videoTextures;

// HEIC tile grid：非空时表示此帧是多 tile 合成，渲染器需要按 tilePieces 的位置信息拼图。
@property(nonatomic) NSArray<FSTilePiece *> * _Nullable tilePieces;

@property(nonatomic) SDL_TextureOverlay * _Nullable overlay;
@property(nonatomic) id _Nullable subTexture;
@property(nonatomic) long tag;

@end

static inline uint32_t fs_ass_color_to_int(UIColor *color) {
#if TARGET_OS_OSX
    color = [color colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]] ?: color;
#endif
    CGFloat r,g,b,a;
    [color getRed:&r green:&g blue:&b alpha:&a];
    
    r *= 255;
    g *= 255;
    b *= 255;
    //in ass,0 means opaque
    a = 1-a;
    a *= 255;
    return (uint32_t)a + ((uint32_t)b << 8) + ((uint32_t)g << 16) + ((uint32_t)r << 24);
}

static inline UIColor * fs_ass_int_to_color(uint32_t rgba) {
    CGFloat r,g,b,a;
    a = 1 - (float)(rgba & 0xFF) / 255.0;
    b = (float)(rgba >> 8  & 0xFF) / 255.0;
    g = (float)(rgba >> 16 & 0xFF) / 255.0;
    r = (float)(rgba >> 24 & 0xFF) / 255.0;
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

typedef enum _FSSDLRotateType {
    FSRotateNone,
    FSRotateX,
    FSRotateY,
    FSRotateZ
} FSRotateType;

typedef struct _FSSDLRotatePreference FSRotatePreference;
struct _FSSDLRotatePreference {
    FSRotateType type;
    float degrees;
};

typedef struct _FSColorConvertPreference FSColorConvertPreference;
struct _FSColorConvertPreference {
    float brightness;
    float saturation;
    float contrast;
};

typedef struct _FSSDLDARPreference FSDARPreference;
struct _FSSDLDARPreference {
    float ratio; //ratio is width / height;
};

typedef enum : NSUInteger {
    FSSnapshotTypeOrigin, //keep original video size,without subtitle and video effect
    FSSnapshotTypeScreen, //current glview's picture as you see
    FSSnapshotTypeEffect_Origin,//keep original video size,with subtitle,without video effect
    FSSnapshotTypeEffect_Subtitle_Origin //keep original video size,with subtitle and video effect
} FSSnapshotType;

@protocol FSVideoRenderingDelegate;

#define HDR_API_AVAILABLE API_AVAILABLE(macos(10.11), ios(16.0)) API_UNAVAILABLE(tvos, watchos)

@protocol FSVideoRenderingProtocol <NSObject>

@property(nullable, nonatomic, weak) id <FSVideoRenderingDelegate> displayDelegate;

@property(nonatomic) FSScalingMode scalingMode;
#if TARGET_OS_IOS
@property(nonatomic) CGFloat scaleFactor;
#endif

@property(nonatomic) FSRotatePreference rotatePreference __deprecated_msg("will be removed in future version");
@property(nonatomic) float xRotateDegrees;
@property(nonatomic) float yRotateDegrees;
@property(nonatomic) float zRotateDegrees;
// color conversion preference
@property(nonatomic) FSColorConvertPreference colorPreference;
// user defined display aspect ratio
@property(nonatomic) FSDARPreference darPreference;
// not render picture and subtitle,but holder overlay content.
@property(atomic) BOOL preventDisplay;
// YES when the current display supports EDR/HDR and HDR content is rendered natively
// (no tone-mapping to SDR). Updated automatically when the display changes.
// HDR direct display is unavailable on tvOS
@property(nonatomic, readonly) BOOL directDisplayHDRSupportted HDR_API_AVAILABLE;
// Controls whether HDR direct rendering is permitted at all.
// Default YES. Set to NO to always tone-map HDR content to SDR regardless of display capability.
@property(nonatomic) BOOL allowHDRDirectDisplay HDR_API_AVAILABLE;
// refresh current video picture and subtitle (when player paused change video pic preference, you can invoke this method)
- (void)setNeedsRefreshCurrentPic;

// display the overlay.
- (BOOL)displayAttach:(FSOverlayAttach *)attach;

#if !TARGET_OS_OSX
- (UIImage *)snapshot;
#endif
- (CGImageRef)snapshot:(FSSnapshotType)aType;
- (NSString *)name;
- (id)context;

@optional;
- (void)setBackgroundColor:(uint8_t)r g:(uint8_t)g b:(uint8_t)b;
// 高斯模糊背景图片：替代默认纯色背景，填充无视频或黑边区域。传 nil 清除。
@property(nonatomic, strong, nullable) UIImage *backgroundImage;
// 生成高斯模糊的迭代次数，默认 3，推荐 2~4。
@property(nonatomic) int backgroundBlurIterations;
// 单次高斯模糊的 sigma（模糊半径），默认 30，值越大越模糊。
@property(nonatomic) float backgroundBlurSigma;
- (void)registerRefreshCurrentPicObserver:(nullable dispatch_block_t)block;

@end

@protocol FSVideoRenderingDelegate <NSObject>

@optional
//you can replace the video frame
- (CVPixelBufferRef _Nullable)videoRenderingWillDisplay:(id<FSVideoRenderingProtocol>_Nonnull)renderer videoFrame:(CVPixelBufferRef)videoFrame;

@optional
- (void)videoRenderingDidDisplay:(id<FSVideoRenderingProtocol>)renderer attach:(FSOverlayAttach *)attach;

@end

NS_ASSUME_NONNULL_END

#endif /* FSVideoRenderingProtocol_h */
