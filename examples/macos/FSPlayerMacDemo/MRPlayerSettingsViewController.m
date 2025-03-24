//
//  MRPlayerSettingsViewController.m
//  IJKMediaMacDemo
//
//  Created by Reach Matt on 2024/1/24.
//  Copyright © 2024 IJK Mac. All rights reserved.
//

#import "MRPlayerSettingsViewController.h"
#import <IJKMediaPlayerKit/IJKFFMoviePlayerController.h>
#import "MRCocoaBindingUserDefault.h"
#import "MRPlayerSettingsView.h"

@interface MRPlayerSettingsViewController ()

@property (weak) IBOutlet NSScrollView *scrollView;
@property (weak) IBOutlet MRPlayerSettingsView *settingsView;

@property (nonatomic, assign) BOOL use_openGL;
@property (nonatomic, copy) NSString *fcc;
@property (nonatomic, assign) int snapshot;
@property (nonatomic, assign) BOOL accurateSeek;
//for cocoa binding end

@property (nonatomic, copy) MRPlayerSettingsCloseStreamBlock closeCurrentStream;
@property (nonatomic, copy) MRPlayerSettingsExchangeStreamBlock exchangeSelectedStream;
@property (nonatomic, copy) dispatch_block_t captureShot;

@property (nonatomic, strong) NSFont *font;

@end

@implementation MRPlayerSettingsViewController

- (void)viewDidAppear
{
    [super viewDidAppear];
    NSPoint newOrigin = NSMakePoint(0, NSMaxY(self.scrollView.documentView.frame) - self.scrollView.bounds.size.height);
    [self.scrollView.contentView scrollToPoint:newOrigin];
}

- (void)exchangeToNextSubtitle
{
    [self.settingsView exchangeToNextSubtitle];
}

- (void)updateTracks:(NSDictionary *)mediaMeta
{
    int audioIdx = [mediaMeta[k_IJKM_VAL_TYPE__AUDIO] intValue];
    NSLog(@"当前音频：%d",audioIdx);
    int videoIdx = [mediaMeta[k_IJKM_VAL_TYPE__VIDEO] intValue];
    NSLog(@"当前视频：%d",videoIdx);
    int subtitleIdx = [mediaMeta[k_IJKM_VAL_TYPE__SUBTITLE] intValue];
    NSLog(@"当前字幕：%d",subtitleIdx);
    
    [self.settingsView removeAllItems];
    
    NSString *currentSubtitle = @"选择字幕";
    [self.settingsView addSubtitleItemWithTitle:currentSubtitle];
    NSString *currentAudio = @"选择音轨";
    [self.settingsView addAudioItemWithTitle:currentAudio];
    NSString *currentVideo = @"选择视轨";
    [self.settingsView addVideoItemWithTitle:currentVideo];
    
    for (NSDictionary *stream in mediaMeta[kk_IJKM_KEY_STREAMS]) {
        NSString *type = stream[k_IJKM_KEY_TYPE];
        int streamIdx = [stream[k_IJKM_KEY_STREAM_IDX] intValue];
        if ([type isEqualToString:k_IJKM_VAL_TYPE__SUBTITLE]) {
            NSLog(@"subtile meta:%@",stream);
            NSString *url = stream[k_IJKM_KEY_EX_SUBTITLE_URL];
            NSString *title = nil;
            if (url) {
                title = [[url lastPathComponent] stringByRemovingPercentEncoding];
            } else {
                title = stream[k_IJKM_KEY_TITLE];
                if (title.length == 0) {
                    title = stream[k_IJKM_KEY_LANGUAGE];
                }
                if (title.length == 0) {
                    title = @"未知";
                }
            }
            title = [NSString stringWithFormat:@"%@-%d",title,streamIdx];
            if ([mediaMeta[k_IJKM_VAL_TYPE__SUBTITLE] intValue] == streamIdx) {
                currentSubtitle = title;
            }
            [self.settingsView addSubtitleItemWithTitle:title];
        } else if ([type isEqualToString:k_IJKM_VAL_TYPE__AUDIO]) {
            NSLog(@"audio meta:%@",stream);
            NSString *title = stream[k_IJKM_KEY_TITLE];
            if (title.length == 0) {
                title = stream[k_IJKM_KEY_LANGUAGE];
            }
            if (title.length == 0) {
                title = @"未知";
            }
            title = [NSString stringWithFormat:@"%@-%d",title,streamIdx];
            if ([mediaMeta[k_IJKM_VAL_TYPE__AUDIO] intValue] == streamIdx) {
                currentAudio = title;
            }
            [self.settingsView addAudioItemWithTitle:title];
        } else if ([type isEqualToString:k_IJKM_VAL_TYPE__VIDEO]) {
            NSLog(@"video meta:%@",stream);
            NSString *title = stream[k_IJKM_KEY_TITLE];
            if (title.length == 0) {
                title = stream[k_IJKM_KEY_LANGUAGE];
            }
            if (title.length == 0) {
                title = @"未知";
            }
            title = [NSString stringWithFormat:@"%@-%d",title,streamIdx];
            if ([mediaMeta[k_IJKM_VAL_TYPE__VIDEO] intValue] == streamIdx) {
                currentVideo = title;
            }
            [self.settingsView addVideoItemWithTitle:title];
        }
    }
    [self.settingsView selectAudioItemWithTitle:currentAudio];
    [self.settingsView selectVideoItemWithTitle:currentVideo];
    [self.settingsView selectSubtitleItemWithTitle:currentSubtitle];
}

- (void)onCloseCurrentStream:(MRPlayerSettingsCloseStreamBlock)block
{
    self.closeCurrentStream = block;
}

- (void)onExchangeSelectedStream:(MRPlayerSettingsExchangeStreamBlock)block
{
    self.exchangeSelectedStream = block;
}

- (void)onCaptureShot:(dispatch_block_t)block
{
    self.captureShot = block;
}

#pragma mark 轨道设置

- (void)onSelectTrack:(NSPopUpButton*)sender
{
    if (sender.indexOfSelectedItem == 0) {
        if (self.closeCurrentStream) {
            if (sender.tag == 1) {
                self.closeCurrentStream(k_IJKM_VAL_TYPE__AUDIO);
            } else if (sender.tag == 2) {
                self.closeCurrentStream(k_IJKM_VAL_TYPE__VIDEO);
            } else if (sender.tag == 3) {
                self.closeCurrentStream(k_IJKM_VAL_TYPE__SUBTITLE);
            }
        }
    } else {
        NSString *title = sender.selectedItem.title;
        NSArray *items = [title componentsSeparatedByString:@"-"];
        int idx = [[items lastObject] intValue];
        if (sender.tag == 1) {
            NSLog(@"SelectAudioTrack:%d",idx);
        } else if (sender.tag == 2) {
            NSLog(@"SelectVideoTrack:%d",idx);
        } else if (sender.tag == 3) {
            NSLog(@"SelectSubtitleTrack:%d",idx);
        }
        
        if (self.exchangeSelectedStream) {
            self.exchangeSelectedStream(idx);
        }
    }
}

- (void)onResetColorAdjust:(NSButton *)sender
{
    int tag = (int)sender.tag;
    NSString *key = nil;
    if (tag == 1) {
        key = @"color_adjust_brightness";
    } else if (tag == 2){
        key = @"color_adjust_saturation";
    } else if (tag == 3){
        key = @"color_adjust_contrast";
    }
    if (key) {
        [MRCocoaBindingUserDefault resetValueForKey:key];
    }
}

- (void)changeFont:(NSFontManager *)sender
{
    self.font = [[NSFontPanel sharedFontPanel] panelConvertFont:self.font];
    [MRCocoaBindingUserDefault setFontName:self.font.fontName];
}

- (void)onSelectFont:(NSButton *)sender
{
    NSFontManager *fontManager = [NSFontManager sharedFontManager];
    [fontManager setTarget:self];
    NSFontPanel *panel = [fontManager fontPanel:YES];
    int fontSize = [MRCocoaBindingUserDefault subtitle_scale] * 50;
    NSFont *font = [NSFont fontWithName:[MRCocoaBindingUserDefault FontName] size:fontSize];
    if (!font) {
        font = [NSFont systemFontOfSize:fontSize];
    }
    self.font = font;
    [panel setPanelFont:self.font isMultiple:NO];
    [[self.view window] makeFirstResponder:panel];
    [panel orderFront:self];
}

- (void)onSnapshot:(NSButton *)sender
{
    if (self.captureShot) {
        self.captureShot();
    }
}

- (void)onRestAllSettings:(NSButton *)sender
{
    [MRCocoaBindingUserDefault resetAll];
}
@end
