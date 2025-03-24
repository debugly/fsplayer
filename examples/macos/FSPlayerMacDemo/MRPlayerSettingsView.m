//
//  MRPlayerSettingsView.m
//  IJKMediaMacDemo
//
//  Created by Reach Matt on 2024/5/16.
//  Copyright © 2024 IJK Mac. All rights reserved.
//

#import "MRPlayerSettingsView.h"

@interface MRPlayerSettingsView ()

@property(nonatomic, weak) NSViewController *vc;
@property (nonatomic, weak) IBOutlet NSPopUpButton *subtitlePopUpBtn;
@property (nonatomic, weak) IBOutlet NSPopUpButton *audioPopUpBtn;
@property (nonatomic, weak) IBOutlet NSPopUpButton *videoPopUpBtn;
@property (nonatomic, weak) NSView *settingsView;

@end

@implementation MRPlayerSettingsView

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        NSArray *objs = nil;
        if ([[NSBundle bundleForClass:[MRPlayerSettingsView class]] loadNibNamed:@"MRPlayerSettingsView" owner:self topLevelObjects:&objs]) {
            for (NSView * view in objs) {
                if ([view isKindOfClass:[NSView class]]) {
                    [self addSubview:view];
                    self.settingsView = view;
                    //update frame
                    CGRect rect = self.frame;
                    rect.size.height = self.settingsView.frame.size.height;
                    self.frame = rect;
                    rect.origin = CGPointZero;
                    self.settingsView.frame = rect;
                    self.settingsView.autoresizingMask = NSViewHeightSizable | NSViewWidthSizable;
                    break;
                }
            }
        }
    }
    return self;
}

- (NSResponder *)myResponder
{
    if (!self.vc) {
        NSResponder * resp = self.nextResponder;
        while (resp && ![resp isKindOfClass:[NSViewController class]]) {
            resp = resp.nextResponder;
        }
        if ([resp isKindOfClass:[NSViewController class]]) {
            self.vc = (NSViewController *)resp;
        }
    }
    return self.vc;
}

#pragma mark forwarding to viewcontroller

- (IBAction)onSelectTrack:(NSPopUpButton*)sender
{
    [self.myResponder performSelector:_cmd withObject:sender];
}

- (IBAction)onResetColorAdjust:(NSButton *)sender
{
    [self.myResponder performSelector:_cmd withObject:sender];
}

- (IBAction)onSelectFont:(NSButton *)sender
{
    [self.myResponder performSelector:_cmd withObject:sender];
}

- (IBAction)onSnapshot:(NSButton *)sender
{
    [self.myResponder performSelector:_cmd withObject:sender];
}

- (IBAction)onRestAllSettings:(NSButton *)sender
{
    [self.myResponder performSelector:_cmd withObject:sender];
}

- (void)exchangeToNextSubtitle
{
    NSInteger idx = [self.subtitlePopUpBtn indexOfSelectedItem];
    idx ++;
    if (idx >= [self.subtitlePopUpBtn numberOfItems]) {
        idx = 0;
    }
    NSMenuItem *item = [self.subtitlePopUpBtn itemAtIndex:idx];
    if (item) {
        [self.subtitlePopUpBtn selectItem:item];
        [self.subtitlePopUpBtn.target performSelector:self.subtitlePopUpBtn.action withObject:self.subtitlePopUpBtn];
    }
}

- (void)addAudioItemWithTitle:(NSString *)title
{
    [self.audioPopUpBtn addItemWithTitle:title];
}

- (void)addVideoItemWithTitle:(NSString *)title
{
    [self.videoPopUpBtn addItemWithTitle:title];
}

- (void)addSubtitleItemWithTitle:(NSString *)title
{
    [self.subtitlePopUpBtn addItemWithTitle:title];
}

- (void)removeAllAudioItems
{
    [self.audioPopUpBtn removeAllItems];
}

- (void)removeAllVideoItems
{
    [self.videoPopUpBtn removeAllItems];
}

- (void)removeAllSubtileItems
{
    [self.subtitlePopUpBtn removeAllItems];
}

- (void)removeAllItems
{
    [self removeAllAudioItems];
    [self removeAllVideoItems];
    [self removeAllSubtileItems];
}

- (void)selectAudioItemWithTitle:(NSString *)title
{
    [self.audioPopUpBtn selectItemWithTitle:title];
}

- (void)selectVideoItemWithTitle:(NSString *)title
{
    [self.videoPopUpBtn selectItemWithTitle:title];
}

- (void)selectSubtitleItemWithTitle:(NSString *)title
{
    [self.subtitlePopUpBtn selectItemWithTitle:title];
}

@end
