//
//  MRStatisticalViewController.m
//  IJKMediaMacDemo
//
//  Created by Matt Reach on 2021/11/1.
//  Copyright © 2021 IJK Mac. All rights reserved.
//

#import "MRStatisticalViewController.h"
#import "MRDragView.h"
#import "MRUtil+SystemPanel.h"
#import <IJKMediaPlayerKit/IJKMediaPlayerKit.h>
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
#import "MRCocoaBindingUserDefault.h"

static BOOL hdrAnimationShown = 0;

@interface MRStatisticalViewController ()<MRDragViewDelegate,SHBaseViewDelegate,NSMenuDelegate>

@property (nonatomic, weak) IBOutlet NSStackView *advancedView;
@property (nonatomic, weak) IBOutlet MRBaseView *playerCtrlPanel;
@property (nonatomic, weak) IBOutlet NSTextField *playedTimeLb;
@property (nonatomic, weak) IBOutlet NSTextField *durationTimeLb;
@property (nonatomic, weak) IBOutlet NSButton *playCtrlBtn;
@property (nonatomic, weak) IBOutlet MRProgressIndicator *playerSlider;

@property (nonatomic, weak) IBOutlet NSPopUpButton *subtitlePopUpBtn;
@property (nonatomic, weak) IBOutlet NSPopUpButton *audioPopUpBtn;
@property (nonatomic, weak) IBOutlet NSPopUpButton *videoPopUpBtn;
@property (nonatomic, weak) IBOutlet NSTextField *seekCostLb;
@property (nonatomic, weak) NSTrackingArea *trackingArea;

//for cocoa binding begin
@property (nonatomic, assign) float volume;
@property (nonatomic, assign) float subtitleDelay;
@property (nonatomic, assign) float subtitleMargin;

@property (nonatomic, assign) float brightness;
@property (nonatomic, assign) float saturation;
@property (nonatomic, assign) float contrast;
@property (nonatomic, assign) BOOL use_openGL;
@property (nonatomic, copy) NSString *fcc;
@property (nonatomic, assign) int snapshot;
@property (nonatomic, assign) BOOL shouldShowHudView;
@property (nonatomic, assign) BOOL accurateSeek;
@property (nonatomic, assign) BOOL loop;
//for cocoa binding end

@property (nonatomic, assign) BOOL seeking;
@property (nonatomic, weak) id eventMonitor;
@property (nonatomic, assign) int playCount;
@property (nonatomic, strong) NSMutableArray *statisticalSample;
@property (nonatomic, assign) int tickCount;
//player
@property (nonatomic, strong) IJKFFMoviePlayerController *player;
@property (nonatomic, strong) NSMutableArray *playList;
@property (nonatomic, strong) NSMutableArray *subtitles;
@property (nonatomic, copy) NSURL *playingUrl;
@property (nonatomic, weak) NSTimer *tickTimer;
@property (nonatomic, assign, getter=isUsingHardwareAccelerate) BOOL usingHardwareAccelerate;

@end

@implementation MRStatisticalViewController

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
    self.title = @"Statistical";
    [IJKFFMoviePlayerController setLogHandler:^(IJKLogLevel level, NSString *tag, NSString *msg) {
        NSLog(@"[%@] [%d] %@",tag,level,msg);
//        printf("[%s] %s\n",[tag UTF8String],[msg UTF8String]);
    }];

    self.subtitleMargin = 0.7;
    self.fcc = @"fcc-_es2";
    self.snapshot = 3;
    self.volume = 0.4;
    [self onReset:nil];
    [self reSetLoglevel:@"verbose"];
    self.seekCostLb.stringValue = @"";
    self.accurateSeek = 1;
    self.loop = 1;
    
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
                self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(onTick:) userInfo:nil repeats:YES];
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
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self toggleAdvancedViewShow];
    });

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
            [menu addItemWithTitle:@"停止" action:@selector(doStopPlay) keyEquivalent:@"."];
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
    if (!self.view.window.isKeyWindow) {
        return;
    }
    NSDictionary *info = notifi.userInfo;
    NSArray *movies = info[@"obj"];
    
    if ([movies count] > 0) {
        // 追加到列表，开始播放
        [self appendToPlayList:movies reset:YES];
    }
}

- (void)_playNetMovies:(NSNotification *)notifi
{
    NSDictionary *info = notifi.userInfo;
    NSArray *links = info[@"links"];
    NSMutableArray *videos = [NSMutableArray array];
    
    for (NSString *link in links) {
        NSURL *url = [NSURL URLWithString:link];
        [videos addObject:url];
    }
    
    if ([videos count] > 0) {
        // 开始播放
        [self.playList removeAllObjects];
        [self.playList addObjectsFromArray:videos];
        [self doStopPlay];
        [self playFirstIfNeed];
    }
}

- (void)toggleAdvancedViewShow
{
    __weakSelf__
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
        context.duration = 0.35;
        context.allowsImplicitAnimation = YES;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        __strongSelf__
        self.advancedView.animator.hidden = !self.advancedView.isHidden;
    }];
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
                [self toggleAdvancedViewShow];
            }
                break;
            case kVK_ANSI_R:
            {
                IJKSDLRotatePreference preference = self.player.view.rotatePreference;
                
                if (preference.type == IJKSDLRotateNone) {
                    preference.type = IJKSDLRotateZ;
                }
                
                if (event.modifierFlags & NSEventModifierFlagOption) {
                    
                    preference.type --;
                    
                    if (preference.type <= IJKSDLRotateNone) {
                        preference.type = IJKSDLRotateZ;
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
                [self onCaptureShot:nil];
            }
                break;
            case kVK_ANSI_Period:
            {
                [self doStopPlay];
            }
                break;
            case kVK_ANSI_H:
            {
                if (event.modifierFlags & NSEventModifierFlagShift) {
                    [self toggleHUD:nil];
                }
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
                int currentIdx = [dic[k_IJKM_VAL_TYPE__SUBTITLE] intValue];
                int position = -1;
                NSMutableArray *subStreamIdxArr = [NSMutableArray array];
                for (NSDictionary *stream in dic[kk_IJKM_KEY_STREAMS]) {
                    NSString *type = stream[k_IJKM_KEY_TYPE];
                    if ([type isEqualToString:k_IJKM_VAL_TYPE__SUBTITLE]) {
                        int streamIdx = [stream[k_IJKM_KEY_STREAM_IDX] intValue];
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
                float volume = self.volume;
                volume -= 0.1;
                if (volume < 0) {
                    volume = .0f;
                }
                self.volume = volume;
                [self onVolumeChange:nil];
            }
                break;
            case kVK_UpArrow:
            {
                float volume = self.volume;
                volume += 0.1;
                if (volume > 1) {
                    volume = 1.0f;
                }
                self.volume = volume;
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
                    self.subtitleDelay = delay;
                    self.player.currentSubtitleExtraDelay = delay;
                }
            }
                break;
            case kVK_ANSI_Equal:
            {
                float delay = self.player.currentSubtitleExtraDelay;
                delay += 2;
                self.subtitleDelay = delay;
                self.player.currentSubtitleExtraDelay = delay;
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

- (NSMutableArray *)playList
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

- (NSMutableArray *)statisticalSample
{
    if (!_statisticalSample) {
        _statisticalSample = [NSMutableArray array];
    }
    return _statisticalSample;
}

- (void)perpareIJKPlayer:(NSURL *)url hwaccel:(BOOL)hwaccel
{
    if (self.playingUrl) {
        [self doStopPlay];
    }
    
    self.playingUrl = url;
    
    self.seeking = NO;
    
    [IJKFFMoviePlayerController setLogLevel:k_IJK_LOG_INFO];
    
    IJKFFOptions *options = [IJKFFOptions optionsByDefault];
    //视频帧处理不过来的时候丢弃一些帧达到同步的效果
    [options setPlayerOptionIntValue:1 forKey:@"framedrop"];
    [options setPlayerOptionIntValue:6      forKey:@"video-pictq-size"];
    //    [options setPlayerOptionIntValue:50000      forKey:@"min-frames"];
    [options setPlayerOptionIntValue:119     forKey:@"max-fps"];
    [options setCodecOptionIntValue:IJK_AVDISCARD_DEFAULT forKey:@"skip_loop_filter"];
    //for mgeg-ts seek
    [options setFormatOptionIntValue:1 forKey:@"seek_flag_keyframe"];
//    default is 5000000,but some high bit rate video probe faild cause no audio.
//    [options setFormatOptionValue:@"10000000" forKey:@"probesize"];
//    [options setFormatOptionValue:@"1" forKey:@"flush_packets"];
//    [options setPlayerOptionIntValue:0      forKey:@"packet-buffering"];
//    [options setPlayerOptionIntValue:1      forKey:@"render-wait-start"];
//    [options setCodecOptionIntValue:1 forKey:@"allow_software"];
//    test video decoder performance.
//    [options setPlayerOptionIntValue:1 forKey:@"an"];
//    [options setPlayerOptionIntValue:1 forKey:@"nodisp"];
//    [options setPlayerOptionValue:@"hls" forKey:@"iformat"];
    [options setFormatOptionIntValue:0 forKey:@"fpsprobesize"];
    
    //加载流时清理一次，但是不会二次传递
//    [options setFormatOptionIntValue:1 forKey:@"dns_cache_clear"];
//    [options setFormatOptionIntValue:1 forKey:@"http_multiple"];
    
    //默认不使用dns缓存，指定超时时间才会使用；
    [options setFormatOptionIntValue:300 * 1000 forKey:@"dns_cache_timeout"];
    //实际测试效果不好，容易导致域名解析失败，谨慎使用;没有fallback逻辑
    //决定dns的方式，大于0时使用tcp_getaddrinfo_nonblock方式
    [options setFormatOptionIntValue:0 forKey:@"addrinfo_timeout"];
    [options setFormatOptionIntValue:0 forKey:@"addrinfo_one_by_one"];
//    [options setFormatOptionIntValue:1 forKey:@"http_persistent"];
//    [options setFormatOptionValue:@"test=cookie" forKey:@"cookies"];
    //if you want set ts segments options only:
//    [options setFormatOptionValue:@"fastopen=2:dns_cache_timeout=600000:addrinfo_timeout=2000000" forKey:@"seg_format_options"];
    //default inherit options : "headers", "user_agent", "cookies", "http_proxy", "referer", "rw_timeout", "icy",you can inherit more:
    [options setFormatOptionValue:@"connect_timeout,ijkapplication,addrinfo_one_by_one,addrinfo_timeout,dns_cache_timeout,fastopen,dns_cache_clear" forKey:@"seg_inherit_options"];
    
    //protocol_whitelist need add httpproxy
//    [options setFormatOptionValue:@"http://10.7.36.42:8888" forKey:@"http_proxy"];
    [options setFormatOptionValue:@"Accept-Encoding: gzip, deflate" forKey:@"headers"];
    
    [options setPlayerOptionIntValue:[MRCocoaBindingUserDefault copy_hw_frame] forKey:@"copy_hw_frame"];
    if ([url isFileURL]) {
        //图片不使用 cvpixelbufferpool
        NSString *ext = [[[url path] pathExtension] lowercaseString];
        if ([[MRUtil pictureType] containsObject:ext]) {
            [options setPlayerOptionIntValue:0      forKey:@"enable-cvpixelbufferpool"];
            if ([@"gif" isEqualToString:ext]) {
                [options setPlayerOptionIntValue:-1      forKey:@"loop"];
            }
        }
    }
    
//    [options setFormatOptionIntValue:0 forKey:@"http_persistent"];
    //请求m3u8文件里的ts出错后是否继续请求下一个ts，默认是1000
    [options setFormatOptionIntValue:1 forKey:@"max_reload"];
    
    BOOL isLive = NO;
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
    
//    [options setPlayerOptionValue:@"fcc-bgra"        forKey:@"overlay-format"];
//    [options setPlayerOptionValue:@"fcc-bgr0"        forKey:@"overlay-format"];
//    [options setPlayerOptionValue:@"fcc-argb"        forKey:@"overlay-format"];
//    [options setPlayerOptionValue:@"fcc-0rgb"        forKey:@"overlay-format"];
//    [options setPlayerOptionValue:@"fcc-uyvy"        forKey:@"overlay-format"];
//    [options setPlayerOptionValue:@"fcc-i420"        forKey:@"overlay-format"];
//    [options setPlayerOptionValue:@"fcc-nv12"        forKey:@"overlay-format"];
    
    [options setPlayerOptionValue:self.fcc forKey:@"overlay-format"];
    [options setPlayerOptionIntValue:hwaccel forKey:@"videotoolbox_hwaccel"];
    [options setPlayerOptionIntValue:self.accurateSeek forKey:@"enable-accurate-seek"];
    [options setPlayerOptionIntValue:1500 forKey:@"accurate-seek-timeout"];
    
    options.metalRenderer = !self.use_openGL;
    options.showHudView = self.shouldShowHudView;
    
    NSMutableArray *dus = [NSMutableArray array];
    if ([url.scheme isEqualToString:@"file"] && [url.absoluteString.pathExtension isEqualToString:@"m3u8"]) {
        NSString *str = [[NSString alloc] initWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
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
    
    [NSDocumentController.sharedDocumentController noteNewRecentDocumentURL:url];
    self.player = [[IJKFFMoviePlayerController alloc] initWithContentURL:url withOptions:options];
    
    NSView <IJKVideoRenderingProtocol>*playerView = self.player.view;
    CGRect rect = self.view.frame;
    rect.origin = CGPointZero;
    playerView.frame = rect;
    playerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.view addSubview:playerView positioned:NSWindowBelow relativeTo:self.playerCtrlPanel];
    
    playerView.showHdrAnimation = !hdrAnimationShown;
    //playerView.preventDisplay = YES;
    //test
    [playerView setBackgroundColor:0 g:0 b:0];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerFirstVideoFrameRendered:) name:IJKMPMoviePlayerFirstVideoFrameRenderedNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerSelectedStreamDidChange:) name:IJKMPMediaPlaybackIsPreparedToPlayDidChangeNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerPreparedToPlay:) name:IJKMPMoviePlayerSelectedStreamDidChangeNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerDidFinish:) name:IJKMPMoviePlayerPlaybackDidFinishNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerCouldNotFindCodec:) name:IJKMPMovieNoCodecFoundNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerAfterSeekFirstVideoFrameDisplay:) name:IJKMPMoviePlayerAfterSeekFirstVideoFrameDisplayNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerVideoDecoderFatal:) name:IJKMPMoviePlayerVideoDecoderFatalNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerRecvWarning:) name:IJKMPMoviePlayerPlaybackRecvWarningNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerHdrAnimationStateChanged:) name:IJKMoviePlayerHDRAnimationStateChanged object:self.player.view];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerFindStreamInfo:) name:IJKMPMoviePlayerFindStreamInfoNotification object:self.player.view];
    
    self.player.shouldAutoplay = YES;
    [self onVolumeChange:nil];
}

#pragma mark - ijkplayer

- (void)ijkPlayerRecvWarning:(NSNotification *)notifi
{
    if (self.player == notifi.object) {
        int reason = [notifi.userInfo[IJKMPMoviePlayerPlaybackWarningReasonUserInfoKey] intValue];
        if (reason == 1000) {
            NSLog(@"recv warning:%d",reason);
            //会收到很多次，所以立马取消掉监听
            [[NSNotificationCenter defaultCenter] removeObserver:self name:IJKMPMoviePlayerPlaybackRecvWarningNotification object:notifi.object];
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

- (void)ijkPlayerFindStreamInfo:(NSNotification *)notifi
{
    
}

- (void)ijkPlayerFirstVideoFrameRendered:(NSNotification *)notifi
{
    NSLog(@"first frame cost:%lldms",self.player.monitor.firstVideoFrameLatency);
    self.seekCostLb.stringValue = [NSString stringWithFormat:@"%lldms",self.player.monitor.firstVideoFrameLatency];
    
    if (self.loop) {
        [self.statisticalSample addObject:@(self.player.monitor.firstVideoFrameLatency)];
        self.seekCostLb.stringValue = [self.statisticalSample componentsJoinedByString:@","];
        
        //播放5s后，重播
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self.loop) {
                return;
            }
            [self onStop];
            //播放12次
            if (++self.playCount < 12) {
                [self pauseOrPlay:nil];
            } else {
                NSArray *sortedArr = [self.statisticalSample sortedArrayUsingComparator:^NSComparisonResult(NSNumber * _Nonnull obj1, NSNumber * _Nonnull obj2) {
                    return [obj1 compare:obj2];
                }];
                
                NSMutableArray *tmpArr = [[NSMutableArray alloc] initWithArray:sortedArr];
                [tmpArr removeObjectAtIndex:0];
                [tmpArr removeLastObject];
                int sum = 0;
                for (NSNumber *num in tmpArr) {
                    sum += [num intValue];
                }
                int avg = sum / tmpArr.count;
                NSLog(@"first frame [%lu] avg cost:%d",tmpArr.count,avg);
                self.seekCostLb.stringValue = [NSString stringWithFormat:@"%dms",avg];
            }
        });
    }
}

- (void)ijkPlayerVideoDecoderFatal:(NSNotification *)notifi
{
    if (self.player == notifi.object) {
        if (self.isUsingHardwareAccelerate) {
            self.usingHardwareAccelerate = NO;
            NSLog(@"decoder fatal:%@;close videotoolbox hwaccel.",notifi.userInfo);
            NSURL *playingUrl = self.playingUrl;
            [self doStopPlay];
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
//    if (self.playCtrlBtn.state == NSControlStateValueOn) {
//        [self.player play];
//    }
}

- (void)ijkPlayerCouldNotFindCodec:(NSNotification *)notifi
{
    NSLog(@"找不到解码器，联系开发小帅锅：%@",notifi.userInfo);
}

- (void)ijkPlayerDidFinish:(NSNotification *)notifi
{
    if (self.player == notifi.object) {
        int reason = [notifi.userInfo[IJKMPMoviePlayerPlaybackDidFinishReasonUserInfoKey] intValue];
        if (IJKMPMovieFinishReasonPlaybackError == reason) {
            int errCode = [notifi.userInfo[@"code"] intValue];
            NSLog(@"播放出错:%d",errCode);
        } else if (IJKMPMovieFinishReasonPlaybackEnded == reason) {
            NSLog(@"播放结束");
            if ([[MRUtil pictureType] containsObject:[[self.playingUrl lastPathComponent] pathExtension]]) {
//                [self stopPlay];
            } else {
                NSString *key = [[self.playingUrl absoluteString] md5Hash];
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
//                self.playingUrl = nil;
                [self playNext:nil];
            }
        }
    }
}

- (void)updateStreams 
{
    if (self.player.isPreparedToPlay) {
        
        NSDictionary *dic = self.player.monitor.mediaMeta;
        int audioIdx = [dic[k_IJKM_VAL_TYPE__AUDIO] intValue];
        NSLog(@"当前音频：%d",audioIdx);
        int videoIdx = [dic[k_IJKM_VAL_TYPE__VIDEO] intValue];
        NSLog(@"当前视频：%d",videoIdx);
        int subtitleIdx = [dic[k_IJKM_VAL_TYPE__SUBTITLE] intValue];
        NSLog(@"当前字幕：%d",subtitleIdx);
        
        [self.subtitlePopUpBtn removeAllItems];
        NSString *currentTitle = @"选择字幕";
        [self.subtitlePopUpBtn addItemWithTitle:currentTitle];
        
        [self.audioPopUpBtn removeAllItems];
        NSString *currentAudio = @"选择音轨";
        [self.audioPopUpBtn addItemWithTitle:currentAudio];
        
        [self.videoPopUpBtn removeAllItems];
        NSString *currentVideo = @"选择视轨";
        [self.videoPopUpBtn addItemWithTitle:currentVideo];
        
        for (NSDictionary *stream in dic[kk_IJKM_KEY_STREAMS]) {
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
                if ([dic[k_IJKM_VAL_TYPE__SUBTITLE] intValue] == streamIdx) {
                    currentTitle = title;
                }
                [self.subtitlePopUpBtn addItemWithTitle:title];
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
                if ([dic[k_IJKM_VAL_TYPE__AUDIO] intValue] == streamIdx) {
                    currentAudio = title;
                }
                [self.audioPopUpBtn addItemWithTitle:title];
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
                if ([dic[k_IJKM_VAL_TYPE__VIDEO] intValue] == streamIdx) {
                    currentVideo = title;
                }
                [self.videoPopUpBtn addItemWithTitle:title];
            }
        }
        [self.subtitlePopUpBtn selectItemWithTitle:currentTitle];
        [self.audioPopUpBtn selectItemWithTitle:currentAudio];
        [self.videoPopUpBtn selectItemWithTitle:currentVideo];
        
        if (!self.tickTimer) {
            self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(onTick:) userInfo:nil repeats:YES];
        }
    }
}

- (void)ijkPlayerSelectedStreamDidChange:(NSNotification *)notifi
{
    [self updateStreams];
}

- (void)ijkPlayerPreparedToPlay:(NSNotification *)notifi
{
    [self updateStreams];
}

- (void)playURL:(NSURL *)url
{
    if (!url) {
        return;
    }
    [self destroyPlayer];
    [self perpareIJKPlayer:url hwaccel:self.isUsingHardwareAccelerate];
    NSString *videoName = [url isFileURL] ? [url path] : [[url resourceSpecifier] lastPathComponent];
    
    NSInteger idx = [self.playList indexOfObject:self.playingUrl] + 1;
    
    NSString *title = [NSString stringWithFormat:@"(%ld/%ld)%@",(long)idx,[[self playList] count],videoName];
    [self.view.window setTitle:title];
    [self onReset:nil];
    self.playCtrlBtn.state = NSControlStateValueOn;
    
    [self.player prepareToPlay];
    
    if ([self.subtitles count] > 0) {
        NSURL *firstUrl = [self.subtitles firstObject];
        [self.player loadThenActiveSubtitle:firstUrl];
        [self.player loadSubtitlesOnly:[self.subtitles subarrayWithRange:NSMakeRange(1, self.subtitles.count - 1)]];
    }
    
    [self onTick:nil];
}

- (void)enableComputerSleep:(BOOL)enable
{
    AppDelegate *delegate = NSApp.delegate;
    [delegate enableComputerSleep:enable];
}

- (void)onTick:(NSTimer *)sender
{
    long interval = (long)self.player.currentPlaybackTime;
    long duration = self.player.monitor.duration / 1000;
    self.playedTimeLb.stringValue = [NSString stringWithFormat:@"%02d:%02d",(int)(interval/60),(int)(interval%60)];
    self.durationTimeLb.stringValue = [NSString stringWithFormat:@"%02d:%02d",(int)(duration/60),(int)(duration%60)];
    self.playerSlider.playedValue = interval;
    self.playerSlider.minValue = 0;
    self.playerSlider.maxValue = duration;
    self.playerSlider.preloadValue = self.player.playableDuration;
    
    if ([self.player isPlaying]) {
        self.tickCount ++;
        [self enableComputerSleep:NO];
    }
}

- (NSURL *)existTaskForUrl:(NSURL *)url
{
    NSURL *t = nil;
    for (NSURL *item in [self.playList copy]) {
        if ([[item absoluteString] isEqualToString:[url absoluteString]]) {
            t = item;
            break;
        }
    }
    return t;
}

- (void)appendToPlayList:(NSArray *)bookmarkArr reset:(BOOL)reset
{
    NSMutableArray *videos = [NSMutableArray array];
    NSMutableArray *subtitles = [NSMutableArray array];
    
    for (NSDictionary *dic in bookmarkArr) {
        NSURL *url = dic[@"url"];
        
        if ([self existTaskForUrl:url]) {
            continue;
        }
        if ([[[url pathExtension] lowercaseString] isEqualToString:@"xlist"]) {
            if (reset) {
                [self.playList removeAllObjects];
            }
            [self.playList addObjectsFromArray:[MRUtil parseXPlayList:url]];
            [self playFirstIfNeed];
            continue;
        }
        if ([dic[@"type"] intValue] == 0) {
            [videos addObject:url];
        } else if ([dic[@"type"] intValue] == 1) {
            [subtitles addObject:url];
        } else {
            NSAssert(NO, @"没有处理的文件:%@",url);
        }
    }
    
    if ([videos count] > 0) {
        if (reset) {
            [self.playList removeAllObjects];
        }
        [self.playList addObjectsFromArray:videos];
        [self playFirstIfNeed];
    }
    
    if ([subtitles count] > 0) {
        [self.subtitles addObjectsFromArray:subtitles];
        
        NSURL *firstUrl = [subtitles firstObject];
        [subtitles removeObjectAtIndex:0];
        [self.player loadThenActiveSubtitle:firstUrl];
        [self.player loadSubtitlesOnly:subtitles];
    }
}
#pragma mark - 拖拽

- (void)handleDragFileList:(nonnull NSArray<NSURL *> *)fileUrls
{
    NSMutableArray *bookmarkArr = [NSMutableArray array];
    for (NSURL *url in fileUrls) {
        //先判断是不是文件夹
        NSArray *dicArr = [MRUtil scanFolder:url filter:[MRUtil acceptMediaType]];
        if ([dicArr count] > 0) {
            [bookmarkArr addObjectsFromArray:dicArr];
        }
    }
    
    //拖拽进来视频文件时先清空原先的列表
    BOOL needPlay = NO;
    for (NSDictionary *dic in bookmarkArr) {
        if ([dic[@"type"] intValue] == 0) {
            needPlay = YES;
            break;
        }
    }
    
    if (needPlay) {
        [self.playList removeAllObjects];
        [self doStopPlay];
    }
    
    [self appendToPlayList:bookmarkArr reset:YES];
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
                   //扫描文件夹
//                   NSString *dir = [url path];
//                   NSArray *dicArr = [MRUtil scanFolderWithPath:dir filter:[MRUtil acceptMediaType]];
//                    if ([dicArr count] > 0) {
//                        return NSDragOperationCopy;
//                    }
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

- (void)playFirstIfNeed
{
    if (!self.playingUrl) {
        [self pauseOrPlay:nil];
    }
}

#pragma mark - 点击事件

- (IBAction)pauseOrPlay:(NSButton *)sender
{
    if (!sender) {
        if (self.playCtrlBtn.state == NSControlStateValueOff) {
            self.playCtrlBtn.state = NSControlStateValueOn;
        } else {
            self.playCtrlBtn.state = NSControlStateValueOff;
        }
    }
    
    if (self.playingUrl) {
        if (self.playCtrlBtn.state == NSControlStateValueOff) {
            [self enableComputerSleep:YES];
            [self.player pause];
            [self toggleTitleBar:YES];
        } else {
            [self.player play];
        }
    } else {
        [self playNext:nil];
    }
}

- (IBAction)toggleHUD:(id)sender
{
    self.shouldShowHudView = !self.shouldShowHudView;
    self.player.shouldShowHudView = self.shouldShowHudView;
}

- (IBAction)onMoreFunc:(id)sender
{
    [self toggleAdvancedViewShow];
}

- (BOOL)preferHW
{
    return [MRCocoaBindingUserDefault use_hw];
}

- (void)retry
{
    NSURL *url = self.playingUrl;
    [self doStopPlay];
    self.usingHardwareAccelerate = [self preferHW];
    [self playURL:url];
}

- (void)onStop
{
    [self doStopPlay];
}

- (void)destroyPlayer
{
    if (self.player) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:self.player];
        [self.player.view removeFromSuperview];
        [self.player pause];
        [self.player shutdown];
        self.player = nil;
    }
}

- (void)doStopPlay
{
    NSLog(@"stop play");
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
    self.playCtrlBtn.state = NSControlStateValueOff;
}

- (IBAction)playPrevious:(NSButton *)sender
{
    if ([self.playList count] == 0) {
        return;
    }
    
    NSUInteger idx = [self.playList indexOfObject:self.playingUrl];
    if (idx == NSNotFound) {
        idx = 0;
    } else if (idx <= 0) {
        idx = [self.playList count] - 1;
    } else {
        idx --;
    }
    
    NSURL *url = self.playList[idx];
    self.usingHardwareAccelerate = [self preferHW];
    [self playURL:url];
}

- (IBAction)playNext:(NSButton *)sender
{
    if ([self.playList count] == 0) {
        [self doStopPlay];
        return;
    }

    NSUInteger idx = [self.playList indexOfObject:self.playingUrl];
    //when autotest not loop
    if (idx == self.playList.count - 1) {
        [self doStopPlay];
        [self.playList removeAllObjects];
        return;
    }
    
    if (idx == NSNotFound) {
        idx = 0;
    } else if (idx >= [self.playList count] - 1) {
        idx = 0;
    } else {
        idx ++;
    }
    
    NSURL *url = self.playList[idx];
    self.usingHardwareAccelerate = [self preferHW];
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

- (IBAction)fastRewind:(NSButton *)sender
{
    float cp = self.player.currentPlaybackTime;
    cp -= 10;
    [self seekTo:cp];
}

- (IBAction)fastForward:(NSButton *)sender
{    
    if (self.player.playbackState == IJKMPMoviePlaybackStatePaused) {
        [self.player stepToNextFrame];
    } else {
        float cp = self.player.currentPlaybackTime;
        cp += 10;
        [self seekTo:cp];
    }
}

- (IBAction)onVolumeChange:(NSSlider *)sender
{
    self.player.playbackVolume = self.volume;
}

#pragma mark 倍速设置

- (void)updateSpeed:(NSButton *)sender
{
    NSInteger tag = sender.tag;
    float speed = tag / 100.0;
    self.player.playbackRate = speed;
}

#pragma mark 字幕设置

- (IBAction)onChangeSubtitleColor:(NSPopUpButton *)sender
{
    NSMenuItem *item = [sender selectedItem];
    int bgrValue = (int)item.tag;
    IJKSDLSubtitlePreference p = self.player.subtitlePreference;
    p.PrimaryColour = bgrValue;
    self.player.subtitlePreference = p;
}

- (IBAction)onChangeSubtitleSize:(NSStepper *)sender
{
    IJKSDLSubtitlePreference p = self.player.subtitlePreference;
    p.Scale = sender.floatValue / 50;
    self.player.subtitlePreference = p;
}

- (IBAction)onSelectSubtitle:(NSPopUpButton*)sender
{
    if (sender.indexOfSelectedItem == 0) {
        [self.player closeCurrentStream:k_IJKM_VAL_TYPE__SUBTITLE];
    } else {
        NSString *title = sender.selectedItem.title;
        NSArray *items = [title componentsSeparatedByString:@"-"];
        int idx = [[items lastObject] intValue];
        NSLog(@"SelectSubtitleTrack:%d",idx);
        [self.player exchangeSelectedStream:idx];
    }
}

- (IBAction)onChangeSubtitleDelay:(NSStepper *)sender
{
    self.player.currentSubtitleExtraDelay = sender.floatValue;
}

- (IBAction)onChangeSubtitleBottomMargin:(NSSlider *)sender
{
    IJKSDLSubtitlePreference p = self.player.subtitlePreference;
    p.BottomMargin = sender.floatValue;
    self.player.subtitlePreference = p;
}

#pragma mark 画面设置

- (IBAction)onChangeRenderType:(NSPopUpButton *)sender
{
    [self retry];
}

- (IBAction)onChangeScaleMode:(NSPopUpButton *)sender
{
    NSMenuItem *item = [sender selectedItem];
    if (item.tag == 1) {
        //scale to fill
        [self.player setScalingMode:IJKMPMovieScalingModeFill];
    } else if (item.tag == 2) {
        //aspect fill
        [self.player setScalingMode:IJKMPMovieScalingModeAspectFill];
    } else if (item.tag == 3) {
        //aspect fit
        [self.player setScalingMode:IJKMPMovieScalingModeAspectFit];
    }
    
    if (!self.player.isPlaying) {
        [self.player.view setNeedsRefreshCurrentPic];
    }
}

- (IBAction)onRotate:(NSPopUpButton *)sender
{
    NSMenuItem *item = [sender selectedItem];
    
    IJKSDLRotatePreference preference = self.player.view.rotatePreference;
    
    if (item.tag == 0) {
        preference.type = IJKSDLRotateNone;
        preference.degrees = 0;
    } else if (item.tag == 1) {
        preference.type = IJKSDLRotateZ;
        preference.degrees = -90;
    } else if (item.tag == 2) {
        preference.type = IJKSDLRotateZ;
        preference.degrees = -180;
    } else if (item.tag == 3) {
        preference.type = IJKSDLRotateZ;
        preference.degrees = -270;
    } else if (item.tag == 4) {
        preference.type = IJKSDLRotateY;
        preference.degrees = 180;
    } else if (item.tag == 5) {
        preference.type = IJKSDLRotateX;
        preference.degrees = 180;
    }
    
    self.player.view.rotatePreference = preference;
    if (!self.player.isPlaying) {
        [self.player.view setNeedsRefreshCurrentPic];
    }
    NSLog(@"rotate:%@ %d",@[@"None",@"X",@"Y",@"Z"][preference.type],(int)preference.degrees);
}

- (NSString *)saveDir:(NSString *)subDir
{
    NSArray *subDirs = subDir ? @[@"auto-test",subDir] : @[@"auto-test"];
    NSString * path = [NSFileManager mr_DirWithType:NSPicturesDirectory WithPathComponents:subDirs];
    return path;
}

- (NSString *)dirForCurrentPlayingUrl
{
    if ([self.playingUrl isFileURL]) {
        if (![[MRUtil pictureType] containsObject:[[self.playingUrl lastPathComponent] pathExtension]]) {
            return [self saveDir:[[self.playingUrl path] lastPathComponent]];
        } else {
            return [self saveDir:nil];
        }
    }
    return [self saveDir:[[self.playingUrl path] stringByDeletingLastPathComponent]];
}

- (IBAction)onCaptureShot:(id)sender
{
    CGImageRef img = [self.player.view snapshot:self.snapshot];
    if (img) {
        NSString *dir = [self dirForCurrentPlayingUrl];
        NSString *movieName = [self.playingUrl lastPathComponent];
        NSString *fileName = [NSString stringWithFormat:@"%@-%ld.jpg",movieName,(long)(CFAbsoluteTimeGetCurrent() * 1000)];
        NSString *filePath = [dir stringByAppendingPathComponent:fileName];
        NSLog(@"截屏:%@",filePath);
        [MRUtil saveImageToFile:img path:filePath];
    }
}

- (IBAction)onChangeBSC:(NSSlider *)sender
{
    if (sender.tag == 1) {
        self.brightness = sender.floatValue;
    } else if (sender.tag == 2) {
        self.saturation = sender.floatValue;
    } else if (sender.tag == 3) {
        self.contrast = sender.floatValue;
    }
    
    IJKSDLColorConversionPreference colorPreference = self.player.view.colorPreference;
    colorPreference.brightness = self.brightness;//B
    colorPreference.saturation = self.saturation;//S
    colorPreference.contrast = self.contrast;//C
    self.player.view.colorPreference = colorPreference;
    if (!self.player.isPlaying) {
        [self.player.view setNeedsRefreshCurrentPic];
    }
}

- (IBAction)onChangeDAR:(NSPopUpButton *)sender
{
    int dar_num = 0;
    int dar_den = 1;
    if (![sender.titleOfSelectedItem isEqual:@"还原"]) {
        const char* str = sender.titleOfSelectedItem.UTF8String;
        sscanf(str, "%d:%d", &dar_num, &dar_den);
    }
    self.player.view.darPreference = (IJKSDLDARPreference){1.0 * dar_num/dar_den};
    if (!self.player.isPlaying) {
        [self.player.view setNeedsRefreshCurrentPic];
    }
}

- (IBAction)onReset:(NSButton *)sender
{
    if (sender.tag == 1) {
        self.brightness = 1.0;
    } else if (sender.tag == 2) {
        self.saturation = 1.0;
    } else if (sender.tag == 3) {
        self.contrast = 1.0;
    } else {
        self.brightness = 1.0;
        self.saturation = 1.0;
        self.contrast = 1.0;
    }
    
    [self onChangeBSC:nil];
}

#pragma mark 音轨设置

- (IBAction)onSelectAudioTrack:(NSPopUpButton*)sender
{
    if (sender.indexOfSelectedItem == 0) {
        [self.player closeCurrentStream:k_IJKM_VAL_TYPE__AUDIO];
    } else {
        NSString *title = sender.selectedItem.title;
        NSArray *items = [title componentsSeparatedByString:@"-"];
        int idx = [[items lastObject] intValue];
        NSLog(@"SelectAudioTrack:%d",idx);
        [self.player exchangeSelectedStream:idx];
    }
}

- (IBAction)onSelectVideoTrack:(NSPopUpButton*)sender
{
    if (sender.indexOfSelectedItem == 0) {
        [self.player closeCurrentStream:k_IJKM_VAL_TYPE__VIDEO];
    } else {
        NSString *title = sender.selectedItem.title;
        NSArray *items = [title componentsSeparatedByString:@"-"];
        int idx = [[items lastObject] intValue];
        NSLog(@"SelectVideoTrack:%d",idx);
        [self.player exchangeSelectedStream:idx];
    }
}

#pragma mark 解码设置

- (IBAction)onChangedHWaccel:(NSButton *)sender
{
    [self retry];
}

- (IBAction)onChangedAccurateSeek:(NSButton *)sender
{
    [self.player enableAccurateSeek:self.accurateSeek];
}

- (IBAction)onSelectFCC:(NSPopUpButton*)sender
{
    [self retry];
}

#pragma mark 日志级别

- (int)levelWithString:(NSString *)str
{
    str = [str lowercaseString];
    if ([str isEqualToString:@"default"]) {
        return k_IJK_LOG_DEFAULT;
    } else if ([str isEqualToString:@"verbose"]) {
        return k_IJK_LOG_VERBOSE;
    } else if ([str isEqualToString:@"debug"]) {
        return k_IJK_LOG_DEBUG;
    } else if ([str isEqualToString:@"info"]) {
        return k_IJK_LOG_INFO;
    } else if ([str isEqualToString:@"warn"]) {
        return k_IJK_LOG_WARN;
    } else if ([str isEqualToString:@"error"]) {
        return k_IJK_LOG_ERROR;
    } else if ([str isEqualToString:@"fatal"]) {
        return k_IJK_LOG_FATAL;
    } else if ([str isEqualToString:@"silent"]) {
        return k_IJK_LOG_SILENT;
    } else {
        return k_IJK_LOG_UNKNOWN;
    }
}

- (void)reSetLoglevel:(NSString *)loglevel
{
    int level = [self levelWithString:loglevel];
    [IJKFFMoviePlayerController setLogLevel:level];
}

- (IBAction)onChangeLogLevel:(NSPopUpButton*)sender
{
    NSString *title = sender.selectedItem.title;
    [self reSetLoglevel:title];
}

- (IBAction)testMultiRenderSample:(NSButton *)sender
{
    NSURL *playingUrl = self.playingUrl;
    [self doStopPlay];
    
    MultiRenderSample *multiRenderVC = [[MultiRenderSample alloc] initWithNibName:@"MultiRenderSample" bundle:nil];
    
    NSWindowStyleMask mask = NSWindowStyleMaskBorderless | NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView;
    
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600) styleMask:mask backing:NSBackingStoreBuffered defer:YES];
    window.contentViewController = multiRenderVC;
    window.movableByWindowBackground = YES;
    [window makeKeyAndOrderFront:nil];
    window.releasedWhenClosed = NO;
    [multiRenderVC playURL:playingUrl];
}

- (IBAction)openNewInstance:(id)sender
{
    NSWindowStyleMask mask = NSWindowStyleMaskBorderless | NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView;
    
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600) styleMask:mask backing:NSBackingStoreBuffered defer:YES];
    window.contentViewController = [[MRStatisticalViewController alloc] init];
    window.movableByWindowBackground = YES;
    [window makeKeyAndOrderFront:nil];
    window.releasedWhenClosed = NO;
}

@end
