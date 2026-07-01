//
//  FSMetalView.h
//  FFmpegTutorial-macOS
//
//  Created by debugly on 2022/11/22.
//  Copyright © 2022 debugly's Awesome FFmpeg Tutorial. All rights reserved.
//

#import "FSVideoRenderingProtocol.h"
@import MetalKit;

NS_ASSUME_NONNULL_BEGIN

@interface FSMetalView : MTKView <FSVideoRenderingProtocol>

/// 高斯模糊背景图片。设置后，没有视频画面或视频按比例缩放留出黑边时，
/// 会用这张图片的高斯模糊结果填充背景，替代默认的纯色（黑色）背景。
/// 传 nil 清除，恢复纯色背景。
@property (nonatomic, strong, nullable) UIImage *backgroundImage;

/// 生成高斯模糊时的迭代次数：每多迭代一次模糊越强（有效 sigma 约按 sqrt(次数) 增长）。
/// 默认 3，推荐 2~4：1 次偏轻，2~4 次是清晰度与开销的最佳平衡，再多收益递减。
@property (nonatomic) int backgroundBlurIterations;

/// 单次高斯模糊的 sigma（模糊半径）。默认 30，值越大越模糊。
@property (nonatomic) float backgroundBlurSigma;

@end

NS_ASSUME_NONNULL_END
