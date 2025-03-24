//
//  AppDelegate.h
//  IJKMediaDemo
//
//  Created by Matt Reach on 2021/12/01.
//  Copyright © 2021 IJK Mac. All rights reserved.
//

#import <AppKit/AppKit.h>

@class SHBaseView;
@protocol SHBaseViewDelegate <NSObject>
@optional;
- (void)baseView:(SHBaseView *)baseView mouseEntered:(NSEvent *)event;
- (void)baseView:(SHBaseView *)baseView mouseExited:(NSEvent *)event;
- (void)baseView:(SHBaseView *)baseView mouseMoved:(NSEvent *)event;
- (void)baseView:(SHBaseView *)baseView mouseDown:(NSEvent *)event;
- (void)baseView:(SHBaseView *)baseView mouseUp:(NSEvent *)event;
- (void)baseView:(SHBaseView *)baseView mouseDragged:(NSEvent *)theEvent;
- (BOOL)baseView:(SHBaseView *)baseView cursorNeedUpdate:(NSEvent *)event;

@end

@interface SHBaseView : NSView

@property (strong, nonatomic) IBInspectable NSColor *backgroundColor;
@property (weak) IBOutlet id<SHBaseViewDelegate> delegate;
//default is YES;
@property (assign, nonatomic) IBInspectable BOOL userInteraction;
//default is NO;
@property (assign, nonatomic) IBInspectable BOOL needTracking;
@property (copy, nonatomic) NSString *name;
@property (nonatomic, assign) NSEdgeInsets inset;
@property (readwrite) IBInspectable NSInteger tag;

@end
