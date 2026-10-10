/*
 * Copyright (c) 2019 debugly <qianlongxu@gmail.com>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Gaussian-style blur for the swipe background.
///
/// Ported from SohuLive's UIImage+SLImageEffects, which is itself the standard
/// Accelerate/vImage recipe: three successive box blurs approximate a Gaussian
/// to within about 3%, then saturation is scaled and a tint is laid over. The
/// background is an avatar-sized image blown up to fill the screen, so a real
/// Gaussian would be expensive and a box approximation reads the same.
@interface UIImage (FSImageEffects)

/// The effect used for the swipe backdrop: strong blur, dimmed.
- (nullable UIImage *)fs_applyDarkEffect;

- (nullable UIImage *)fs_applyBlurWithRadius:(CGFloat)blurRadius
                                   tintColor:(nullable UIColor *)tintColor
                       saturationDeltaFactor:(CGFloat)saturationDeltaFactor;

@end

NS_ASSUME_NONNULL_END