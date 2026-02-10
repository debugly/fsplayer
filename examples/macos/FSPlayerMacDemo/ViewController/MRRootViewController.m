//
//  MRRootViewController.m
//  FSPlayerMacDemo
//
//  Created by debugly on 2021/11/1.
//  Copyright © 2021 FSPlayer Mac. All rights reserved.
//

#import "MRRootViewController.h"
#import "MRDragView.h"
#import "MRUtil+SystemPanel.h"
#import <FSPlayer/FSPlayer.h>
#import "NSFileManager+Sandbox.h"
#import "SHBaseView.h"
#import <Quartz/Quartz.h>
#import <Carbon/Carbon.h>
#import "MRGlobalNotification.h"
#import "AppDelegate.h"
#import "MRProgressIndicator.h"
#import "MRBaseView.h"
#import "MultiRenderSample.h"
#import "NSString+Ex.h"
#import "MRPlayerSettingsViewController.h"
#import "MRPlaylistViewController.h"
#import "MRCocoaBindingUserDefault.h"

static NSString* lastPlayedKey = @"__lastPlayedKey";
static BOOL hdrAnimationShown = 0;

@interface MRRootViewController ()<MRDragViewDelegate,SHBaseViewDelegate,NSMenuDelegate,FSVideoRenderingDelegate>

@property (nonatomic, weak) IBOutlet NSView *playerContainer;
@property (nonatomic, weak) IBOutlet NSView *siderBarContainer;
@property (weak) IBOutlet NSLayoutConstraint *siderBarWidthConstraint;

@property (nonatomic, weak) IBOutlet NSView *playerCtrlPanel;

@property (nonatomic, weak) IBOutlet NSTextField *playedTimeLb;
@property (nonatomic, weak) IBOutlet NSTextField *durationTimeLb;
@property (nonatomic, weak) IBOutlet NSButton *playCtrlBtn;
@property (nonatomic, weak) IBOutlet MRProgressIndicator *playerSlider;

@property (nonatomic, weak) IBOutlet NSTextField *seekCostLb;
@property (nonatomic, weak) NSTrackingArea *trackingArea;

@property (nonatomic, assign) BOOL seeking;
@property (nonatomic, weak) id eventMonitor;

//
@property (nonatomic, assign) int tickCount;

//player
@property (nonatomic, strong) FSPlayer * player;
@property (nonatomic, strong) NSMutableArray *playList;
@property (nonatomic, strong) NSMutableArray *subtitles;
@property (nonatomic, assign) int lastSubIdx;

@property (nonatomic, copy) NSString *playingUrl;
@property (nonatomic, weak) NSTimer *tickTimer;
@property (nonatomic, assign, getter=isUsingHardwareAccelerate) BOOL usingHardwareAccelerate;


@property (nonatomic, assign) BOOL shouldShowHudView;

@property (nonatomic, assign) BOOL loop;


@end

@implementation MRRootViewController

- (void)dealloc
{
    if (self.tickTimer) {
        [self.tickTimer invalidate];
        self.tickTimer = nil;
        self.tickCount = 0;
    }
    
    [NSEvent removeMonitor:self.eventMonitor];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do view setup here.
    
    //for debug
    //[self.view setWantsLayer:YES];
    //self.view.layer.backgroundColor = [[NSColor redColor] CGColor];
    self.title = @"Root";
    self.seekCostLb.stringValue = @"";
    self.loop = 0;
    self.lastSubIdx = -1;
    
    if ([self.view isKindOfClass:[SHBaseView class]]) {
        SHBaseView *baseView = (SHBaseView *)self.view;
        baseView.delegate = self;
        baseView.needTracking = YES;
    }

    __weakSelf__
    self.eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent * _Nullable(NSEvent * _Nonnull theEvent) {
        __strongSelf__
        if (theEvent.window == self.view.window && [theEvent keyCode] == kVK_ANSI_Period && theEvent.modifierFlags & NSEventModifierFlagCommand){
            [self onStop];
            return nil;
        }
        return theEvent;
    }];
    
    OBSERVER_NOTIFICATION(self, _playExplorerMovies:,kPlayExplorerMovieNotificationName_G, nil);
    OBSERVER_NOTIFICATION(self, _playNetMovies:,kPlayNetMovieNotificationName_G, nil);
    [self prepareRightMenu];
    
    [self.playerSlider onDraggedIndicator:^(double progress, MRProgressIndicator * _Nonnull indicator, BOOL isEndDrag) {
        __strongSelf__
        if (isEndDrag) {
            [self seekTo:progress * indicator.maxValue];
            if (!self.tickTimer) {
                self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.03 target:self selector:@selector(onTick:) userInfo:nil repeats:YES];
            }
        } else {
            if (self.tickTimer) {
                [self.tickTimer invalidate];
                self.tickTimer = nil;
                self.tickCount = 0;
            }
            int interval = progress * indicator.maxValue;
            self.playedTimeLb.stringValue = [NSString stringWithFormat:@"%02d:%02d",(int)(interval/60),(int)(interval%60)];
        }
    }];
    
    self.playedTimeLb.stringValue = @"--:--";
    self.durationTimeLb.stringValue = @"--:--";
    
//    [self.siderBarContainer setWantsLayer:YES];
//    self.siderBarContainer.layer.backgroundColor = NSColor.redColor.CGColor;
    
    [self observerCocoaBingsChange];
}

- (void)prepareRightMenu
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Root"];
    menu.delegate = self;
    self.view.menu = menu;
}

- (void)menuWillOpen:(NSMenu *)menu
{
    if (menu == self.view.menu) {
        
        [menu removeAllItems];
        
        [menu addItemWithTitle:@"打开文件" action:@selector(openFile:)keyEquivalent:@""];
        
        if (self.playingUrl) {
            if ([self.player isPlaying]) {
                [menu addItemWithTitle:@"暂停" action:@selector(pauseOrPlay:)keyEquivalent:@""];
            } else {
                [menu addItemWithTitle:@"播放" action:@selector(pauseOrPlay:)keyEquivalent:@""];
            }
            [menu addItemWithTitle:@"重播" action:@selector(retry) keyEquivalent:@""];
            [menu addItemWithTitle:@"停止" action:@selector(onStop) keyEquivalent:@"."];
            [menu addItemWithTitle:@"下一集" action:@selector(playNext:)keyEquivalent:@""];
            [menu addItemWithTitle:@"上一集" action:@selector(playPrevious:)keyEquivalent:@""];
            
            [menu addItemWithTitle:@"前进10s" action:@selector(fastForward:)keyEquivalent:@""];
            [menu addItemWithTitle:@"后退10s" action:@selector(fastRewind:)keyEquivalent:@""];
            
            NSMenuItem *speedItem = [menu addItemWithTitle:@"倍速" action:nil keyEquivalent:@""];
            
            [menu setSubmenu:({
                NSMenu *menu = [[NSMenu alloc] initWithTitle:@"倍速"];
                menu.delegate = self;
                ;menu;
            }) forItem:speedItem];
        } else {
            if ([self.playList count] > 0) {
                [menu addItemWithTitle:@"下一集" action:@selector(playNext:)keyEquivalent:@""];
                [menu addItemWithTitle:@"上一集" action:@selector(playPrevious:)keyEquivalent:@""];
            }
        }
    } else if ([menu.title isEqualToString:@"倍速"]) {
        [menu removeAllItems];
        [menu addItemWithTitle:@"0.01x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 1;
        [menu addItemWithTitle:@"0.8x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 80;
        [menu addItemWithTitle:@"1.0x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 100;
        [menu addItemWithTitle:@"1.25x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 125;
        [menu addItemWithTitle:@"1.5x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 150;
        [menu addItemWithTitle:@"2.0x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 200;
        [menu addItemWithTitle:@"3.0x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 300;
        [menu addItemWithTitle:@"4.0x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 400;
        [menu addItemWithTitle:@"5.0x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 500;
        [menu addItemWithTitle:@"20x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 2000;
    }
}

- (void)openFile:(NSMenuItem *)sender
{
    AppDelegate *delegate = NSApp.delegate;
    [delegate openDocument:sender];
}

- (void)_playExplorerMovies:(NSNotification *)notifi
{
    NSDictionary *info = notifi.userInfo;
    NSArray *movies = info[@"obj"];
    
    if ([movies count] > 0) {
        // 追加到列表，开始播放
        [self appendToPlayList:movies append:NO];
    }
}

- (void)_playNetMovies:(NSNotification *)notifi
{
    NSDictionary *info = notifi.userInfo;
    NSArray *links = info[@"links"];
    NSMutableArray *videos = [NSMutableArray array];
    
    for (NSString *link in links) {
        [videos addObject:link];
    }
    
    if ([videos count] > 0) {
        // 开始播放
        [self.playList removeAllObjects];
        [self.playList addObjectsFromArray:videos];
        [self onStop];
        [self playFirstIfNeed];
    }
}

- (MRPlayerSettingsViewController *)findSettingViewController {
    MRPlayerSettingsViewController *settings = nil;
    for (NSViewController *vc in self.childViewControllers) {
        if ([vc isKindOfClass:[MRPlayerSettingsViewController class]]) {
            settings = (MRPlayerSettingsViewController *)vc;
            break;
        }
    }
    return settings;
}

- (void)showPlayerSettingsSideBar
{
    if (self.siderBarWidthConstraint.constant > 0) {
        __weakSelf__
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
            context.duration = 0.35;
            context.allowsImplicitAnimation = YES;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            __strongSelf__
            [self.siderBarContainer.animator layoutSubtreeIfNeeded];
            self.siderBarWidthConstraint.animator.constant = 0;
            [self.siderBarContainer.animator setNeedsLayout:YES];
        }];
    } else {
        MRPlayerSettingsViewController *settings = [self findSettingViewController];
        BOOL created = NO;
        if (!settings) {
            settings = [[MRPlayerSettingsViewController alloc] initWithNibName:@"MRPlayerSettingsViewController" bundle:nil];
            __weakSelf__
            [settings onCloseCurrentStream:^(NSString * _Nonnull st) {
                __strongSelf__
                [self.player closeCurrentStream:st];
            }];
            
            [settings onExchangeSelectedStream:^(int idx) {
                __strongSelf__
                [self.player exchangeSelectedStream:idx];
            }];
            
            [settings onCaptureShot:^{
                __strongSelf__
                [self onCaptureShot];
            }];
            
            created = YES;
            [self addChildViewController:settings];
        }
        [self.siderBarContainer addSubview:settings.view];
        CGRect frame = settings.view.bounds;
        frame.size = CGSizeMake(frame.size.width, self.siderBarContainer.bounds.size.height);
        settings.view.frame = frame;

        if (created) {
            [self updateStreams];
        }
        
        __weakSelf__
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
            context.duration = 0.35;
            context.allowsImplicitAnimation = YES;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            __strongSelf__
            [self.siderBarContainer.animator layoutSubtreeIfNeeded];
            self.siderBarWidthConstraint.animator.constant = frame.size.width;
            [self.siderBarContainer.animator setNeedsLayout:YES];
        }];
    }
}

- (void)toggleTitleBar:(BOOL)show
{
    if (!show && !self.playingUrl) {
        return;
    }
    
    if (show == self.view.window.titlebarAppearsTransparent) {
        self.view.window.titlebarAppearsTransparent = !show;
        self.view.window.titleVisibility = show ? NSWindowTitleVisible : NSWindowTitleHidden;
        [[self.view.window standardWindowButton:NSWindowCloseButton] setHidden:!show];
        [[self.view.window standardWindowButton:NSWindowMiniaturizeButton] setHidden:!show];
        [[self.view.window standardWindowButton:NSWindowZoomButton] setHidden:!show];
        
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
            context.duration = 0.45;
            self.playerCtrlPanel.animator.alphaValue = show ? 1.0 : 0.0;
        }];
    }
}

- (void)baseView:(SHBaseView *)baseView mouseEntered:(NSEvent *)event
{
    if ([event locationInWindow].y > self.view.bounds.size.height - 35) {
        return;
    }
    [self toggleTitleBar:YES];
}

- (void)baseView:(SHBaseView *)baseView mouseMoved:(NSEvent *)event
{
    if ([event locationInWindow].y > self.view.bounds.size.height - 35) {
        return;
    }
    [self toggleTitleBar:YES];
}

- (void)baseView:(SHBaseView *)baseView mouseExited:(NSEvent *)event
{
    [self toggleTitleBar:NO];
}

- (void)keyDown:(NSEvent *)event
{
    if (event.window != self.view.window) {
        return;
    }
    
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        switch ([event keyCode]) {
            case kVK_LeftArrow:
            {
                [self playPrevious:nil];
            }
                break;
            case kVK_RightArrow:
            {
                [self playNext:nil];
            }
                break;
            case kVK_ANSI_B:
            {
                
            }
                break;
            case kVK_ANSI_R:
            {
                FSRotatePreference preference = self.player.view.rotatePreference;
                
                if (preference.type == FSRotateNone) {
                    preference.type = FSRotateZ;
                }
                
                if (event.modifierFlags & NSEventModifierFlagOption) {
                    
                    preference.type --;
                    
                    if (preference.type <= FSRotateNone) {
                        preference.type = FSRotateZ;
                    }
                }
                
                if (event.modifierFlags & NSEventModifierFlagShift) {
                    preference.degrees --;
                } else {
                    preference.degrees ++;
                }
                
                if (preference.degrees >= 360) {
                    preference.degrees = 0;
                }
                self.player.view.rotatePreference = preference;
                if (!self.player.isPlaying) {
                    [self.player.view setNeedsRefreshCurrentPic];
                }
                NSLog(@"rotate:%@ %d",@[@"X",@"Y",@"Z"][preference.type-1],(int)preference.degrees);
            }
                break;
            case kVK_ANSI_S:
            {
                [self onCaptureShot];
            }
                break;
            case kVK_ANSI_Period:
            {
                [self onStop];
            }
                break;
            case kVK_ANSI_H:
            {
                if (event.modifierFlags & NSEventModifierFlagShift) {
                    [self onToggleHUD:nil];
                }
            }
                break;
            case kVK_ANSI_D:
            {
                [self retry];
            }
                break;
            default:
            {
                NSLog(@"0x%X",[event keyCode]);
            }
                break;
        }
    } else if (event.modifierFlags & NSEventModifierFlagControl) {
        switch ([event keyCode]) {
            case kVK_ANSI_H:
            {
                
            }
                break;
            case kVK_ANSI_S:
            {
                //快速切换字幕
                NSDictionary *dic = self.player.monitor.mediaMeta;
                int currentIdx = [dic[FS_VAL_TYPE__SUBTITLE] intValue];
                int position = -1;
                NSMutableArray *subStreamIdxArr = [NSMutableArray array];
                for (NSDictionary *stream in dic[FS_KEY_STREAMS]) {
                    NSString *type = stream[FS_KEY_STREAM_TYPE];
                    if ([type isEqualToString:FS_VAL_TYPE__SUBTITLE]) {
                        int streamIdx = [stream[FS_KEY_STREAM_IDX] intValue];
                        if (currentIdx == streamIdx) {
                            position = (int)[subStreamIdxArr count];
                        }
                        [subStreamIdxArr addObject:@(streamIdx)];
                    }
                }
                position++;
                if (position >= [subStreamIdxArr count]) {
                    position = 0;
                }
                [self.player exchangeSelectedStream:[subStreamIdxArr[position] intValue]];
            }
                break;
        }
    } else if (event.modifierFlags & NSEventModifierFlagOption) {
        switch ([event keyCode]) {
            case kVK_ANSI_S:
            {
                //loop exchange subtitles
#warning TODO exchangeToNextSubtitle
            }
                break;
        }
    }  else {
        switch ([event keyCode]) {
            case kVK_RightArrow:
            {
                [self fastForward:nil];
            }
                break;
            case kVK_LeftArrow:
            {
                [self fastRewind:nil];
            }
                break;
            case kVK_DownArrow:
            {
                float volume = [MRCocoaBindingUserDefault volume];
                volume -= 0.1;
                if (volume < 0) {
                    volume = .0f;
                }
                [MRCocoaBindingUserDefault setVolume:volume];
                [self onVolumeChange:nil];
            }
                break;
            case kVK_UpArrow:
            {
                float volume = [MRCocoaBindingUserDefault volume];
                volume += 0.1;
                if (volume > 1) {
                    volume = 1.0f;
                }
                [MRCocoaBindingUserDefault setValue:@(volume) forKey:@"volume"];
                [self onVolumeChange:nil];
            }
                break;
            case kVK_Space:
            {
                [self pauseOrPlay:nil];
            }
                break;
            case kVK_ANSI_Minus:
            {
                if (self.player) {
                    float delay = self.player.currentSubtitleExtraDelay;
                    delay -= 2;
                    self.player.currentSubtitleExtraDelay = delay;
                }
            }
                break;
            case kVK_ANSI_Equal:
            {
                if (self.player) {
                    float delay = self.player.currentSubtitleExtraDelay;
                    delay += 2;
                    self.player.currentSubtitleExtraDelay = delay;
                }
            }
                break;
            case kVK_Escape:
            {
                if (self.view.window.styleMask & NSWindowStyleMaskFullScreen) {
                    [self.view.window toggleFullScreen:nil];
                }
            }
                break;
            case kVK_Return:
            {
                if (!(self.view.window.styleMask & NSWindowStyleMaskFullScreen)) {
                    [self.view.window toggleFullScreen:nil];
                }
            }
                break;
            default:
            {
                NSLog(@"keyCode:0x%X",[event keyCode]);
            }
                break;
        }
    }
}

- (NSMutableArray <NSString *> *)playList
{
    if (!_playList) {
        _playList = [NSMutableArray array];
    }
    return _playList;
}

- (NSMutableArray *)subtitles
{
    if (!_subtitles) {
        _subtitles = [NSMutableArray array];
    }
    return _subtitles;
}

- (void)perpareIJKPlayer:(NSString *)urlStr hwaccel:(BOOL)hwaccel isLive:(BOOL)isLive
{
    if (self.playingUrl) {
        [self doStopPlay];
    }
    
    self.playingUrl = urlStr;
    self.seeking = NO;
    
    FSOptions *options = [FSOptions optionsByDefault];
    
    //isLive表示是直播还是点播
    if (isLive) {
        // Param for living
        [options setPlayerOptionIntValue:1 forKey:@"infbuf"];
        [options setPlayerOptionIntValue:0 forKey:@"packet-buffering"];
    } else {
        // Param for playback
        [options setPlayerOptionIntValue:0 forKey:@"infbuf"];
        [options setPlayerOptionIntValue:1 forKey:@"packet-buffering"];
    }
    
    //视频帧处理不过来的时候丢弃一些帧达到同步的效果
    [options setPlayerOptionIntValue:1 forKey:@"framedrop"];
    [options setPlayerOptionIntValue:6      forKey:@"video-pictq-size"];
    //    [options setPlayerOptionIntValue:50000      forKey:@"min-frames"];
    [options setPlayerOptionIntValue:119     forKey:@"max-fps"];
    [options setPlayerOptionIntValue:self.loop?0:1      forKey:@"loop"];
#warning todo de_interlace
    // [options setCodecOptionIntValue:FS_AVDISCARD_DEFAULT forKey:@"skip_loop_filter"];
    //for mgeg-ts seek
    [options setFormatOptionIntValue:1 forKey:@"seek_flag_keyframe"];
    //    default is 5000000,but some high bit rate video probe faild cause no audio.
    [options setFormatOptionValue:@"10000000" forKey:@"probesize"];
    //    [options setFormatOptionValue:@"1" forKey:@"flush_packets"];
    //    [options setPlayerOptionIntValue:0      forKey:@"packet-buffering"];
    //    [options setPlayerOptionIntValue:1      forKey:@"render-wait-start"];
    //    [options setCodecOptionIntValue:1 forKey:@"allow_software"];
    //    test video decoder performance.
    //    [options setPlayerOptionIntValue:1 forKey:@"an"];
    //    [options setPlayerOptionIntValue:1 forKey:@"nodisp"];
    
    [options setPlayerOptionIntValue:[MRCocoaBindingUserDefault copy_hw_frame] forKey:@"copy_hw_frame"];
    //图片不使用 cvpixelbufferpool
    NSString *ext = [[urlStr pathExtension] lowercaseString];
    if ([[MRUtil pictureType] containsObject:ext]) {
        [options setPlayerOptionIntValue:0      forKey:@"enable-cvpixelbufferpool"];
        if ([@"gif" isEqualToString:ext] || [@"webp" isEqualToString:ext]) {
            [options setPlayerOptionIntValue:-1      forKey:@"loop"];
        }
    }
    [options setFormatOptionIntValue:0 forKey:@"http_persistent"];
    //请求m3u8文件里的ts出错后是否继续请求下一个ts，默认是3
    [options setFormatOptionIntValue:1 forKey:@"max_reload"];
    //set icy update period
    [options setPlayerOptionValue:@"3500" forKey:@"icy-update-period"];
    
    
    //    [options setPlayerOptionValue:@"fcc-bgra"        forKey:@"overlay-format"];
    //    [options setPlayerOptionValue:@"fcc-bgr0"        forKey:@"overlay-format"];
    //    [options setPlayerOptionValue:@"fcc-argb"        forKey:@"overlay-format"];
    //    [options setPlayerOptionValue:@"fcc-0rgb"        forKey:@"overlay-format"];
    //    [options setPlayerOptionValue:@"fcc-uyvy"        forKey:@"overlay-format"];
    //    [options setPlayerOptionValue:@"fcc-i420"        forKey:@"overlay-format"];
    //    [options setPlayerOptionValue:@"fcc-nv12"        forKey:@"overlay-format"];
    
    //[options setPlayerOptionIntValue:1 forKey:@"subtitle-texture-reuse"];
    [options setPlayerOptionValue:[MRCocoaBindingUserDefault overlay_format] forKey:@"overlay-format"];
    [options setPlayerOptionIntValue:hwaccel forKey:@"videotoolbox_hwaccel"];
    [options setPlayerOptionIntValue:[MRCocoaBindingUserDefault accurate_seek] forKey:@"enable-accurate-seek"];
    [options setPlayerOptionIntValue:1500 forKey:@"accurate-seek-timeout"];
    options.metalRenderer = ![MRCocoaBindingUserDefault use_opengl];
    options.showHudView = self.shouldShowHudView;
    //指定使用 HTTP 1.0 Basic auth 授权认证，可避免一次试探请求。重定向后仍旧有效
    [options setFormatOptionValue:@"1" forKey:@"auth_type2"];
    
    //默认不使用dns缓存，指定超时时间才会使用；
    if ([MRCocoaBindingUserDefault use_dns_cache]) {
        [options setFormatOptionIntValue:[MRCocoaBindingUserDefault dns_cache_period] * 1000 forKey:@"dns_cache_timeout"];
        [options setFormatOptionValue:@"connect_timeout,ijkapplication,selected_http,addrinfo_one_by_one,addrinfo_timeout,dns_cache_timeout,fastopen,dns_cache_clear" forKey:@"seg_inherit_options"];
    } else {
        [options setFormatOptionValue:@"ijkapplication,selected_http" forKey:@"seg_inherit_options"];
    }
    
    if ([MRCocoaBindingUserDefault open_gzip]) {
        [options setFormatOptionValue:@"Accept-Encoding: gzip, deflate" forKey:@"headers"];
    }
    
//    [options setFormatOptionIntValue:1 forKey:@"multiple_requests"];
//    [options setFormatOptionIntValue:1 forKey:@"http_persistent"];
    //实际测试效果不好，容易导致域名解析失败，谨慎使用;没有fallback逻辑
    //决定dns的方式，大于0时使用tcp_getaddrinfo_nonblock方式
    //[options setFormatOptionIntValue:0 forKey:@"addrinfo_timeout"];
    //[options setFormatOptionIntValue:0 forKey:@"addrinfo_one_by_one"];
       
    //    [options setFormatOptionValue:@"test=cookie" forKey:@"cookies"];
    //if you want set ts segments options only:
    //    [options setFormatOptionValue:@"fastopen=2:dns_cache_timeout=600000:addrinfo_timeout=2000000" forKey:@"seg_format_options"];
    //default inherit options : "headers", "user_agent", "cookies", "http_proxy", "referer", "rw_timeout", "icy",you can inherit more:
    
    //protocolWhitelist need set to httpproxy
    //options.protocolWhitelist = @"httpproxy";
    //[options setFormatOptionValue:@"http://127.0.0.1:8888" forKey:@"http_proxy"];
    //[options setFormatOptionValue:@"Referer: https://example.com\r\nOrigin: https://example.com\r\nUser-Agent: MyApp" forKey:@"headers"];
    //when headers contain User-Agent,that will override the user_agent key
    //[options setFormatOptionValue:@"MyUserAgent" forKey:@"user_agent"];
    
    NSMutableArray *dus = [NSMutableArray array];
    BOOL isFileProtocol = [urlStr hasPrefix:@"file"] || [urlStr hasPrefix:@"/"];
    if (isFileProtocol && [urlStr.pathExtension isEqualToString:@"m3u8"]) {
        NSString *str = [[NSString alloc] initWithContentsOfFile:urlStr encoding:NSUTF8StringEncoding error:nil];
        NSArray *lines = [str componentsSeparatedByString:@"\n"];
        double sum = 0;
        for (NSString *line in lines) {
            if ([line hasPrefix:@"#EXTINF"]) {
                NSArray *items = [line componentsSeparatedByString:@":"];
                NSString *du = [[[items lastObject] componentsSeparatedByString:@","] firstObject];
                if (du) {
                    sum += [du doubleValue];
                    [dus addObject:@(sum)];
                }
            } else {
                continue;
            }
        }
    }
    self.playerSlider.tags = dus;
    
    [NSDocumentController.sharedDocumentController noteNewRecentDocumentURL:[NSURL URLWithString:urlStr]];
    
    int use_cache = 0;
    if (use_cache == 1) {
        NSString *cacheKey = [urlStr md5Hash];
        NSString *fileName = [urlStr lastPathComponent];
        if (fileName.length < 1) {
            fileName = cacheKey;
        }
        NSString *cacheDir = [NSFileManager mr_DirWithType:NSCachesDirectory WithPathComponents:@[@".fsplayer",cacheKey]];
        NSString *cacheFile = [cacheDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.tmp",fileName]];
        NSString *mapFile = [cacheDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-map.tmp",fileName]];
        
        [options setFormatOptionValue:cacheFile forKey:@"cache_file_path"];
        [options setFormatOptionValue:mapFile forKey:@"cache_map_path"];
        [options setFormatOptionValue:@"1" forKey:@"auto_save_map"];
        [options setFormatOptionValue:@"1" forKey:@"parse_cache_map"];
        
        urlStr = [NSString stringWithFormat:@"ijkio:cache:ffio:%@",urlStr];

        [options setPlayerOptionValue:@"5242880" forKey:@"max-buffer-size"];
    } else if (use_cache == 2) {
        urlStr = [NSString stringWithFormat:@"cache:%@",urlStr];
        options.protocolWhitelist = @"cache";
        [options setPlayerOptionValue:@"52428800" forKey:@"max-buffer-size"];
    }
    
//    test preload http
//    [options setFormatOptionValue:@"ijkhttp2" forKey:@"selected_http"];
//    options.protocolWhitelist = @"ijkhttp2";
    options.protocolWhitelist = @"ftp";
    
    self.player = [[FSPlayer alloc] initWithContent:urlStr options:options];
    
    NSView <FSVideoRenderingProtocol>*playerView = self.player.view;
    playerView.frame = self.playerContainer.bounds;
    playerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.playerContainer addSubview:playerView positioned:NSWindowBelow relativeTo:self.playerCtrlPanel];
    
    playerView.showHdrAnimation = !hdrAnimationShown;
    //playerView.preventDisplay = YES;
    //test
    [playerView setBackgroundColor:240 g:0 b:0];
    [playerView setDisplayDelegate:self];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerOpenInput:) name:FSPlayerOpenInputNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerFindStreamInfo:) name:FSPlayerFindStreamInfoNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerPreparedToPlay:) name:FSPlayerIsPreparedToPlayNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerFirstVideoFrameRendered:) name:FSPlayerFirstVideoFrameRenderedNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerSelectedStreamDidChange:) name:FSPlayerSelectedStreamDidChangeNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerDidFinish:) name:FSPlayerDidFinishNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerCouldNotFindCodec:) name:FSPlayerNoCodecFoundNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerNaturalSizeAvailable:) name:FSPlayerNaturalSizeAvailableNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerAfterSeekFirstVideoFrameDisplay:) name:FSPlayerAfterSeekFirstVideoFrameDisplayNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerVideoDecoderFatal:) name:FSPlayerVideoDecoderFatalNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerRecvWarning:) name:FSPlayerRecvWarningNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerHdrAnimationStateChanged:) name:FSPlayerHDRAnimationStateChanged object:self.player.view];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerSelectingStreamDidFailed:) name:FSPlayerSelectingStreamDidFailed object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerICYMetaChanged:) name:FSPlayerICYMetaChangedNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackStateDidChange:) name:FSPlayerPlaybackStateDidChangeNotification object:self.player];

    self.player.shouldAutoplay = YES;
    [self onVolumeChange:nil];
    [self applyScalingMode];
    [self applyDAR];
    [self applyRotate];
    [self applyBSC];
    [self applySubtitlePreference];
}

#pragma mark - ijkplayer notifi

- (void)ijkPlayerOpenInput:(NSNotification *)notifi
{
    if (self.player == notifi.object) {
        NSLog(@"[stat] stream opened:%@",notifi.userInfo[@"name"]);
        NSLog(@"[stat] open input cost:%lldms",self.player.monitor.openInputLatency);
    }
}

- (void)ijkPlayerFindStreamInfo:(NSNotification *)notifi
{
    if (self.player == notifi.object) {
        NSLog(@"[stat] find stream info cost:%lldms",self.player.monitor.findStreamInfoLatency);
    }
}

- (void)ijkPlayerPreparedToPlay:(NSNotification *)notifi
{
    if (self.player == notifi.object) {
        NSLog(@"[stat] prepared to play cost:%lldms",self.player.monitor.prepareLatency);
        [self printICYMeta];
        [self updateStreams];
        NSDictionary *dic = self.player.monitor.mediaMeta;
        NSString *lrc = dic[FS_KEY_LYRICS];
        if (lrc.length > 0) {
            NSString *dir = [self dirForCurrentPlayingUrl];
            NSString *movieName = [self.playingUrl lastPathComponent];
            NSString *fileName = [NSString stringWithFormat:@"%@.lrc",movieName];
            NSString *filePath = [dir stringByAppendingPathComponent:fileName];
            NSLog(@"保存成LRC文件:%@",filePath);
            [[lrc dataUsingEncoding:NSUTF8StringEncoding] writeToFile:filePath atomically:YES];
        }
    }
}

- (void)ijkPlayerFirstVideoFrameRendered:(NSNotification *)notifi
{
    if (self.player == notifi.object) {
        NSLog(@"[stat] first frame cost:%lldms",self.player.monitor.firstVideoFrameLatency);
        self.seekCostLb.stringValue = [NSString stringWithFormat:@"%lldms",self.player.monitor.firstVideoFrameLatency];
    }
}

- (void)ijkPlayerRecvWarning:(NSNotification *)notifi
{
    if (self.player == notifi.object) {
        int reason = [notifi.userInfo[FSPlayerWarningReasonUserInfoKey] intValue];
        if (reason == 1000) {
            NSLog(@"recv warning:%d",reason);
            //会收到很多次，所以立马取消掉监听
            [[NSNotificationCenter defaultCenter] removeObserver:self name:FSPlayerRecvWarningNotification object:notifi.object];
            [self retry];
        }
    }
}

- (void)ijkPlayerHdrAnimationStateChanged:(NSNotification *)notifi
{
    if (self.player.view == notifi.object) {
        int state = [notifi.userInfo[@"state"] intValue];
        if (state == 1) {
            NSLog(@"hdr animation is begin.");
        } else if (state == 2) {
            NSLog(@"hdr animation is end.");
            hdrAnimationShown = 1;
        }
    }
}

- (void)ijkPlayerSelectingStreamDidFailed:(NSNotification *)notifi
{
    if (self.player == notifi.object) {
        int stream = [notifi.userInfo[FSPlayerSelectingStreamIDUserInfoKey] intValue];
        int preStream = [notifi.userInfo[FSPlayerPreSelectingStreamIDUserInfoKey] intValue];
        
        int code = [notifi.userInfo[FSPlayerSelectingStreamErrUserInfoKey] intValue];
        NSLog(@"Selecting Stream Did Failed:%d, pre selected stream is %d,Err Code:%d",stream,preStream,code);
    }
}

- (void)ijkPlayerVideoDecoderFatal:(NSNotification *)notifi
{
    if (self.player == notifi.object) {
        if (self.isUsingHardwareAccelerate) {
            self.usingHardwareAccelerate = NO;
            NSLog(@"decoder fatal:%@;close videotoolbox hwaccel.",notifi.userInfo);
            NSString *playingUrl = self.playingUrl;
            [self onStop];
            [self playURL:playingUrl];
            return;
        }
    }
    NSLog(@"decoder fatal:%@",notifi.userInfo);
}

- (void)ijkPlayerAfterSeekFirstVideoFrameDisplay:(NSNotification *)notifi
{
    NSLog(@"seek cost time:%@ms",notifi.userInfo[@"du"]);
//    self.seeking = NO;
    self.seekCostLb.stringValue = [NSString stringWithFormat:@"%@ms",notifi.userInfo[@"du"]];
//    //seek 完毕后仍旧是播放状态就开始播放
//    if (self.playCtrlBtn.state == NSControlStateValueOff) {
//        [self.player play];
//    }
}

- (void)ijkPlayerCouldNotFindCodec:(NSNotification *)notifi
{
    NSLog(@"找不到解码器，联系开发小帅锅：%@",notifi.userInfo);
}

- (void)videoRenderingDidDisplay:(id<FSVideoRenderingProtocol>)renderer attach:(FSOverlayAttach *)attach
{
    //NSLog(@"当前帧：%@",attach);
}

- (void)applyLockScreenRatio
{
    const CGSize videoSize = self.player.naturalSize;
    if (CGSizeEqualToSize(CGSizeZero, videoSize)) {
        return;
    }
    const CGRect screenVisibleFrame = self.view.window.screen.visibleFrame;
    const CGSize screenSize = screenVisibleFrame.size;
    CGSize targetSize = videoSize;
    
    if (videoSize.width > screenSize.width || videoSize.height > screenSize.height) {
        float wRatio = screenSize.width / videoSize.width;
        float hRatio = screenSize.height / videoSize.height;
        float ratio  = MIN(wRatio, hRatio);
        targetSize = CGSizeMake(floor(videoSize.width * ratio), floor(videoSize.height * ratio));
    }
    [self.view.window setAspectRatio:targetSize];
    
    CGRect targetRect = CGRectMake(screenVisibleFrame.origin.x + (screenSize.width - targetSize.width) / 2.0, screenVisibleFrame.origin.y + (screenSize.height - targetSize.height) / 2.0, targetSize.width, targetSize.height);
    
    NSLog(@"窗口位置:%@;视频尺寸：%@",NSStringFromRect(targetRect),NSStringFromSize(videoSize));
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
        [self.view.window.animator setFrame:targetRect display:YES];
    }];
}
- (void)ijkPlayerNaturalSizeAvailable:(NSNotification *)notifi
{
    if (self.player == notifi.object && [MRCocoaBindingUserDefault lock_screen_ratio]) {
        [self applyLockScreenRatio];
    }
}

- (void)ijkPlayerDidFinish:(NSNotification *)notifi
{
    if (self.player == notifi.object) {
        int reason = [notifi.userInfo[FSPlayerDidFinishReasonUserInfoKey] intValue];
        if (FSFinishReasonPlaybackError == reason) {
            int errCode = [notifi.userInfo[@"code"] intValue];
            NSLog(@"播放出错:%d",errCode);
            NSAlert *alert = [[NSAlert alloc] init];
            alert.informativeText = self.player.content;
            alert.messageText = [NSString stringWithFormat:@"%@",notifi.userInfo[@"msg"]];
            
            if ([self.playList count] > 1) {
                [alert addButtonWithTitle:@"Next"];
            }
            [alert addButtonWithTitle:@"Retry"];
            [alert addButtonWithTitle:@"OK"];
            [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
                if ([[alert buttons] count] == 3) {
                    if (returnCode == NSAlertFirstButtonReturn) {
                        [self playNext:nil];
                    } else if (returnCode == NSAlertSecondButtonReturn) {
                        //retry
                        [self retry];
                    } else {
                        //
                    }
                } else if ([[alert buttons] count] == 2) {
                    if (returnCode == NSAlertFirstButtonReturn) {
                        //retry
                        [self retry];
                    } else if (returnCode == NSAlertSecondButtonReturn) {
                        //
                        self.playCtrlBtn.state = NSControlStateValueOn;
                        [self enableComputerSleep:YES];
                        [self toggleTitleBar:YES];
                        self.playCtrlBtn.image = [NSImage imageNamed:@"play"];
                    }
                }
            }];
        } else if (FSFinishReasonPlaybackEnded == reason) {
            NSLog(@"播放结束");
            
            if ([[MRUtil pictureType] containsObject:[[[self.playingUrl lastPathComponent] pathExtension] lowercaseString]]) {
//                [self stopPlay];
            } else {
                NSString *key = [self.playingUrl md5Hash];
                [self playNext:nil];
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
            }
        }
    }
}

- (void)ijkPlayerSelectedStreamDidChange:(NSNotification *)notifi
{
    [self updateStreams];
}

- (void)ijkPlayerICYMetaChanged:(NSNotification *)notifi
{
    [self printICYMeta];
}

- (void)playbackStateDidChange:(NSNotification *)notifi
{
    if (notifi.object == self.player) {
        switch (self.player.playbackSchedule) {
            case FSPlayerPlaybackScheduleIdle:
                NSLog(@"FSPlayerPlaybackSchedule:Idle");
                break;
            case FSPlayerPlaybackScheduleInitialized:
                NSLog(@"FSPlayerPlaybackSchedule:Initialized");
                break;
            case FSPlayerPlaybackSchedulePreparing:
                NSLog(@"FSPlayerPlaybackSchedule:Preparing");
                break;
            case FSPlayerPlaybackSchedulePrepared:
                NSLog(@"FSPlayerPlaybackSchedule:Prepared");
                break;
            case FSPlayerPlaybackScheduleStarted:
                NSLog(@"FSPlayerPlaybackSchedule:Started");
                break;
            case FSPlayerPlaybackSchedulePaused:
                NSLog(@"FSPlayerPlaybackSchedule:Paused");
                break;
            case FSPlayerPlaybackScheduleCompleted:
                NSLog(@"FSPlayerPlaybackSchedule:Completed");
                break;
            case FSPlayerPlaybackScheduleStopped:
                NSLog(@"FSPlayerPlaybackSchedule:Stopped");
                break;
            case FSPlayerPlaybackScheduleError:
                NSLog(@"FSPlayerPlaybackSchedule:Error");
                break;
        }
        
        switch (self.player.playbackState) {
            case FSPlayerPlaybackStatePaused:
                NSLog(@"FSPlayerPlaybackState:Paused");
                break;
            case FSPlayerPlaybackStatePlaying:
                NSLog(@"FSPlayerPlaybackState:Playing");
                break;
            case FSPlayerPlaybackStateStopped:
                NSLog(@"FSPlayerPlaybackState:Stopped");
                break;
            case FSPlayerPlaybackStateInterrupted:
                NSLog(@"FSPlayerPlaybackState:Interrupted");
                break;
            case FSPlayerPlaybackStateSeekingForward:
                NSLog(@"FSPlayerPlaybackState:SeekingForward");
                break;
            case FSPlayerPlaybackStateSeekingBackward:
                NSLog(@"FSPlayerPlaybackState:SeekingBackward");
                break;
        }
    }
}

- (void)saveCurrentPlayRecord
{
    if (self.playingUrl && self.player) {
        NSString *key = [self.playingUrl md5Hash];
        
        if (self.player.duration > 0 &&
            self.player.duration - self.player.currentPlaybackTime < 10 &&
            self.player.currentPlaybackTime / self.player.duration > 0.9) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
        } else {
            [[NSUserDefaults standardUserDefaults] setDouble:self.player.currentPlaybackTime forKey:key];
        }
    }
}

- (NSTimeInterval)readCurrentPlayRecord
{
    if (self.playingUrl) {
        NSString *key = [self.playingUrl md5Hash];
        return [[NSUserDefaults standardUserDefaults] doubleForKey:key];
    }
    return 0.0;
}

- (void)updateStreams
{
    if (self.player.isPreparedToPlay) {
        NSDictionary *dic = self.player.monitor.mediaMeta;
        NSArray *chapteArr = self.player.monitor.chapterMetaArr;
        NSLog(@"video chapters:%@",chapteArr);
        
        MRPlayerSettingsViewController *settings = [self findSettingViewController];
        [settings updateTracks:dic];
        if (!self.tickTimer) {
            self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.03 target:self selector:@selector(onTick:) userInfo:nil repeats:YES];
        }
        //test
        //[self.player exchangeSelectedStream:48];
    }
}

- (void)printICYMeta
{
    NSDictionary *dic = self.player.monitor.mediaMeta;
    NSLog(@"---ICY Meta Changed---------------");
    NSLog(FS_KEY_ICY_BR@":%@",dic[FS_KEY_ICY_BR]);
    NSLog(FS_KEY_ICY_DESC@":%@",dic[FS_KEY_ICY_DESC]);
    NSLog(FS_KEY_ICY_GENRE@":%@",dic[FS_KEY_ICY_GENRE]);
    NSLog(FS_KEY_ICY_NAME@":%@",dic[FS_KEY_ICY_NAME]);
    NSLog(FS_KEY_ICY_PUB@":%@",dic[FS_KEY_ICY_PUB]);
    NSLog(FS_KEY_ICY_URL@":%@",dic[FS_KEY_ICY_URL]);
    NSLog(FS_KEY_ICY_ST@":%@",dic[FS_KEY_ICY_ST]);
    NSLog(FS_KEY_ICY_SU@":%@",dic[FS_KEY_ICY_SU]);
}

- (void)enableComputerSleep:(BOOL)enable
{
    AppDelegate *delegate = NSApp.delegate;
    [delegate enableComputerSleep:enable];
}

- (void)onTick:(NSTimer *)sender
{
    double currentPosition = self.player.currentPlaybackTime;
    double duration = self.player.monitor.duration / 1000.0;
    self.playedTimeLb.stringValue = [NSString stringWithFormat:@"%02d:%02d",(int)(currentPosition/60),(int)currentPosition%60];
    self.durationTimeLb.stringValue = [NSString stringWithFormat:@"%02d:%02d",(int)duration/60,(int)duration%60];
    self.playerSlider.playedValue = currentPosition;
    self.playerSlider.minValue = 0;
    self.playerSlider.maxValue = duration;
    self.playerSlider.preloadValue = self.player.playableDuration;
    
    if ([self.player isPlaying]) {
        self.tickCount ++;
        if (self.tickCount % 1980 == 0) {
            [self saveCurrentPlayRecord];
        }
        [self enableComputerSleep:NO];
    }
}

- (void)playURL:(NSString *)urlStr
{
    if (!urlStr) {
        return;
    }
    [self destroyPlayer];
#warning 根据地址，动态修改
    BOOL isLive = [urlStr hasPrefix:@"rtmp"] || [urlStr hasPrefix:@"rtsp"];
    
    [self perpareIJKPlayer:urlStr hwaccel:self.isUsingHardwareAccelerate isLive:isLive];
    NSString *videoName = [urlStr lastPathComponent];
    
    NSInteger idx = [self.playList indexOfObject:self.playingUrl] + 1;
    
    [[NSUserDefaults standardUserDefaults] setObject:videoName forKey:lastPlayedKey];
    
    NSString *title = [NSString stringWithFormat:@"(%ld/%ld)%@",(long)idx,[[self playList] count],videoName];
    [self.view.window setTitle:title];
    
    self.playCtrlBtn.image = [NSImage imageNamed:@"pause"];
    self.playCtrlBtn.state = NSControlStateValueOff;
    
    if (!isLive && [MRCocoaBindingUserDefault play_from_history]) {
        int startTime = (int)([self readCurrentPlayRecord] * 1000);
        [self.player setPlayerOptionIntValue:startTime forKey:@"seek-at-start"];
    }
    
    [self.player prepareToPlay];
    
    if ([self.subtitles count] > 0) {
        NSURL *firstUrl = [self.subtitles firstObject];
        [self.player loadThenActiveSubtitle:firstUrl];
        [self.player loadSubtitlesOnly:[self.subtitles subarrayWithRange:NSMakeRange(1, self.subtitles.count - 1)]];
    }
    
    [self onTick:nil];
}

- (NSString *)existingInPlayList:(NSString *)url
{
    NSString *t = nil;
    for (NSString *item in [self.playList copy]) {
        if ([item isEqualToString:url]) {
            t = item;
            break;
        }
    }
    return t;
}

- (NSURL *)existingInSubList:(NSURL *)url
{
    NSURL *t = nil;
    for (NSURL *item in [self.subtitles copy]) {
        if ([[item absoluteString] isEqualToString:[url absoluteString]]) {
            t = item;
            break;
        }
    }
    return t;
}

- (NSString *)decodeURL:(NSURL *)url
{
    NSURLComponents *comp = [[NSURLComponents alloc] initWithURL:url resolvingAgainstBaseURL:NO];
    NSString *scheme = comp.scheme ?: @"file";
    NSString *host = comp.host ?: @"";
    NSString *port = comp.port ? [NSString stringWithFormat:@":%@", comp.port] : @"";

    NSString *auth = @"";
    if (comp.user || comp.password) {
        auth = [NSString stringWithFormat:@"%@:%@@", comp.user ?: @"", comp.password ?: @""];
    }
    NSString *decodedPath = [comp path];
    NSString *query = [comp query] ? [NSString stringWithFormat:@"?%@", comp.query] : @"";
    NSString *fragment = [comp fragment] ? [NSString stringWithFormat:@"#%@", comp.fragment] : @"";
    return [NSString stringWithFormat:@"%@://%@%@%@%@%@%@", scheme, auth, host, port, decodedPath,query,fragment];
}

- (void)appendToPlayList:(NSArray *)bookmarkArr append:(BOOL)append
{
    if (!append) {
        self.lastSubIdx = -1;
        [self onStop];
        [self.subtitles removeAllObjects];
        [self.playList removeAllObjects];
    }
    
    NSMutableArray *videos = [NSMutableArray array];
    NSMutableArray *subtitles = [NSMutableArray array];
    
    for (NSDictionary *dic in bookmarkArr) {
        NSURL *url = dic[@"url"];
        NSString *str = [self decodeURL:url];
        if ([[[str pathExtension] lowercaseString] isEqualToString:@"xlist"]) {
            for (NSString *u in [MRUtil parseXPlayList:str]) {
                if ([self existingInPlayList:u]) {
                    continue;
                }
                [videos addObject:u];
            }
        } else if ([dic[@"type"] intValue] == 0) {
            if ([self existingInPlayList:str]) {
                continue;
            }
            [videos addObject:str];
        } else if ([dic[@"type"] intValue] == 1) {
            NSURL *url = dic[@"url"];
            if ([self existingInSubList:url]) {
                continue;
            }
            [subtitles addObject:url];
        } else {
            NSAssert(NO, @"没有处理的文件:%@",url);
        }
    }
    
    if ([videos count] == 0) {
        [self.subtitles addObjectsFromArray:subtitles];
        if (![self playFirstIfNeed]) {
            NSURL *url = [subtitles firstObject];
            [self.player loadThenActiveSubtitle:url];
        }
        return;
    }
    
    
    [self.subtitles addObjectsFromArray:subtitles];
    [self.playList addObjectsFromArray:videos];
    [self playFirstIfNeed];
}

#pragma mark - 拖拽

- (void)handleDragFileList:(nonnull NSArray<NSURL *> *)fileUrls append:(BOOL)append
{
    NSMutableArray *bookmarkArr = [NSMutableArray array];
    for (NSURL *url in fileUrls) {
        //先判断是不是文件夹
        NSArray *dicArr = [MRUtil scanFolder:url filter:[MRUtil acceptMediaType]];
        if ([dicArr count] > 0) {
            [bookmarkArr addObjectsFromArray:dicArr];
        }
    }
    
    [self appendToPlayList:bookmarkArr append:append];
}

- (NSDragOperation)acceptDragOperation:(NSArray<NSURL *> *)list
{
    for (NSURL *url in list) {
        if (url) {
            //先判断是不是文件夹
            BOOL isDirectory = NO;
            BOOL isExist = [[NSFileManager defaultManager] fileExistsAtPath:[url path] isDirectory:&isDirectory];
            if (isExist) {
                if (isDirectory) {
                    return NSDragOperationCopy;
                } else {
                    NSString *pathExtension = [[url pathExtension] lowercaseString];
                    if ([@"xlist" isEqualToString:pathExtension]) {
                        return NSDragOperationCopy;
                    } else if ([[MRUtil acceptMediaType] containsObject:pathExtension]) {
                        return NSDragOperationCopy;
                    }
                }
            }
        }
    }
    return NSDragOperationNone;
}

- (BOOL)playFirstIfNeed
{
    if (self.playingUrl) {
        return NO;
    }
    [self pauseOrPlay:nil];
    return YES;
}

#pragma mark - 点击事件

- (IBAction)pauseOrPlay:(NSButton *)sender
{
    if ([self.playList count] == 0) {
        self.playCtrlBtn.state = NSControlStateValueOn;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self openFile:nil];
        });
        return;
    }
    
    if (self.playingUrl) {
        if (!sender) {
            self.playCtrlBtn.state = !self.playCtrlBtn.state;
        }
        if (self.playCtrlBtn.state == NSControlStateValueOn) {
            [self enableComputerSleep:YES];
            [self.player pause];
            [self toggleTitleBar:YES];
            self.playCtrlBtn.image = [NSImage imageNamed:@"play"];
        } else {
            [self.player play];
            self.playCtrlBtn.image = [NSImage imageNamed:@"pause"];
        }
    } else {
        [self playNext:nil];
    }
}

- (IBAction)onToggleHUD:(id)sender
{
    self.shouldShowHudView = !self.shouldShowHudView;
    self.player.shouldShowHudView = self.shouldShowHudView;
}

- (IBAction)onToggleSiderBar:(id)sender
{
    [self showPlayerSettingsSideBar];
}

static BOOL useExact = NO;

- (int)startRecord:(NSString *)filePath
{
    if (useExact) {
        return [self.player startExactRecord:filePath];
    } else {
        return [self.player startFastRecord:filePath];
    }
}

- (int)stopRecord
{
    if (useExact) {
        return [self.player stopExactRecord];
    } else {
        return [self.player stopFastRecord];
    }
}

- (IBAction)onToggleRecord:(NSButton *)sender
{
    if (sender.state == NSControlStateValueOff) {
        int error = [self stopRecord];
        NSLog(@"停止录制:%d", error);
    } else {
        // 获取Caches目录路径
        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *cacheDirectory = [paths firstObject];
        // 获取当前时间戳（毫秒级）
        NSDate *now = [NSDate date];
        long long timestamp = (long long)([now timeIntervalSince1970] * 1000);
        NSString *extension = [[self.player.content lastPathComponent] pathExtension];
        if (!extension) {
            extension = [[self.player getInputFormatExtensions] firstObject];
        }
        if (!extension) {
            extension = @"mkv";
        }
        // 格式化为字符串
        NSString *fileName = [NSString stringWithFormat:@"%lld.%@", timestamp, extension];
        // 构建完整文件路径
        NSString *filePath = [cacheDirectory stringByAppendingPathComponent:fileName];
        int error = [self.player startFastRecord:filePath];
        if (error) {
            NSLog(@"开始录制:%d",error);
        } else {
            NSLog(@"开始录制:%@",filePath);
        }
    }
}

- (IBAction)onToggleMultiRenderer:(NSButton *)sender
{
    static MultiRenderSample *multiRenderVC = nil;
    
    if (sender.state == NSControlStateValueOn) {
        
        if (multiRenderVC) {
            return;
        }
        NSString *playingUrl = self.playingUrl;
        [self doStopPlay];
        
        multiRenderVC = [[MultiRenderSample alloc] initWithNibName:@"MultiRenderSample" bundle:nil];
        
        [self addChildViewController:multiRenderVC];
        [self.playerContainer addSubview:multiRenderVC.view positioned:NSWindowBelow relativeTo:self.playerCtrlPanel];
        multiRenderVC.view.frame = self.playerContainer.bounds;
        multiRenderVC.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [multiRenderVC.view viewDidMoveToSuperview];

        [multiRenderVC setContentURL:playingUrl];
    } else {
        if (!multiRenderVC) {
            return;
        }
        NSString *playingUrl = multiRenderVC.contentURL;
        [multiRenderVC.view removeFromSuperview];
        [multiRenderVC removeFromParentViewController];
        multiRenderVC = nil;
        
        [self playURL:playingUrl];
    }
}

- (BOOL)preferHW
{
    return [MRCocoaBindingUserDefault use_hw];
}

- (void)retry
{
    self.usingHardwareAccelerate = [self preferHW];
    float playbackRate = self.player.playbackRate;
    
    NSString *url = self.playingUrl;
    [self onStop];
    [self playURL:url];
    self.player.playbackRate = playbackRate;
}

- (void)onStop
{
    [self saveCurrentPlayRecord];
    [self doStopPlay];
}

- (BOOL)destroyPlayer
{
    if (self.player) {
        NSLog(@"destroy play");
        [[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:self.player];
        [self.player.view removeFromSuperview];
        [self.player pause];
        [self.player shutdown];
        self.player = nil;
        return YES;
    }
    return NO;
}

- (void)doStopPlay
{
    [self destroyPlayer];
    
    if (self.tickTimer) {
        [self.tickTimer invalidate];
        self.tickTimer = nil;
        self.tickCount = 0;
    }
    
    if (self.playingUrl) {
        self.playingUrl = nil;
    }
    
    [self.view.window setTitle:@""];
    self.playedTimeLb.stringValue = @"--:--";
    self.durationTimeLb.stringValue = @"--:--";
    [self enableComputerSleep:YES];
    self.playCtrlBtn.state = NSControlStateValueOn;
    self.playCtrlBtn.image = [NSImage imageNamed:@"play"];
}

- (void)resetPreferenceEachPlay
{
    self.usingHardwareAccelerate = [self preferHW];
    
    [MRCocoaBindingUserDefault setValue:@(0.0) forKey:@"subtitle_delay"];
    
    [MRCocoaBindingUserDefault setValue:@(0.0) forKey:@"audio_delay"];
}

- (IBAction)playPrevious:(NSButton *)sender
{
    if ([self.playList count] == 0) {
        return;
    }
    [self saveCurrentPlayRecord];
    
    NSUInteger idx = [self.playList indexOfObject:self.playingUrl];
    if (idx == NSNotFound) {
        idx = 0;
    } else if (idx <= 0) {
        idx = [self.playList count] - 1;
    } else {
        idx --;
    }
    
    NSString *url = self.playList[idx];
    [self resetPreferenceEachPlay];
    [self playURL:url];
}

- (IBAction)playNext:(NSButton *)sender
{
    if ([self.playList count] == 0) {
        return;
    }
    [self saveCurrentPlayRecord];
    
    NSUInteger idx = [self.playList indexOfObject:self.playingUrl];
    
    if (idx == NSNotFound) {
        idx = 0;
    } else if (idx >= [self.playList count] - 1) {
        idx = 0;
    } else {
        idx ++;
    }
    
    NSURL *url = self.playList[idx];
    [self resetPreferenceEachPlay];
    [self playURL:url];
}

- (void)seekTo:(float)cp
{
    NSLog(@"seek to:%g",cp);
//    if (self.seeking) {
//        NSLog(@"xql ignore seek.");
//        return;
//    }
//    self.seeking = YES;
    if (cp < 0) {
        cp = 0;
    }
//    [self.player pause];
    self.seekCostLb.stringValue = @"";
    if (self.player.monitor.duration > 0) {
        if (cp >= self.player.monitor.duration) {
            cp = self.player.monitor.duration - 5;
        }
        self.player.currentPlaybackTime = cp;
        
        long interval = (long)cp;
        self.playedTimeLb.stringValue = [NSString stringWithFormat:@"%02d:%02d",(int)(interval/60),(int)(interval%60)];
        self.playerSlider.playedValue = interval;
    }
}

- (void)fastRewind:(NSButton *)sender
{
    float cp = self.player.currentPlaybackTime;
    cp -= [MRCocoaBindingUserDefault seek_step];
    [self seekTo:cp];
}

- (void)fastForward:(NSButton *)sender
{
    if (self.player.playbackState == FSPlayerPlaybackStatePaused) {
        [self.player stepToNextFrame];
    } else {
        float cp = self.player.currentPlaybackTime;
        cp += [MRCocoaBindingUserDefault seek_step];
        [self seekTo:cp];
    }
}

- (IBAction)onVolumeChange:(NSSlider *)sender
{
    self.player.playbackVolume = [MRCocoaBindingUserDefault volume];
}

#pragma mark 倍速设置

- (void)updateSpeed:(NSButton *)sender
{
    NSInteger tag = sender.tag;
    float speed = tag / 100.0;
    self.player.playbackRate = speed;
}

#pragma mark 字幕设置

- (void)applySubtitlePreference
{
    FSSubtitlePreference p = self.player.subtitlePreference;
    p.ForceOverride = [MRCocoaBindingUserDefault force_override];
    p.PrimaryColour = fs_ass_color_to_int([MRCocoaBindingUserDefault PrimaryColour]);
    p.SecondaryColour = fs_ass_color_to_int([MRCocoaBindingUserDefault SecondaryColour]);
    p.BackColour = fs_ass_color_to_int([MRCocoaBindingUserDefault BackColour]);
    p.OutlineColour = fs_ass_color_to_int([MRCocoaBindingUserDefault OutlineColour]);
    p.Outline = [MRCocoaBindingUserDefault Outline];
    p.BottomMargin = ([MRCocoaBindingUserDefault subtitle_bottom_margin]) / 100.0;
    p.Scale = [MRCocoaBindingUserDefault subtitle_scale];
    
    strcpy(p.FontsDir, "/Users/matt/Movies/fonts");
    NSString *name = [MRCocoaBindingUserDefault FontName];
    name = @"苹方-港";
    if (name) {
        strcpy(p.FontName,[name UTF8String]);
    } else {
        bzero(p.FontName, sizeof(p.FontName));
    }
    self.player.subtitlePreference = p;
}

#pragma mark 色彩调节

- (void)applyBSC
{
    FSColorConvertPreference colorPreference = self.player.view.colorPreference;
    colorPreference.brightness = [MRCocoaBindingUserDefault color_adjust_brightness];
    colorPreference.saturation = [MRCocoaBindingUserDefault color_adjust_saturation];
    colorPreference.contrast   = [MRCocoaBindingUserDefault color_adjust_contrast];
    
    self.player.view.colorPreference = colorPreference;
}

#pragma mark 播放器偏好设置

- (void)applyScalingMode
{
    [self.player setScalingMode:[MRCocoaBindingUserDefault picture_fill_mode]];
}

- (void)applyDAR
{
    int value = [MRCocoaBindingUserDefault picture_wh_ratio];
    int dar_num = 0;
    int dar_den = 1;
    if (value == 1) {
        dar_num = 4;
        dar_den = 3;
    } else if (value == 2) {
        dar_num = 16;
        dar_den = 9;
    } else if (value == 3) {
        dar_num = 1;
        dar_den = 1;
    }
    self.player.view.darPreference = (FSDARPreference){1.0 * dar_num/dar_den};
}

- (void)applyRotate
{
    FSRotatePreference preference = self.player.view.rotatePreference;
    int rotate = [MRCocoaBindingUserDefault picture_ratate_mode];
    if (rotate == 0) {
        preference.type = FSRotateNone;
        preference.degrees = 0;
    } else if (rotate == 1) {
        preference.type = FSRotateZ;
        preference.degrees = -90;
    } else if (rotate == 2) {
        preference.type = FSRotateZ;
        preference.degrees = -180;
    } else if (rotate == 3) {
        preference.type = FSRotateZ;
        preference.degrees = -270;
    } else if (rotate == 4) {
        preference.type = FSRotateY;
        preference.degrees = 180;
    } else if (rotate == 5) {
        preference.type = FSRotateX;
        preference.degrees = 180;
    }
    self.player.view.rotatePreference = preference;
    NSLog(@"rotate:%@ %d",@[@"None",@"X",@"Y",@"Z"][preference.type],(int)preference.degrees);
}

#pragma mark 日志级别

- (int)levelWithString:(NSString *)str
{
    str = [str lowercaseString];
    if ([str isEqualToString:@"default"]) {
        return FS_LOG_DEFAULT;
    } else if ([str isEqualToString:@"verbose"]) {
        return FS_LOG_VERBOSE;
    } else if ([str isEqualToString:@"debug"]) {
        return FS_LOG_DEBUG;
    } else if ([str isEqualToString:@"info"]) {
        return FS_LOG_INFO;
    } else if ([str isEqualToString:@"warn"]) {
        return FS_LOG_WARN;
    } else if ([str isEqualToString:@"error"]) {
        return FS_LOG_ERROR;
    } else if ([str isEqualToString:@"fatal"]) {
        return FS_LOG_FATAL;
    } else if ([str isEqualToString:@"silent"]) {
        return FS_LOG_SILENT;
    } else {
        return FS_LOG_UNKNOWN;
    }
}

- (void)reSetLoglevel
{
    NSString *loglevel = [MRCocoaBindingUserDefault log_level];
    NSLog(@"FS LogLevel set:%@",loglevel);
    int level = [self levelWithString:loglevel];
//    [FSPlayer setLogReport:[@[@"verbose",@"debug"] containsObject:loglevel]];
    [FSPlayer setLogLevel:level];
}

- (void)observerCocoaBingsChange
{
    static NSDateFormatter *df;
    if (!df) {
        df = [[NSDateFormatter alloc]init];
#if DEBUG
        df.dateFormat = @"HH:mm:ss SSS";
#else
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss S";
#endif
    }

    [FSPlayer setLogHandler:^(FSLogLevel level, NSString *tag, NSString *msg) {
        NSString *msgStr = [msg stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (msgStr.length > 0) {
            NSString *dateStr = [df stringFromDate:[NSDate date]];
            NSLog(@"[%@] [%@] %@", dateStr, tag, msg);
        }
    }];
    
    [self reSetLoglevel];
    
    __weakSelf__
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull value,BOOL *removed) {
        __strongSelf__
        [self reSetLoglevel];
    } forKey:@"log_level"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        [self applyBSC];
    } forKey:@"color_adjust_brightness"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        [self applyBSC];
    } forKey:@"color_adjust_saturation"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        [self applyBSC];
    } forKey:@"color_adjust_contrast"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        int value = [v intValue];
        [self.player setScalingMode:value];
    } forKey:@"picture_fill_mode"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        [self applyDAR];
    } forKey:@"picture_wh_ratio"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        [self applyRotate];
    } forKey:@"picture_ratate_mode"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        FSSubtitlePreference p = self.player.subtitlePreference;
        NSString *name = v;
        if (name) {
            strcpy(p.FontName,[name UTF8String]);
        } else {
            bzero(p.FontName, sizeof(p.FontName));
        }
        self.player.subtitlePreference = p;
    } forKey:@"FontName"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        FSSubtitlePreference p = self.player.subtitlePreference;
        p.BottomMargin = [v intValue] / 100.0;
        self.player.subtitlePreference = p;
    } forKey:@"subtitle_bottom_margin"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        FSSubtitlePreference p = self.player.subtitlePreference;
        p.Scale = [v floatValue];
        self.player.subtitlePreference = p;
    } forKey:@"subtitle_scale"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull rm) {
        __strongSelf__
        NSColor *color = v;
        FSSubtitlePreference p = self.player.subtitlePreference;
        p.PrimaryColour = fs_ass_color_to_int(color);
        self.player.subtitlePreference = p;
    } forKey:@"PrimaryColour"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull rm) {
        __strongSelf__
        NSColor *color = v;
        FSSubtitlePreference p = self.player.subtitlePreference;
        p.SecondaryColour = fs_ass_color_to_int(color);
        self.player.subtitlePreference = p;
    } forKey:@"SecondaryColour"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull rm) {
        __strongSelf__
        NSColor *color = v;
        FSSubtitlePreference p = self.player.subtitlePreference;
        p.BackColour = fs_ass_color_to_int(color);
        self.player.subtitlePreference = p;
    } forKey:@"BackColour"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull rm) {
        __strongSelf__
        NSColor *color = v;
        FSSubtitlePreference p = self.player.subtitlePreference;
        p.OutlineColour = fs_ass_color_to_int(color);
        self.player.subtitlePreference = p;
    } forKey:@"OutlineColour"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull rm) {
        __strongSelf__
        FSSubtitlePreference p = self.player.subtitlePreference;
        p.Outline = [v floatValue];
        self.player.subtitlePreference = p;
    } forKey:@"Outline"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull rm) {
        __strongSelf__
        FSSubtitlePreference p = self.player.subtitlePreference;
        p.ForceOverride = [v boolValue];
        self.player.subtitlePreference = p;
    } forKey:@"force_override"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull rm) {
        __strongSelf__
        FSSubtitlePreference p = self.player.subtitlePreference;
        if (!v) {
            v = @"";
        }
        //p.otherStyles = [v UTF8String];
        self.player.subtitlePreference = p;
    } forKey:@"custom_style"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull rm) {
        __strongSelf__
        self.player.currentSubtitleExtraDelay = [v floatValue];
    } forKey:@"subtitle_delay"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull rm) {
        __strongSelf__
        self.player.currentAudioExtraDelay = [v floatValue];
    } forKey:@"audio_delay"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        [self.player enableAccurateSeek:[v boolValue]];
    } forKey:@"accurate_seek"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        if ([v boolValue]) {
            [self applyLockScreenRatio];
        }
    } forKey:@"lock_screen_ratio"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        [self retry];
    } forKey:@"use_opengl"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        [self retry];
    } forKey:@"use_hw"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        if ([MRCocoaBindingUserDefault use_hw]) {
            [self retry];
        }
    } forKey:@"copy_hw_frame"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        [self retry];
    } forKey:@"de_interlace"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
#warning todo
    } forKey:@"open_hdr"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        if (![MRCocoaBindingUserDefault use_hw]) {
            [self retry];
        }
    } forKey:@"overlay_format"];
    
#warning todo open_gzip
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        [self retry];
    } forKey:@"open_gzip"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        [self retry];
    } forKey:@"use_dns_cache"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        [self retry];
    } forKey:@"dns_cache_period"];
}

- (NSString *)saveDir:(NSString *)subDir
{
    NSArray *subDirs = subDir ? @[@"ijkPro",subDir] : @[@"ijkPro"];
    NSString * path = [NSFileManager mr_DirWithType:NSPicturesDirectory WithPathComponents:subDirs];
    return path;
}

- (NSString *)dirForCurrentPlayingUrl
{
    return [self saveDir:[self.playingUrl lastPathComponent]];
}

- (void)onCaptureShot
{
    CGImageRef img = [self.player.view snapshot:[MRCocoaBindingUserDefault snapshot_type]];
    if (img) {
        NSString *dir = [self dirForCurrentPlayingUrl];
        NSString *movieName = [self.playingUrl lastPathComponent];
        NSString *fileName = [NSString stringWithFormat:@"%@-%ld.jpg",movieName,(long)(CFAbsoluteTimeGetCurrent() * 1000)];
        NSString *filePath = [dir stringByAppendingPathComponent:fileName];
        NSLog(@"截屏:%@",filePath);
        [MRUtil saveImageToFile:img path:filePath];
    }
}

@end
