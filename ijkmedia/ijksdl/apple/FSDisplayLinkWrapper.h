//
//  FSDisplayLinkWrapper.h
//  FSPlayer
//
//  Created by debugly on 2026/03/31.
//  Copyright © 2026 FSPlayer. All rights reserved.
//

#import <Foundation/Foundation.h>

#if TARGET_OS_OSX
#import <AppKit/NSView.h>
#endif

NS_ASSUME_NONNULL_BEGIN

typedef void (^FSDisplayLinkCallback)(CFTimeInterval timestamp);

@interface FSDisplayLinkWrapper : NSObject

@property (nonatomic, copy, readonly) FSDisplayLinkCallback callback;
@property (nonatomic, assign, getter=isPaused) BOOL paused;

- (instancetype)initWithCallback:(FSDisplayLinkCallback)callback;

#if TARGET_OS_OSX
- (void)updateWithWindow:(nullable NSWindow *)window;
#endif

- (void)start;
- (void)stop;
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
