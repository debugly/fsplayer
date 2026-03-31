//
//  FSDisplayLinkWrapper.h
//  FSPlayer
//
//  Created by debugly on 2026/03/31.
//  Copyright © 2026 FSPlayer. All rights reserved.
//

#import "FSDisplayLinkWrapper.h"

#if TARGET_OS_OSX
#import <CoreVideo/CVDisplayLink.h>
#import <AppKit/AppKit.h>
#else
#import <QuartzCore/QuartzCore.h>
#endif

@interface FSDisplayLinkWrapper ()

#if TARGET_OS_OSX
@property (nonatomic, assign) CVDisplayLinkRef displayLink;
#else
@property (nonatomic, strong) CADisplayLink *displayLink;
#endif

@end

#if TARGET_OS_OSX
static CVReturn MyDisplayLinkCallback(CVDisplayLinkRef displayLink,
                                      const CVTimeStamp *inNow,
                                      const CVTimeStamp *inOutputTime,
                                      CVOptionFlags flagsIn,
                                      CVOptionFlags *flagsOut,
                                      void *displayLinkContext) {
    FSDisplayLinkWrapper *wrapper = (__bridge FSDisplayLinkWrapper *)displayLinkContext;
    CFTimeInterval timestamp = inOutputTime->hostTime / CVGetHostClockFrequency();
    if (wrapper.callback) {
        wrapper.callback(timestamp);
    }
    return kCVReturnSuccess;
}
#endif

@implementation FSDisplayLinkWrapper

- (instancetype)initWithCallback:(FSDisplayLinkCallback)callback {
    self = [super init];
    if (self) {
        _callback = [callback copy];
#if TARGET_OS_OSX
        CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
        CVDisplayLinkSetOutputCallback(_displayLink, MyDisplayLinkCallback, (__bridge void *)self);
        CGDirectDisplayID displayID = CGMainDisplayID();
        CVDisplayLinkSetCurrentCGDisplay(_displayLink, displayID);
#else
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkFired:)];
        if (@available(iOS 15.0,tvOS 15.0, *)) {
            _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(1, 60, 30);
        } else {
            _displayLink.preferredFramesPerSecond = 30;
        }
#endif
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
}

#if !TARGET_OS_OSX
- (void)displayLinkFired:(CADisplayLink *)displayLink {
    if (self.callback) {
        self.callback(displayLink.targetTimestamp);
    }
}
#endif

- (void)start {
#if TARGET_OS_OSX
    if (_displayLink) {
        CVDisplayLinkStart(_displayLink);
    }
#else
    if (_displayLink) {
        [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
#endif
}

- (void)stop {
#if TARGET_OS_OSX
    if (_displayLink) {
        CVDisplayLinkStop(_displayLink);
    }
#else
    if (_displayLink) {
        [_displayLink invalidate];
        _displayLink = nil;
    }
#endif
}

- (void)invalidate {
#if TARGET_OS_OSX
    if (_displayLink) {
        CVDisplayLinkStop(_displayLink);
        CVDisplayLinkRelease(_displayLink);
        _displayLink = NULL;
    }
#else
    if (_displayLink) {
        [_displayLink invalidate];
        _displayLink = nil;
    }
#endif
}

- (void)setPaused:(BOOL)paused {
#if TARGET_OS_OSX
    if (_displayLink) {
        if (paused) {
            CVDisplayLinkStop(_displayLink);
        } else {
            CVDisplayLinkStart(_displayLink);
        }
    }
#else
    if (_displayLink) {
        _displayLink.paused = paused;
    }
#endif
}

- (BOOL)isPaused {
#if TARGET_OS_OSX
    if (_displayLink) {
        return !CVDisplayLinkIsRunning(_displayLink);
    }
    return YES;
#else
    return _displayLink.isPaused;
#endif
}

#if TARGET_OS_OSX
- (void)updateWithWindow:(NSWindow *)window {
    if (!window) return;
    NSNumber *screenNumber = [[window screen] deviceDescription][@"NSScreenNumber"];
    if (screenNumber && _displayLink) {
        CGDirectDisplayID displayID = (CGDirectDisplayID)[screenNumber unsignedIntValue];
        CVDisplayLinkSetCurrentCGDisplay(_displayLink, displayID);
    }
}
#endif

@end