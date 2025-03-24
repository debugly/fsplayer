//
//  MRProgressIndicator.h
//  IJKMediaDemo
//
//  Created by Matt Reach on 2022/11/07.
//  Copyright © 2022 IJK Mac 版. All rights reserved.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

static const CGFloat kProgressIndicatorColorHeight = 6.0;

@interface MRProgressIndicator : NSView

//左侧已经播放开始颜色
@property (nonatomic, strong) IBInspectable NSColor  *playedStartColor;
//左侧已经播放结束颜色
@property (nonatomic, strong) IBInspectable NSColor  *playedEndColor;
//右侧预加载颜色
@property (nonatomic, strong) IBInspectable NSColor  *preloadColor;
//右侧未加载颜色
@property (nonatomic, strong) IBInspectable NSColor  *unLoadColor;
//已播放时长[min-max];
@property (nonatomic, assign) IBInspectable CGFloat playedValue;
//预加载时长[min-max];
@property (nonatomic, assign) IBInspectable CGFloat preloadValue;
//视频时长
@property (nonatomic, assign) IBInspectable CGFloat maxValue;
//最小视频时长；0
@property (nonatomic, assign) IBInspectable CGFloat minValue;
//设置时间点，展示一个竖条，用于实现看点
@property (nonatomic, strong, nullable) NSArray <NSNumber *>* tags;
//设置进度条是否是圆角，默认 NO
@property (nonatomic, assign) IBInspectable BOOL rounded;
//设置进库条在外侧容器内的水平 padding，默认 0
@property (nonatomic, assign) IBInspectable CGFloat horizontalPadding;

@property (assign, nonatomic) BOOL userInteraction;
@property (readwrite) NSInteger tag;

// 停止拖拽时回调
- (void)onDraggedIndicator:(void(^)(double progress,MRProgressIndicator *indicator,BOOL isEndDrag))handler;
// Hover期间回调
- (void)onHoveredBar:(void (^)(double,MRProgressIndicator*))hoveredHandler
              onExit:(void (^)(MRProgressIndicator*))exitHandler;

@end

NS_ASSUME_NONNULL_END
