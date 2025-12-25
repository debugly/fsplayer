//
//  FSMetalView.h
//  FFmpegTutorial-macOS
//
//  Created by debugly on 2022/11/22.
//  Copyright © 2022 debugly's Awesome FFmpeg Tutotial. All rights reserved.
//

#import "FSVideoRenderingProtocol.h"
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
typedef NSView UIView;
#else
#import <UIKit/UIKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

NS_CLASS_AVAILABLE(10_13, 11_0)
@interface FSMetalView : UIView <FSVideoRenderingProtocol>

@end

NS_ASSUME_NONNULL_END
