//
//  MRTrackingView.h
//  AuraPlayer
//
//  Created by debugly on 2021/12/01.
//  Copyright © 2021 debugly. All rights reserved.
//

#import <AppKit/AppKit.h>

@class MRTrackingView;
@protocol MRTrackingViewDelegate <NSObject>
@optional;
- (void)trackingView:(MRTrackingView *)view mouseEntered:(NSEvent *)event;
- (void)trackingView:(MRTrackingView *)view mouseExited:(NSEvent *)event;
- (void)trackingView:(MRTrackingView *)view mouseMoved:(NSEvent *)event;
- (void)trackingView:(MRTrackingView *)view mouseDown:(NSEvent *)event;
- (void)trackingView:(MRTrackingView *)view mouseUp:(NSEvent *)event;
- (void)trackingView:(MRTrackingView *)view mouseDragged:(NSEvent *)theEvent;
- (BOOL)trackingView:(MRTrackingView *)view cursorNeedUpdate:(NSEvent *)event;

@end

@interface MRTrackingView : NSView

@property (strong, nonatomic) IBInspectable NSColor *backgroundColor;
@property (weak) IBOutlet id<MRTrackingViewDelegate> delegate;
//default is YES;
@property (assign, nonatomic) IBInspectable BOOL userInteraction;
//default is NO;
@property (assign, nonatomic) IBInspectable BOOL needTracking;
@property (copy, nonatomic) NSString *name;
@property (nonatomic, assign) NSEdgeInsets inset;
@property (readwrite) IBInspectable NSInteger tag;

@end
