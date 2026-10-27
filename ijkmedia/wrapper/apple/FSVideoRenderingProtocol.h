/*
 * FSVideoRenderingProtocol.h
 *
 * Copyright (c) 2019 debugly <qianlongxu@gmail.com>
 *
 * This file is part of FSPlayer.
 *
 * FSPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
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

#import <FSPlayer/FSVideoOutputProtocol.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FSScalingMode) {
    FSScalingModeAspectFit,  // Uniform scale until one dimension fits
    FSScalingModeAspectFill, // Uniform scale until the movie fills the visible bounds. One dimension may have clipped contents
    FSScalingModeFill        // Non-uniform scale. Both render dimensions will exactly match the visible bounds
};

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

/// Full rendering controls provided by FSMetalView.
@protocol FSVideoRenderingProtocol <FSVideoOutputProtocol>

@property(nullable, nonatomic, weak) id <FSVideoRenderingDelegate> displayDelegate;

@property(nonatomic) FSScalingMode scalingMode;
#if TARGET_OS_IOS
@property(nonatomic) CGFloat scaleFactor;
#endif

@property(nonatomic) float xRotateDegrees;
@property(nonatomic) float yRotateDegrees;
@property(nonatomic) float zRotateDegrees;
// color conversion preference
@property(nonatomic) FSColorConvertPreference colorPreference;
// user defined display aspect ratio
@property(nonatomic) FSDARPreference darPreference;
// not render picture and subtitle,but holder overlay content.
@property(atomic) BOOL preventDisplay;
// Controls whether HDR direct rendering is permitted at all.
// Default YES. Set to NO to always tone-map HDR content to SDR regardless of display capability.
@property(nonatomic) BOOL allowHDRDirectDisplay HDR_API_AVAILABLE;
// refresh current video picture and subtitle (when player paused change video pic preference, you can invoke this method)
- (void)setNeedsRefreshCurrentPic;

#if !TARGET_OS_OSX
- (UIImage *)snapshot;
#endif
- (CGImageRef)snapshot:(FSSnapshotType)aType;

@optional;
//控制背景色
- (void)setBackgroundColor:(uint8_t)r g:(uint8_t)g b:(uint8_t)b;
// transparent == YES 时背景完全透明，无视频区域和视频透明区域均可透出底层视图。
// transparent == NO 时使用不透明背景，与上面三个参数的方法等价。
- (void)setBackgroundColor:(uint8_t)r g:(uint8_t)g b:(uint8_t)b transparent:(BOOL)transparent;
/// 默认 NO。开启后，带 alpha 的视频帧自动使用透明背景，backgroundImage 仍正常绘制。
/// 普通视频或关闭此选项时将渲染 setBackgroundColor 设置的颜色与透明状态。
/// 只控制渲染视图；父视图和窗口的透明状态由调用者设置。
@property (nonatomic) BOOL autoTransparentBackgroundColor;
// 高斯模糊背景图片：替代默认纯色背景，只有需要填充黑边区域时才绘制。传 nil 清除。
@property(nonatomic, strong, nullable) UIImage *backgroundImage;
// 生成高斯模糊的迭代次数，默认 3，推荐 2~4。
@property(nonatomic) int backgroundBlurIterations;
// 单次高斯模糊的 sigma（模糊半径），默认 30，值越大越模糊。
@property(nonatomic) float backgroundBlurSigma;

@end

/// Read-only display information supplied by a renderer. Does not retain decoded
/// AVFrame or tile data; the concrete renderer owns its rendering resources.
@protocol FSVideoRenderFrame <NSObject>
@property(nonatomic, readonly) int w;
@property(nonatomic, readonly) int h;
@property(nonatomic, readonly) int sarNum;
@property(nonatomic, readonly) int sarDen;
@property(nonatomic, readonly) int autoZRotate;
@property(nonatomic, readonly) BOOL hasAlpha;
@end

@protocol FSVideoRenderingDelegate <NSObject>

@optional
// You can replace the video frame. Input is borrowed; do not release it.
// Return a borrowed buffer (the input is allowed), or NULL to omit the video image.
// The renderer retains a replacement buffer; ownership is not transferred by this callback.
- (CVPixelBufferRef _Nullable)videoRenderingWillDisplay:(id<FSVideoRenderingProtocol>_Nonnull)renderer videoFrame:(CVPixelBufferRef)videoFrame;

@optional
// Display information belongs to the renderer; it contains no decoded frame data.
- (void)videoRenderingDidDisplay:(id<FSVideoRenderingProtocol>)renderer attach:(id<FSVideoRenderFrame>)attach;

@end

NS_ASSUME_NONNULL_END

#endif /* FSVideoRenderingProtocol_h */
