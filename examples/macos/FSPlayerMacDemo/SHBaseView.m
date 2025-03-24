//
//  AppDelegate.h
//  IJKMediaDemo
//
//  Created by Matt Reach on 2021/12/01.
//  Copyright © 2021 IJK Mac. All rights reserved.
//

#import "SHBaseView.h"

@implementation SHBaseView
{
    BOOL hovered;
    NSTrackingArea *_trackingArea;
}

@synthesize tag = _tag;

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)commonInit
{
    self.userInteraction = YES;
    //当在hover区域内，通过点击事件跳转到了别的应用时，updateTrackingAreas 能够让view收到exit；不至于下次进来enter和move均不能接收，需要二次进入
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidResignActive:) name:NSApplicationDidResignActiveNotification object:nil];
}

- (void)applicationDidResignActive:(NSNotification *)sender
{
    [self updateTrackingAreas];
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)setBackgroundColor:(NSColor *)backgroundColor
{
    [self setWantsLayer:YES];
    self.layer.backgroundColor = [backgroundColor CGColor];
}

- (NSView *)hitTest:(NSPoint)point
{
    if (self.userInteraction && !self.isHidden) {
        return [super hitTest:point];
    } else {
        return nil;
    }
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    
    if (hovered) {
        hovered = NO;
        if (self.delegate && [self.delegate respondsToSelector:@selector(baseView:mouseExited:)]) {
            [self.delegate baseView:self mouseExited:nil];
        }
    }
    
    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }
    
    if (self.userInteraction && self.needTracking && !self.isHidden) {
    
        NSRect trackingAreaRect =  CGRectMake(self.bounds.origin.x + self.inset.left, self.bounds.origin.y + self.inset.bottom,self.bounds.size.width - self.inset.right - self.inset.left, self.bounds.size.height - self.inset.bottom -self.inset.top);

        _trackingArea = [[NSTrackingArea alloc] initWithRect:trackingAreaRect
                                                                    options:(NSTrackingMouseEnteredAndExited |
                                                                             NSTrackingMouseMoved |
                                                                             NSTrackingActiveInActiveApp |
                                                                             NSTrackingAssumeInside |
                                                                             NSTrackingCursorUpdate)
                                                                      owner:self
                                                                   userInfo:nil];
        [self addTrackingArea:_trackingArea];
    }
}

- (void)setInset:(NSEdgeInsets)inset
{
    if (NSEdgeInsetsEqual(_inset, inset)) {
        return;
    }
    _inset = inset;
    [self updateTrackingAreas];
}

- (void)mouseEntered:(NSEvent *)theEvent
{
    if (self.window.ignoresMouseEvents) {
        return;
    }
    hovered = YES;
    if (self.delegate && [self.delegate respondsToSelector:@selector(baseView:mouseEntered:)]) {
        [self.delegate baseView:self mouseEntered:theEvent];
    }
}

- (void)mouseExited:(NSEvent *)theEvent
{
    if (self.window.ignoresMouseEvents) {
        return;
    }
    hovered = NO;
    if (self.delegate && [self.delegate respondsToSelector:@selector(baseView:mouseExited:)]) {
        [self.delegate baseView:self mouseExited:theEvent];
    }
}

- (void)mouseMoved:(NSEvent *)theEvent
{
    if (self.window.ignoresMouseEvents) {
        return;
    }
    if (self.delegate && [self.delegate respondsToSelector:@selector(baseView:mouseMoved:)]) {
        [self.delegate baseView:self mouseMoved:theEvent];
    }
}

- (void)mouseDown:(NSEvent *)theEvent
{
    [self.window makeFirstResponder:self];
    
    if (self.window.ignoresMouseEvents) {
        return;
    }
    if (self.delegate && [self.delegate respondsToSelector:@selector(baseView:mouseDown:)]) {
        [self.delegate baseView:self mouseDown:theEvent];
    }
    //第一次点击鼠标，窗口激活；第二次点击之后，没有捕获到事件，因此这里更新下，鼠标移动则能立马捕获到；
    if (!hovered) {
        [self updateTrackingAreas];
    }
}

- (void)mouseUp:(NSEvent *)theEvent
{
    if (self.window.ignoresMouseEvents) {
        return;
    }
    if (self.delegate && [self.delegate respondsToSelector:@selector(baseView:mouseUp:)]) {
        [self.delegate baseView:self mouseUp:theEvent];
    }
}

- (void)mouseDragged:(NSEvent *)theEvent
{
    if (self.window.ignoresMouseEvents) {
        return;
    }
    if (self.delegate && [self.delegate respondsToSelector:@selector(baseView:mouseDragged:)]) {
        [self.delegate baseView:self mouseDragged:theEvent];
    }
}

- (void)cursorUpdate:(NSEvent *)event
{
    if (self.window.ignoresMouseEvents) {
        return;
    }
    //防止在首页的时候，移动鼠标，调用 [super cursorUpdate:event];
    if (!self.needTracking) {
        return;
    }
    
    if (self.delegate && [self.delegate respondsToSelector:@selector(baseView:cursorNeedUpdate:)]) {
        if (![self.delegate baseView:self cursorNeedUpdate:event]) {
            return;
        }
    }
    
    NSPoint thePoint = [self convertPoint:[event locationInWindow] fromView:nil];
    NSRect trackingAreaRect = CGRectMake(self.bounds.origin.x + self.inset.left,
                                         self.bounds.origin.y + self.inset.bottom,
                                         self.bounds.size.width - self.inset.right - self.inset.left,
                                         self.bounds.size.height - self.inset.bottom - self.inset.top);
    
    if (!NSPointInRect(thePoint, trackingAreaRect)) {
        return;
    }
    //解决从H5点击进来后，鼠标没有变成指针问题！
    [super cursorUpdate:event];
}

- (void)setUserInteraction:(BOOL)userInteraction
{
    if (_userInteraction != userInteraction) {
        _userInteraction = userInteraction;
        [self updateTrackingAreas];
    }
}

- (void)setNeedTracking:(BOOL)needTracking
{
    if (_needTracking != needTracking) {
        _needTracking = needTracking;
        [self updateTrackingAreas];
    }
}

- (void)setHidden:(BOOL)hidden
{
    [super setHidden:hidden];
    [self updateTrackingAreas];
}

//点击之后立马接收鼠标事件
- (BOOL)acceptsFirstResponder
{
    return YES;
}

@end
