/*
 * FSVideoOutputProtocol.h
 *
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

#ifndef FSVideoOutputProtocol_h
#define FSVideoOutputProtocol_h

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

typedef struct SDL_TextureOverlay SDL_TextureOverlay;

// HEIC tile grid: 单个 tile 的位置信息 + 帧数据。
// avframe 由 dispatch 层从 overlay 克隆（owned）；渲染器独立持有转换结果。
@interface FSTilePiece : NSObject
@property(nonatomic) struct AVFrame * _Nullable avframe;        // 持有 (owned, av_frame_free in dealloc)
@property(nonatomic) int x;         // canvas 上左上角
@property(nonatomic) int y;
@property(nonatomic) int w;         // tile 尺寸
@property(nonatomic) int h;
@end

@interface FSOverlayAttach : NSObject

// Display dimensions resolved by the player (including tile-grid canvas metadata).
@property(nonatomic) int w;
@property(nonatomic) int h;

// Resolved by av_guess_sample_aspect_ratio (may differ from AVFrame SAR).
@property(nonatomic) int sarNum;
@property(nonatomic) int sarDen;
// Player-resolved rotation, including stream metadata and configured override.
@property(nonatomic) int autoZRotate;

// Full decoded frame (av_frame_ref'd, owned; freed in dealloc). Carries side data
// such as Dolby Vision RPU.
// Metal renderers derive their own CVPixelBuffer without modifying this input.
@property(nonatomic) struct AVFrame * _Nullable avframe;

// HEIC tile grid：非空时表示此帧是多 tile 合成，渲染器需要按 tilePieces 的位置信息拼图。
@property(nonatomic) NSArray<FSTilePiece *> * _Nullable tilePieces;

@property(nonatomic) SDL_TextureOverlay * _Nullable overlay;

- (BOOL)hasAlpha;

@end

/// Minimal video output contract consumed by FSPlayer and the Apple vout bridge.
/// Implementations receive frames on the playback output thread.
@protocol FSVideoOutputProtocol <NSObject>

// Return YES when the attach has been accepted.
- (BOOL)displayAttach:(FSOverlayAttach *)attach;

@optional
// Return NO to fall back to displayAttach: with a complete video attach.
- (BOOL)refreshAttach:(nullable SDL_TextureOverlay *)overlay;

// GPU context used to build the subtitle SDL_GPU (e.g. FSMetalView returns its
// MTLDevice).
- (nullable id)context;
- (NSString *)name;
- (void)registerRefreshCurrentPicObserver:(nullable dispatch_block_t)block;
// Release rendering resources (Vulkan/Metal/GPU). Called when the player stops
// and removes the view. Implementations must be safe to call multiple times.
- (void)destroy;

@end

NS_ASSUME_NONNULL_END

#endif /* FSVideoOutputProtocol_h */
