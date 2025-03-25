//
//  FSVideoRenderView.m
//  FSMediaPlayerKit
//
//  Created by Reach Matt on 2023/4/6.
//

#import "FSVideoRenderView.h"
#if TARGET_OS_OSX
#import "FSSDLGLView.h"
#endif
#import "FSMetalView.h"

@implementation FSVideoRenderView

#if TARGET_OS_OSX
+ (UIView<FSVideoRenderingProtocol> *)createGLRenderView
{
#if TARGET_OS_IOS || TARGET_OS_TV
    CGRect rect = [[UIScreen mainScreen] bounds];
#else
    CGRect rect = [[[NSScreen screens] firstObject]frame];
#endif
    rect.origin = CGPointZero;
    return [[FSSDLGLView alloc] initWithFrame:rect];
}
#endif

+ (UIView<FSVideoRenderingProtocol> *)createMetalRenderView
{
#if TARGET_OS_IOS || TARGET_OS_TV
    CGRect rect = [[UIScreen mainScreen] bounds];
#else
    CGRect rect = [[[NSScreen screens] firstObject]frame];
#endif
    rect.origin = CGPointZero;
    return [[FSMetalView alloc] initWithFrame:rect];
}

@end
