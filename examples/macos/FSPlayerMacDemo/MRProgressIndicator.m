//
//  MRProgressIndicator.m
//  IJKMediaDemo
//
//  Created by Matt Reach on 2022/11/07.
//  Copyright © 2022 IJK Mac 版. All rights reserved.

#import "MRProgressIndicator.h"

IB_DESIGNABLE

@interface MRProgressIndicator ()

@property (nonatomic) NSImage *knobImg;

@end

@implementation MRProgressIndicator
{
    BOOL _isMouseDown,_isMouseEnter;
    float _draggedValue;//拖动时使用的value
    
    CGFloat _indicatorHeight;
    CGFloat _indicatorWidth;
    CGFloat _progressHeight;
    void (^draggedIndicatorHandler)(double progress,MRProgressIndicator* indicator,BOOL isEndDrag);
    void (^hoveredBarHandler)(double progress,MRProgressIndicator* indicator);
    void (^exitHoveredBarHandler)(MRProgressIndicator* indicator);
}

@synthesize tag = _tag;

- (NSImage *)knobImg
{
    if (!_knobImg) {
        _knobImg = [NSImage imageNamed:@"knob_small"];
    }
    return _knobImg;
}

- (void)_init
{
    if (!_playedStartColor) {
        _playedStartColor = [NSColor colorWithRed:253.0/255.0 green:107.0/255.0 blue:107.0/255.0 alpha:1.0];
    }
    
    if (!_playedEndColor) {
        _playedEndColor = [NSColor colorWithRed:255.0/255.0 green:41.0/255.0 blue:88.0/255.0 alpha:1.0];
    }
    
    if (!_preloadColor) {
        _preloadColor = [[NSColor whiteColor] colorWithAlphaComponent:0.75];
    }
    
    if (!_unLoadColor) {
        _unLoadColor = [NSColor lightGrayColor];
    }
    
    _userInteraction = YES;
    
    [self updateDrawHeight];
//    [self setWantsLayer:YES];
//    self.layer.backgroundColor = [[NSColor orangeColor] CGColor];
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        [self _init];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)decoder
{
    self = [super initWithCoder:decoder];
    if (self) {
        [self _init];
    }
    return self;
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    
    if (_isMouseEnter) {
        [self mouseExited:[NSEvent new]];
    }
    if (_isMouseDown) {
        [self mouseUp:[NSEvent new]];
    }
    NSArray * trackingAreas = [self trackingAreas];
    for (NSTrackingArea *area in trackingAreas) {
        [self removeTrackingArea:area];
    }
    
    if (self.userInteraction) {
        NSRect trackingRect = [self _theTrackingRect];
        NSTrackingArea *trackingArea = [[NSTrackingArea alloc] initWithRect:trackingRect
                                                                    options:(NSTrackingMouseEnteredAndExited |
                                                                             NSTrackingMouseMoved |
                                                                             NSTrackingActiveInActiveApp |
                                                                             NSTrackingAssumeInside)
                                                                      owner:self
                                                                   userInfo:nil];
        [self addTrackingArea:trackingArea];
    }
}

- (NSRect)_theTrackingRect
{
    NSRect trackingRect = self.bounds;
//    trackingRect.origin.y += 6;
//    trackingRect.size.height -= 20;
    return trackingRect;
}

#pragma mark -
#pragma mark Setters

- (void)setMaxValue:(CGFloat)maxValue
{
    if (_maxValue != maxValue) {
        _maxValue = maxValue;
        [self setNeedsDisplay:YES];
    }
}

- (void)setMinValue:(CGFloat)minValue
{
    if (_minValue != minValue) {
        _minValue = minValue;
        [self setNeedsDisplay:YES];
    }
}

- (void)setPlayedValue:(CGFloat)playedValue
{
    if (!_isMouseDown) {
        if (_playedValue != playedValue) {
            _playedValue = playedValue;
            [self setNeedsDisplay:YES];
        }
    }
}

- (void)setPreloadValue:(CGFloat)preloadValue
{
    if (_preloadValue != preloadValue) {
        _preloadValue = preloadValue;
        [self setNeedsDisplay:YES];
    }
}

- (void)setPlayedStartColor:(NSColor *)playedStartColor
{
    if (_playedStartColor != playedStartColor) {
        _playedStartColor = playedStartColor;
        [self setNeedsDisplay:YES];
    }
}

- (void)setPlayedEndColor:(NSColor *)playedEndColor
{
    if (_playedEndColor != playedEndColor) {
        _playedEndColor = playedEndColor;
        [self setNeedsDisplay:YES];
    }
}

- (void)setPreloadColor:(NSColor *)preloadColor
{
    if (_preloadColor != preloadColor) {
        _preloadColor = preloadColor;
        [self setNeedsDisplay:YES];
    }
}

- (void)setUnLoadColor:(NSColor *)unLoadColor
{
    if (_unLoadColor != unLoadColor) {
        unLoadColor = unLoadColor;
        [self setNeedsDisplay:YES];
    }
}

- (void)updateDrawHeight
{
    CGFloat height = self.bounds.size.height;
    _progressHeight = height * 0.4;
    _indicatorHeight = height;
    _indicatorWidth = _indicatorHeight / self.knobImg.size.height * self.knobImg.size.width;
    
    [self invalidateIntrinsicContentSize];
    [self setNeedsDisplay:YES];
}

- (void)setRounded:(BOOL)rounded
{
    if (_rounded != rounded) {
        _rounded = rounded;
        [self invalidateIntrinsicContentSize];
        [self setNeedsDisplay:YES];
    }
}

- (void)setHorizontalPadding:(CGFloat)horizontalPadding
{
    if (horizontalPadding < 0) {
        horizontalPadding = 0;
    }
    if (fabs((horizontalPadding - _horizontalPadding)) > 1e-4) {
        _horizontalPadding = horizontalPadding;
        [self invalidateIntrinsicContentSize];
        [self setNeedsDisplay:YES];
    }
}

#pragma mark -
#pragma mark DrawRect

- (void)drawRect:(NSRect)dirtyRect
{
    const NSRect viewBounds = self.bounds;
    
    NSRect slideRect = viewBounds;
    
    {
        slideRect.size.height = _progressHeight;
        //向上偏移，这样指示器可以浮在bottomBar上
        slideRect.origin.y = (viewBounds.size.height - _progressHeight) / 2.0;
    }
   
    const CGFloat indicatorRadius = _indicatorWidth / 2.0;
    const CGFloat maxWidth = slideRect.size.width;// - 2 * indicatorRadius;
    const CGFloat denominator = (_maxValue - _minValue);
    
    // stop state
    if (0 == _playedValue && 0 == _maxValue) {
        [_unLoadColor set];
        NSRectFill(slideRect);
        return;
    }
    
    // draw unload background color
    {
        if (_rounded) {
            NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:slideRect xRadius:_progressHeight / 2 yRadius:_progressHeight / 2];
            [_unLoadColor setFill];
            [path fill];
        } else {
            [_unLoadColor set];
            NSRectFill(slideRect);
        }
    }
    
    if (denominator > 0) {
        // draw preload background color
        if (_preloadValue > _playedValue) {
            NSRect rect = slideRect;
            
            CGFloat width = _preloadValue / denominator * maxWidth;
            if (width < 0) {
                width = 0;
            } else if (width > maxWidth) {
                width = maxWidth;
            }
            width += indicatorRadius;
            rect.size.width = width;
            if (_rounded) {
                NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:_progressHeight/2 yRadius:_progressHeight/2];
                [_preloadColor setFill];
                [path fill];
            } else {
                [_preloadColor set];
                NSRectFill(rect);
            }
        }
        
        // draw played background color
        NSRect rect = slideRect;
        
        CGFloat width = 0.0;
        
        if (_isMouseDown && _draggedValue >= 0) {
            width = _draggedValue / denominator * maxWidth;
        } else {
            width = _playedValue / denominator * maxWidth;
        }
        
        if (width < 0) {
            width = 0;
        } else if (width > maxWidth) {
            width = maxWidth;
        }
        
        width += indicatorRadius;
        rect.size.width = width;
        
        NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:_playedStartColor
                                                             endingColor:_playedEndColor];
        
        if (_rounded) {
            NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:_progressHeight/2 yRadius:_progressHeight/2];
            [path closePath];
            if (![path isEmpty]) {
                [gradient drawInBezierPath:path angle:0];
            }
        } else {
            [gradient drawInRect:rect angle:0];
        }
        
        // drew tags
        {
            for (NSNumber *num in self.tags) {
                CGFloat p = [num floatValue] / denominator * maxWidth;
                CGRect rect = slideRect;
                rect.size.width = 1;
                rect.origin.x = p - rect.size.width / 2.0;
                
                NSBezierPath *bezierPath = [NSBezierPath bezierPath];
                [bezierPath appendBezierPathWithRect:rect];
                bezierPath.lineWidth = 1;
                [[NSColor colorWithWhite:1.0 alpha:0.95] setFill];
                [bezierPath fill];
            }
        }
    }

    // draw indicator
    {
        CGFloat width = 0.0;
        
        if (denominator > 0) {
            if (_isMouseDown && _draggedValue >= 0) {
                width = _draggedValue * maxWidth / denominator;
            } else {
                width = _playedValue * maxWidth / denominator;
            }
            
            if (width < 0) {
                width = 0;
            } else if (width > maxWidth) {
                width = maxWidth;
            }
        }
        width += indicatorRadius;
        
        CGFloat indicatorX = width - _indicatorWidth / 2;
        
        if (indicatorX < indicatorRadius - _indicatorWidth / 2) {
            indicatorX = indicatorRadius - _indicatorWidth / 2;
        } else if (indicatorX > maxWidth) {
            indicatorX = maxWidth;
        }
        
        indicatorX += _horizontalPadding;
        
        CGFloat indicatorY = slideRect.origin.y + slideRect.size.height / 2.0 - _indicatorHeight / 2.0;
        CGRect indicatorRect = {{indicatorX,indicatorY},{_indicatorWidth,_indicatorHeight}};
        
        [self.knobImg drawInRect:indicatorRect];
    }
    
//    CGContextRef context = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
//    CGContextSetShadowWithColor(context, CGSizeZero, 25, [[NSColor orangeColor]CGColor]);  // glowing shadow
}

#pragma mark -
#pragma mark Mouse Events

- (void)mouseDown:(NSEvent *)theEvent
{
    NSPoint thePoint = [self convertPoint:[theEvent locationInWindow] fromView:nil];
    if (NSPointInRect(thePoint, [self bounds]))
    {
        _isMouseDown = YES;
        if (_isMouseEnter) {
            if (exitHoveredBarHandler) {
                exitHoveredBarHandler(self);
            }
            _isMouseEnter = NO;
        }
        [self mouseDragged:theEvent];
    }
}

- (void)mouseUp:(NSEvent *)theEvent
{
    if (_isMouseDown) {
        _isMouseDown = NO;
        _isMouseEnter = YES;
        
        const CGFloat denominator = (_maxValue - _minValue);
        
        if (denominator > 0) {
            [self setPlayedValue:_draggedValue];
            
            double progress = _draggedValue / denominator;
            
            if (draggedIndicatorHandler) {
                draggedIndicatorHandler(progress,self,YES);
            }
        }
    }
}

- (void)mouseDragged:(NSEvent *)theEvent
{
    if (_isMouseDown)
    {
        NSPoint thePoint = [self convertPoint:[theEvent locationInWindow] fromView:nil];
        double theValue;
        double maxX = [self bounds].size.width - _indicatorWidth - 2 * _horizontalPadding;
        thePoint.x -= _indicatorWidth / 2.0;
        thePoint.x -= _horizontalPadding;
        
        if (thePoint.x < 0)
            theValue = [self minValue];
        else if (thePoint.x >= maxX)
            theValue = [self maxValue];
        else
            theValue = [self minValue] + (([self maxValue] - [self minValue]) * (round(thePoint.x + 0.5) - 0) / (maxX - 0));
        
        _draggedValue = theValue;
        [self setNeedsDisplay:YES];
        
        const CGFloat denominator = (_maxValue - _minValue);
        
        if (denominator > 0) {
            double progress = _draggedValue / denominator;
            
            if (draggedIndicatorHandler) {
                draggedIndicatorHandler(progress, self, NO);
            }
        }
    }
}

- (void)mouseEntered:(NSEvent *)theEvent
{
    if ([NSApp modalWindow]) {
        return;
    }
    if (self.window.ignoresMouseEvents) {
        return;
    }
    _isMouseEnter = YES;
    [self mouseMoved:theEvent];
}

- (void)mouseExited:(NSEvent *)theEvent
{
    if (_isMouseEnter) {
        if (exitHoveredBarHandler) {
            exitHoveredBarHandler(self);
        }
        _isMouseEnter = NO;
    }
}

- (void)mouseMoved:(NSEvent *)theEvent
{
    if (_isMouseEnter)
    {
        CGPoint pointInWindow = [theEvent locationInWindow];
        NSPoint thePoint = [self convertPoint:pointInWindow fromView:nil];
        thePoint.x -= _indicatorWidth / 2.0;
        thePoint.x -= _horizontalPadding;
        CGFloat x = thePoint.x;
        CGFloat maxX = [self bounds].size.width - _indicatorWidth - 2 * _horizontalPadding;

        if (x < 0) {
            x = 0;
        }else if (x > maxX) {
            x = maxX;
        }
    
        double progress = x / maxX;
        
        if (hoveredBarHandler) {
            hoveredBarHandler(progress,self);
        }
    }
}

- (BOOL)mouseDownCanMoveWindow
{
    return NO;
}

- (void)onDraggedIndicator:(void (^)(double,MRProgressIndicator*,BOOL))handler
{
    draggedIndicatorHandler = handler;
}

- (void)onHoveredBar:(void (^)(double,MRProgressIndicator*))hoveredHandler
              onExit:(void (^)(MRProgressIndicator*))exitHandler
{
    hoveredBarHandler = hoveredHandler;
    exitHoveredBarHandler = exitHandler;
}

- (NSView *)hitTest:(NSPoint)point
{
    if (self.userInteraction) {
        NSPoint myPoint = [self.superview convertPoint:point toView:self];
        NSRect trackingRect = [self _theTrackingRect];
        if (NSPointInRect(myPoint, trackingRect)) {
            return [super hitTest:point];
        } else {
            return nil;
        }
    } else {
        return nil;
    }
}

- (void)setUserInteraction:(BOOL)userInteraction
{
    if (_userInteraction != userInteraction) {
        _userInteraction = userInteraction;
        [self updateTrackingAreas];
    }
}

@end
