//
//  FSInternalRenderView.h
//  FSMediaPlayerKit
//
//  Created by Reach Matt on 2023/4/6.
//
//
// you can use below mthods, create ijk internal render view.

#import "FSVideoRenderingProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@interface FSInternalRenderView : NSObject

#if TARGET_OS_OSX
+ (UIView<FSVideoRenderingProtocol> *)createGLRenderView;
#endif

+ (UIView<FSVideoRenderingProtocol> *)createMetalRenderView NS_AVAILABLE(10_13, 11_0);

@end

NS_ASSUME_NONNULL_END
