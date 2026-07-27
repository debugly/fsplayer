//
//  MRRootViewController.m
//  AuraPlayer
//
//  Created by debugly on 2021/11/1.
//  Copyright © 2021 FSPlayer Mac. All rights reserved.
//

#import "MRRootViewController.h"
#import "MRDragView.h"
#import "MRUtil+SystemPanel.h"
#import "MRHoverColorButton.h"
#import <FSPlayer/FSPlayer.h>
#import <FSPlayer/FSPlayerKit.h>
#import "MRRenderViewAuxProxy.h"
#import "NSFileManager+Sandbox.h"
#import "MRTrackingView.h"
#import <Quartz/Quartz.h>
#import <Carbon/Carbon.h>
#import "MRGlobalNotification.h"
#import "AppDelegate.h"
#import "MRProgressIndicator.h"
#import "MRRoundCornerView.h"
#import "NSString+Ex.h"
#import "MRPlayerSettingsViewController.h"
#import "MRPlaylistViewController.h"
#import "MRCocoaBindingUserDefault.h"
#import <objc/runtime.h>

static NSString* lastPlayedKey = @"__lastPlayedKey";

@class MRVolumeHoverPillView;

@interface MROverlayView : NSView
@property (nonatomic, copy) void (^onClickOutside)(void);
@property (nonatomic, weak) NSView *innerPanelView;
@end

@implementation MROverlayView

- (void)mouseDown:(NSEvent *)event {
    NSPoint locationInView = [self convertPoint:[event locationInWindow] fromView:nil];
    if (self.innerPanelView && !NSPointInRect(locationInView, self.innerPanelView.frame)) {
        if (self.onClickOutside) {
            self.onClickOutside();
        }
    } else {
        [super mouseDown:event];
    }
}

@end

@interface MRRootViewController ()<MRDragViewDelegate,MRTrackingViewDelegate,NSMenuDelegate,FSVideoRenderingDelegate>

@property (nonatomic, weak) IBOutlet NSView *playerContainer;
@property (nonatomic, weak) IBOutlet NSView *siderBarContainer;
@property (weak) IBOutlet NSLayoutConstraint *siderBarWidthConstraint;

@property (nonatomic, weak) IBOutlet NSView *playerCtrlPanel;

@property (nonatomic, strong) IBOutlet NSTextField *playedTimeLb;
@property (nonatomic, weak) IBOutlet NSTextField *durationTimeLb;
@property (nonatomic, weak) IBOutlet MRHoverColorButton *playCtrlBtn;
@property (nonatomic, weak) IBOutlet MRProgressIndicator *playerSlider;

@property (nonatomic, weak) IBOutlet NSTextField *seekCostLb;
@property (nonatomic, weak) NSTrackingArea *trackingArea;

@property (nonatomic, assign) BOOL seeking;

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
@property (nonatomic, strong, nullable) NSWindow *extraRenderWindow;


@property (nonatomic, assign) BOOL shouldShowHudView;

@property (nonatomic, assign) BOOL loop;

@property (nonatomic, strong) NSView *upgradedCtrlPanel;
@property (nonatomic, strong) MRHoverColorButton *volumeBtn;
@property (nonatomic, strong) NSSlider *volumeSlider;
@property (nonatomic, strong) NSButton *rightPlayPauseBtn;
@property (nonatomic, strong) MRVolumeHoverPillView *volumePillView;

typedef NS_ENUM(NSInteger, MRSidebarType) {
    MRSidebarTypeNone = 0,
    MRSidebarTypeSettings,
    MRSidebarTypePlaylist
};

@property (nonatomic, assign) MRSidebarType activeSidebarType;
@property (nonatomic, strong) MRPlaylistViewController *playlistVC;

@property (nonatomic, strong) MROverlayView *sidebarOverlayView;
@property (nonatomic, strong) NSLayoutConstraint *sidebarTrailingConstraint;
@property (nonatomic, strong) NSView *leftScreenshotPillView;
@property (nonatomic, strong) MRHoverColorButton *fullscreenBtn;

@property (nonatomic, strong) NSView *hoverTimePill;
@property (nonatomic, strong) NSTextField *hoverTimeLb;
@property (nonatomic, strong) NSLayoutConstraint *hoverTimeCenterXConstraint;

@end

@interface MRVolumeHoverPillView : NSView {
    NSTrackingArea *_trackingArea;
}
@property (nonatomic, strong) MRHoverColorButton *volumeBtn;
@property (nonatomic, strong) NSView *sliderContainer;
@property (nonatomic, strong) NSSlider *volumeSlider;
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL action;
@end

@implementation MRVolumeHoverPillView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupView];
    }
    return self;
}

- (void)setupView {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor clearColor].CGColor;
    
    // 1. Create a dedicated circular background view to guarantee a perfect circle under any condition
    NSView *btnBg = [[NSView alloc] init];
    btnBg.translatesAutoresizingMaskIntoConstraints = NO;
    btnBg.wantsLayer = YES;
    btnBg.layer.backgroundColor = [NSColor colorWithWhite:0.15 alpha:0.6].CGColor;
    btnBg.layer.cornerRadius = 18;
    btnBg.layer.masksToBounds = YES;
    [self addSubview:btnBg];
    
    [NSLayoutConstraint activateConstraints:@[
        [btnBg.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [btnBg.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [btnBg.widthAnchor constraintEqualToConstant:36],
        [btnBg.heightAnchor constraintEqualToConstant:36]
    ]];
    
    // 2. Create the volume button centered inside the circular background
    self.volumeBtn = [[MRHoverColorButton alloc] init];
    self.volumeBtn.wantsLayer = YES;
    self.volumeBtn.layer.backgroundColor = [NSColor clearColor].CGColor;
    [self addSubview:self.volumeBtn];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.volumeBtn.centerXAnchor constraintEqualToAnchor:btnBg.centerXAnchor],
        [self.volumeBtn.centerYAnchor constraintEqualToAnchor:btnBg.centerYAnchor],
        [self.volumeBtn.widthAnchor constraintEqualToConstant:36],
        [self.volumeBtn.heightAnchor constraintEqualToConstant:36]
    ]];
    
    // 3. Create the vertical slider container positioned above the button background
    self.sliderContainer = [[NSView alloc] init];
    self.sliderContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.sliderContainer.wantsLayer = YES;
    self.sliderContainer.layer.backgroundColor = [NSColor colorWithWhite:0.15 alpha:0.8].CGColor;
    self.sliderContainer.layer.cornerRadius = 18;
    self.sliderContainer.layer.masksToBounds = YES;
    self.sliderContainer.hidden = YES;
    self.sliderContainer.alphaValue = 0.0;
    [self addSubview:self.sliderContainer];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.sliderContainer.bottomAnchor constraintEqualToAnchor:btnBg.topAnchor constant:-8],
        [self.sliderContainer.centerXAnchor constraintEqualToAnchor:btnBg.centerXAnchor],
        [self.sliderContainer.widthAnchor constraintEqualToConstant:36],
        [self.sliderContainer.heightAnchor constraintEqualToConstant:120]
    ]];
    
    // 4. Create the vertical volume slider
    self.volumeSlider = [[NSSlider alloc] init];
    self.volumeSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.volumeSlider.controlSize = NSControlSizeSmall;
    self.volumeSlider.minValue = 0.0;
    self.volumeSlider.maxValue = 1.0;
    self.volumeSlider.doubleValue = [MRCocoaBindingUserDefault volume];
    self.volumeSlider.vertical = YES;
    [self.sliderContainer addSubview:self.volumeSlider];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.volumeSlider.topAnchor constraintEqualToAnchor:self.sliderContainer.topAnchor constant:12],
        [self.volumeSlider.bottomAnchor constraintEqualToAnchor:self.sliderContainer.bottomAnchor constant:-12],
        [self.volumeSlider.centerXAnchor constraintEqualToAnchor:self.sliderContainer.centerXAnchor],
        [self.volumeSlider.widthAnchor constraintEqualToConstant:20]
    ]];
    
    self.volumeSlider.target = self;
    self.volumeSlider.action = @selector(onSliderChanged:);
}

- (void)onSliderChanged:(NSSlider *)sender {
    [MRCocoaBindingUserDefault setVolume:sender.doubleValue];
    if (self.target && self.action) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self.target performSelector:self.action withObject:sender];
        #pragma clang diagnostic pop
    }
}

- (NSView *)hitTest:(NSPoint)point {
    if (self.isHidden || self.alphaValue < 0.01) return nil;
    
    if (!self.volumeSlider.isHidden) {
        NSPoint pointInSlider = [self convertPoint:point toView:self.sliderContainer];
        if ([self.sliderContainer mouse:pointInSlider inRect:self.sliderContainer.bounds]) {
            return [self.sliderContainer hitTest:pointInSlider];
        }
    }
    return [super hitTest:point];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea != nil) {
        [self removeTrackingArea:_trackingArea];
    }
    
    // Tracking rect covers both button (0, 0, 36, 36) and slider container (0, 44, 36, 120)
    NSRect trackingRect = NSMakeRect(0, 0, 36, 164);
    
    int opts = (NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways);
    _trackingArea = [[NSTrackingArea alloc] initWithRect:trackingRect
                                                 options:opts
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    NSPoint localPoint = [self convertPoint:event.locationInWindow fromView:nil];
    if (self.volumeSlider.isHidden && localPoint.y > 36) {
        return;
    }
    
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
        context.duration = 0.2;
        context.allowsImplicitAnimation = YES;
        self.sliderContainer.hidden = NO;
        self.sliderContainer.alphaValue = 1.0;
    } completionHandler:nil];
}

- (void)mouseExited:(NSEvent *)event {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
        context.duration = 0.2;
        context.allowsImplicitAnimation = YES;
        self.sliderContainer.hidden = YES;
        self.sliderContainer.alphaValue = 0.0;
    } completionHandler:nil];
}

@end

@implementation MRRootViewController

- (void)dealloc
{
    if (self.tickTimer) {
        [self.tickTimer invalidate];
        self.tickTimer = nil;
        self.tickCount = 0;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do view setup here.
    
    //for debug
    //[self.view setWantsLayer:YES];
    //self.view.layer.backgroundColor = [[NSColor redColor] CGColor];
    self.title = @"AuraPlayer";
    self.seekCostLb.stringValue = @"";
    self.loop = 0;
    self.lastSubIdx = -1;
    
    if ([self.view isKindOfClass:[MRTrackingView class]]) {
        MRTrackingView *trackingView = (MRTrackingView *)self.view;
        trackingView.delegate = self;
        trackingView.needTracking = YES;
    }
    
    OBSERVER_NOTIFICATION(self, _playExplorerMovies:,kPlayExplorerMovieNotificationName_G, nil);
    OBSERVER_NOTIFICATION(self, _playNetMovies:,kPlayNetMovieNotificationName_G, nil);
    [self prepareRightMenu];
    __weakSelf__
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
            double duration = indicator.maxValue;
            if (duration > 0) {
                self.playedTimeLb.stringValue = [NSString stringWithFormat:@"%d:%02d / %d:%02d", (int)(interval/60), (int)(interval%60), (int)(duration/60), (int)((int)duration%60)];
            } else {
                self.playedTimeLb.stringValue = [NSString stringWithFormat:@"%d:%02d", (int)(interval/60), (int)(interval%60)];
            }
        }
    }];
    
    self.playedTimeLb.stringValue = @"--:-- / --:--";
    self.durationTimeLb.stringValue = @"--:--";
    
//    [self.siderBarContainer setWantsLayer:YES];
//    self.siderBarContainer.layer.backgroundColor = NSColor.redColor.CGColor;
    
    [self observerCocoaBingsChange];
    [self setupUpgradedPlaybackControls];
    
    self.usingHardwareAccelerate = [self preferHW];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    if (self.view.window) {
        self.view.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    }
}

- (NSView *)wrapInPill:(NSView *)innerView withPaddingX:(CGFloat)paddingX paddingY:(CGFloat)paddingY cornerRadius:(CGFloat)radius {
    NSView *pill = [[NSView alloc] init];
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    pill.wantsLayer = YES;
    pill.layer.backgroundColor = [NSColor colorWithWhite:0.15 alpha:0.6].CGColor;
    pill.layer.cornerRadius = radius;
    pill.layer.masksToBounds = YES;
    
    [pill addSubview:innerView];
    innerView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [innerView.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:paddingX],
        [innerView.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-paddingX],
        [innerView.topAnchor constraintEqualToAnchor:pill.topAnchor constant:paddingY],
        [innerView.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-paddingY]
    ]];
    return pill;
}

- (void)onToggleFullscreenBtnPressed:(id)sender {
    BOOL isCurrentlyFullScreen = (self.view.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
    [self updateFullscreenButtonImage:!isCurrentlyFullScreen];
    [self.view.window toggleFullScreen:nil];
}

- (void)onVolumeBtnPressed:(id)sender {
    float currentVolume = [MRCocoaBindingUserDefault volume];
    if (currentVolume > 0) {
        objc_setAssociatedObject(self, "preMuteVolume", @(currentVolume), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [MRCocoaBindingUserDefault setVolume:0.0];
    } else {
        NSNumber *preMuteVol = objc_getAssociatedObject(self, "preMuteVolume");
        float targetVol = preMuteVol ? [preMuteVol floatValue] : 0.5f;
        if (targetVol <= 0) targetVol = 0.5f;
        [MRCocoaBindingUserDefault setVolume:targetVol];
    }
    [self onVolumeChange:nil];
}

- (void)updateVolumeButtonImage:(NSButton *)btn {
    float currentVolume = [MRCocoaBindingUserDefault volume];
    if (@available(macOS 11.0, *)) {
        if (currentVolume <= 0) {
            btn.image = [NSImage imageWithSystemSymbolName:@"speaker.slash.fill" accessibilityDescription:nil];
        } else if (currentVolume < 0.33) {
            btn.image = [NSImage imageWithSystemSymbolName:@"speaker.wave.1.fill" accessibilityDescription:nil];
        } else if (currentVolume < 0.67) {
            btn.image = [NSImage imageWithSystemSymbolName:@"speaker.wave.2.fill" accessibilityDescription:nil];
        } else {
            btn.image = [NSImage imageWithSystemSymbolName:@"speaker.wave.3.fill" accessibilityDescription:nil];
        }
    } else {
        btn.image = [NSImage imageNamed:NSImageNameTouchBarAudioOutputVolumeHighTemplate];
    }
}

- (void)updatePlayPauseBtnState:(BOOL)isPaused {
    if (isPaused) {
        if (@available(macOS 11.0, *)) {
            NSImage *img = [NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:nil];
            self.playCtrlBtn.image = img;
            if (self.rightPlayPauseBtn) {
                self.rightPlayPauseBtn.image = img;
            }
        } else {
            self.playCtrlBtn.image = [NSImage imageNamed:@"play"];
        }
    } else {
        if (@available(macOS 11.0, *)) {
            NSImage *img = [NSImage imageWithSystemSymbolName:@"pause.fill" accessibilityDescription:nil];
            self.playCtrlBtn.image = img;
            if (self.rightPlayPauseBtn) {
                self.rightPlayPauseBtn.image = img;
            }
        } else {
            self.playCtrlBtn.image = [NSImage imageNamed:@"pause"];
        }
    }
}

- (void)setupUpgradedPlaybackControls {
    NSView *oldCtrlPanel = self.playerCtrlPanel;
    if (!oldCtrlPanel) return;
    
    self.upgradedCtrlPanel = [[NSView alloc] init];
    self.upgradedCtrlPanel.translatesAutoresizingMaskIntoConstraints = NO;
    [oldCtrlPanel.superview addSubview:self.upgradedCtrlPanel positioned:NSWindowAbove relativeTo:oldCtrlPanel];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.upgradedCtrlPanel.leadingAnchor constraintEqualToAnchor:oldCtrlPanel.superview.leadingAnchor],
        [self.upgradedCtrlPanel.trailingAnchor constraintEqualToAnchor:oldCtrlPanel.superview.trailingAnchor],
        [self.upgradedCtrlPanel.bottomAnchor constraintEqualToAnchor:oldCtrlPanel.superview.bottomAnchor],
        [self.upgradedCtrlPanel.heightAnchor constraintEqualToConstant:70]
    ]];
    
    self.upgradedCtrlPanel.alphaValue = oldCtrlPanel.alphaValue;
    
    // Clear all old subviews inside oldCtrlPanel to completely deactivate legacy constraints and avoid conflicts
    for (NSView *subview in [oldCtrlPanel.subviews copy]) {
        [subview removeFromSuperview];
    }
    
    oldCtrlPanel.hidden = YES;
    self.durationTimeLb.hidden = YES;
    self.seekCostLb.hidden = YES;
    
    self.playCtrlBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.playCtrlBtn.bordered = NO;
    self.playCtrlBtn.bezelStyle = NSBezelStyleRegularSquare;
    self.playCtrlBtn.contentTintColor = [NSColor whiteColor];
    
    NSView *playPill = [self wrapInPill:self.playCtrlBtn withPaddingX:8 paddingY:8 cornerRadius:18];
    [playPill.widthAnchor constraintEqualToConstant:36].active = YES;
    [playPill.heightAnchor constraintEqualToConstant:36].active = YES;
    
    NSView *volumePlaceholder = [[NSView alloc] init];
    volumePlaceholder.translatesAutoresizingMaskIntoConstraints = NO;
    [volumePlaceholder.widthAnchor constraintEqualToConstant:36].active = YES;
    [volumePlaceholder.heightAnchor constraintEqualToConstant:36].active = YES;
    
    self.volumePillView = [[MRVolumeHoverPillView alloc] init];
    self.volumeBtn = self.volumePillView.volumeBtn;
    self.volumeSlider = self.volumePillView.volumeSlider;
    
    self.volumeBtn.target = self;
    self.volumeBtn.action = @selector(onVolumeBtnPressed:);
    self.volumePillView.target = self;
    self.volumePillView.action = @selector(onVolumeChange:);
    [self updateVolumeButtonImage:self.volumeBtn];
    
    self.playedTimeLb = [NSTextField labelWithString:@"--:-- / --:--"];
    self.playedTimeLb.textColor = [NSColor whiteColor];
    self.playedTimeLb.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
    self.playedTimeLb.alignment = NSTextAlignmentCenter;
    
    NSView *timePill = [self wrapInPill:self.playedTimeLb withPaddingX:14 paddingY:8 cornerRadius:18];
    [timePill.heightAnchor constraintEqualToConstant:36].active = YES;
    [timePill.widthAnchor constraintEqualToConstant:110].active = YES;
    
    self.playerSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.playerSlider.playedStartColor = [NSColor colorWithRed:229.0/255.0 green:9.0/255.0 blue:20.0/255.0 alpha:1.0];
    self.playerSlider.playedEndColor = [NSColor colorWithRed:229.0/255.0 green:9.0/255.0 blue:20.0/255.0 alpha:1.0];
    self.playerSlider.preloadColor = [NSColor colorWithWhite:1.0 alpha:0.35];
    self.playerSlider.unLoadColor = [NSColor colorWithWhite:0.15 alpha:0.6];
    self.playerSlider.rounded = YES;
    [self.playerSlider.heightAnchor constraintEqualToConstant:20].active = YES;
    [self.playerSlider setContentHuggingPriority:50 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.playerSlider setContentCompressionResistancePriority:50 forOrientation:NSLayoutConstraintOrientationHorizontal];
    
    MRHoverColorButton *playlistBtn = [[MRHoverColorButton alloc] init];
    if (@available(macOS 11.0, *)) {
        playlistBtn.image = [NSImage imageWithSystemSymbolName:@"list.bullet" accessibilityDescription:nil];
    } else {
        playlistBtn.image = [NSImage imageNamed:NSImageNameListViewTemplate];
    }
    [playlistBtn.widthAnchor constraintEqualToConstant:20].active = YES;
    [playlistBtn.heightAnchor constraintEqualToConstant:20].active = YES;
    playlistBtn.target = self;
    playlistBtn.action = @selector(onTogglePlaylistSideBar:);
    
    MRHoverColorButton *settingsBtn = [[MRHoverColorButton alloc] init];
    if (@available(macOS 11.0, *)) {
        settingsBtn.image = [NSImage imageWithSystemSymbolName:@"gearshape.fill" accessibilityDescription:nil];
    } else {
        settingsBtn.image = [NSImage imageNamed:NSImageNameAdvanced];
    }
    [settingsBtn.widthAnchor constraintEqualToConstant:20].active = YES;
    [settingsBtn.heightAnchor constraintEqualToConstant:20].active = YES;
    settingsBtn.target = self;
    settingsBtn.action = @selector(onToggleSettingsSideBar:);
    
    self.fullscreenBtn = [[MRHoverColorButton alloc] init];
    if (@available(macOS 11.0, *)) {
        self.fullscreenBtn.image = [NSImage imageWithSystemSymbolName:@"arrow.up.left.and.arrow.down.right" accessibilityDescription:nil];
    } else {
        self.fullscreenBtn.image = [NSImage imageNamed:NSImageNameEnterFullScreenTemplate];
    }
    [self.fullscreenBtn.widthAnchor constraintEqualToConstant:20].active = YES;
    [self.fullscreenBtn.heightAnchor constraintEqualToConstant:20].active = YES;
    self.fullscreenBtn.target = self;
    self.fullscreenBtn.action = @selector(onToggleFullscreenBtnPressed:);
    
    [self updatePlayPauseBtnState:YES];
    
    NSStackView *rightPillStack = [NSStackView stackViewWithViews:@[playlistBtn, settingsBtn, self.fullscreenBtn]];
    rightPillStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    rightPillStack.alignment = NSLayoutAttributeCenterY;
    rightPillStack.spacing = 15;
    
    NSView *rightPill = [self wrapInPill:rightPillStack withPaddingX:12 paddingY:4 cornerRadius:18];
    [rightPill.heightAnchor constraintEqualToConstant:36].active = YES;
    [rightPill setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [rightPill setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    
    [playPill setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [playPill setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    
    [volumePlaceholder setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [volumePlaceholder setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    
    NSStackView *mainStack = [NSStackView stackViewWithViews:@[playPill, volumePlaceholder, timePill, self.playerSlider, rightPill]];
    mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    mainStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    mainStack.alignment = NSLayoutAttributeCenterY;
    mainStack.spacing = 15;
    
    [self.upgradedCtrlPanel addSubview:mainStack];
    
    // Setup hover time pill
    self.hoverTimeLb = [NSTextField labelWithString:@"00:00"];
    self.hoverTimeLb.textColor = [NSColor whiteColor];
    self.hoverTimeLb.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    self.hoverTimeLb.alignment = NSTextAlignmentCenter;
    
    self.hoverTimePill = [self wrapInPill:self.hoverTimeLb withPaddingX:8 paddingY:4 cornerRadius:8];
    self.hoverTimePill.hidden = YES;
    self.hoverTimePill.translatesAutoresizingMaskIntoConstraints = NO; // Use proper Auto Layout
    [self.upgradedCtrlPanel addSubview:self.hoverTimePill positioned:NSWindowAbove relativeTo:mainStack];
    
    self.hoverTimeCenterXConstraint = [self.hoverTimePill.centerXAnchor constraintEqualToAnchor:self.playerSlider.leadingAnchor constant:0];
    [NSLayoutConstraint activateConstraints:@[
        [self.hoverTimePill.bottomAnchor constraintEqualToAnchor:self.playerSlider.topAnchor constant:-4],
        self.hoverTimeCenterXConstraint
    ]];
    
    __weakSelf__
    [self.playerSlider onHoveredBar:^(double progress, CGFloat hoverX, MRProgressIndicator * _Nonnull indicator) {
        __strongSelf__
        if (indicator.maxValue <= 0) {
            self.hoverTimePill.hidden = YES;
            return;
        }
        
        int interval = progress * indicator.maxValue;
        NSString *timeStr;
        if (indicator.maxValue >= 3600) {
            timeStr = [NSString stringWithFormat:@"%d:%02d:%02d", (int)(interval/3600), (int)((interval%3600)/60), (int)(interval%60)];
        } else {
            timeStr = [NSString stringWithFormat:@"%d:%02d", (int)(interval/60), (int)(interval%60)];
        }
        self.hoverTimeLb.stringValue = timeStr;
        
        // Dynamically compute size based on text constraints
        CGFloat pillWidth = self.hoverTimePill.fittingSize.width;
        if (pillWidth <= 0) {
            pillWidth = 55.0;
        }
        CGFloat halfPillWidth = pillWidth / 2.0;
        
        CGFloat constant = hoverX;
        CGFloat minConstant = halfPillWidth;
        CGFloat maxConstant = indicator.bounds.size.width - halfPillWidth;
        if (constant < minConstant) constant = minConstant;
        if (constant > maxConstant) constant = maxConstant;
        
        self.hoverTimeCenterXConstraint.constant = constant;
        self.hoverTimePill.hidden = NO;
    } onExit:^(MRProgressIndicator * _Nonnull indicator) {
        __strongSelf__
        self.hoverTimePill.hidden = YES;
    }];
    
    [oldCtrlPanel.superview addSubview:self.volumePillView positioned:NSWindowAbove relativeTo:self.upgradedCtrlPanel];
    self.volumePillView.alphaValue = self.upgradedCtrlPanel.alphaValue;
    
    [NSLayoutConstraint activateConstraints:@[
        [mainStack.leadingAnchor constraintEqualToAnchor:self.upgradedCtrlPanel.leadingAnchor constant:20],
        [mainStack.trailingAnchor constraintEqualToAnchor:self.upgradedCtrlPanel.trailingAnchor constant:-20],
        [mainStack.topAnchor constraintEqualToAnchor:self.upgradedCtrlPanel.topAnchor],
        [mainStack.bottomAnchor constraintEqualToAnchor:self.upgradedCtrlPanel.bottomAnchor],
        
        [self.volumePillView.centerXAnchor constraintEqualToAnchor:volumePlaceholder.centerXAnchor],
        [self.volumePillView.bottomAnchor constraintEqualToAnchor:volumePlaceholder.bottomAnchor],
        [self.volumePillView.widthAnchor constraintEqualToConstant:36],
        [self.volumePillView.heightAnchor constraintEqualToConstant:164]
    ]];
    
    // Setup custom left screenshot button (1.5x play button size = 54x54 pill)
    MRHoverColorButton *screenshotBtn = [[MRHoverColorButton alloc] init];
    screenshotBtn.imageScaling = NSImageScaleProportionallyUpOrDown;
    NSImage *cameraImg = nil;
    if (@available(macOS 11.0, *)) {
        NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:22 weight:NSFontWeightMedium];
        cameraImg = [[NSImage imageWithSystemSymbolName:@"camera.fill" accessibilityDescription:nil] imageWithSymbolConfiguration:config];
    } else {
        cameraImg = [NSImage imageNamed:NSImageNameShareTemplate];
    }
    screenshotBtn.image = cameraImg;
    screenshotBtn.target = self;
    screenshotBtn.action = @selector(onCaptureShot);
    
    self.leftScreenshotPillView = [self wrapInPill:screenshotBtn withPaddingX:12 paddingY:12 cornerRadius:27];
    [self.view addSubview:self.leftScreenshotPillView positioned:NSWindowAbove relativeTo:self.upgradedCtrlPanel];
    self.leftScreenshotPillView.alphaValue = self.upgradedCtrlPanel.alphaValue;
    
    [NSLayoutConstraint activateConstraints:@[
        [self.leftScreenshotPillView.widthAnchor constraintEqualToConstant:54],
        [self.leftScreenshotPillView.heightAnchor constraintEqualToConstant:54],
        [self.leftScreenshotPillView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [self.leftScreenshotPillView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
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
        // 追加到列表，开始播放（不主动清空已有播放列表）
        [self appendToPlayList:movies append:YES];
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

- (NSViewController *)viewControllerForSidebarType:(MRSidebarType)type
{
    if (type == MRSidebarTypePlaylist) {
        if (!self.playlistVC) {
            self.playlistVC = [[MRPlaylistViewController alloc] init];
            __weakSelf__
            self.playlistVC.onSelectPlayItem = ^(NSString *url, NSInteger index) {
                __strongSelf__
                [self playURL:url];
            };
            self.playlistVC.onRemovePlayItem = ^(NSInteger index) {
                __strongSelf__
                if (index < [self.playList count]) {
                    NSString *removedUrl = self.playList[index];
                    [self.playList removeObjectAtIndex:index];
                    if ([removedUrl isEqualToString:self.playingUrl]) {
                        if ([self.playList count] > 0) {
                            NSInteger nextIdx = (index < [self.playList count]) ? index : ([self.playList count] - 1);
                            NSString *nextUrl = self.playList[nextIdx];
                            [self playURL:nextUrl];
                        } else {
                            [self doStopPlay];
                        }
                    }
                    [self updatePlaylistView];
                }
            };
            self.playlistVC.onClearPlaylist = ^{
                __strongSelf__
                [self.playList removeAllObjects];
                [self doStopPlay];
                [self updatePlaylistView];
            };
            self.playlistVC.onAddFilesRequested = ^{
                __strongSelf__
                [self openFile:nil];
            };
            self.playlistVC.onFilesDropped = ^(NSArray<NSURL *> *fileUrls) {
                __strongSelf__
                [self handleDragFileList:fileUrls append:YES];
            };
            [self addChildViewController:self.playlistVC];
        }
        [self updatePlaylistView];
        return self.playlistVC;
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
            
            settings.onMultiRendererToggled = ^(BOOL enabled) {
                __strongSelf__
                if (self.playingUrl) {
                    NSString *url = self.playingUrl;
                    [self doStopPlay];
                    [self playURL:url];
                }
            };
            
            created = YES;
            [self addChildViewController:settings];
        }
        if (created) {
            [self updateStreams];
        }
        return settings;
    }
}

- (void)updatePlaylistView
{
    if (self.playlistVC) {
        [self.playlistVC updatePlaylist:self.playList currentlyPlaying:self.playingUrl];
    }
}

- (void)onToggleSettingsSideBar:(id)sender
{
    if (self.activeSidebarType == MRSidebarTypeSettings) {
        [self dismissSettingsSidebar];
    } else {
        [self presentSidebarWithType:MRSidebarTypeSettings];
    }
}

- (void)onTogglePlaylistSideBar:(id)sender
{
    if (self.activeSidebarType == MRSidebarTypePlaylist) {
        [self dismissSettingsSidebar];
    } else {
        [self presentSidebarWithType:MRSidebarTypePlaylist];
    }
}

- (void)showPlayerSettingsSideBar
{
    [self onToggleSettingsSideBar:nil];
}

- (void)presentSidebarWithType:(MRSidebarType)type
{
    NSViewController *vc = [self viewControllerForSidebarType:type];
    NSView *panel = vc.view;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    
    // If overlay already exists (swapping between Settings & Playlist)
    if (self.sidebarOverlayView) {
        if (self.sidebarOverlayView.innerPanelView) {
            [self.sidebarOverlayView.innerPanelView removeFromSuperview];
        }
        self.sidebarOverlayView.innerPanelView = panel;
        [self.sidebarOverlayView addSubview:panel];
        
        NSLayoutConstraint *widthConstraint = [panel.widthAnchor constraintEqualToConstant:320];
        NSLayoutConstraint *topConstraint = [panel.topAnchor constraintEqualToAnchor:self.sidebarOverlayView.topAnchor];
        NSLayoutConstraint *bottomConstraint = [panel.bottomAnchor constraintEqualToAnchor:self.sidebarOverlayView.bottomAnchor];
        NSLayoutConstraint *trailingConstraint = [panel.trailingAnchor constraintEqualToAnchor:self.sidebarOverlayView.trailingAnchor constant:0];
        [NSLayoutConstraint activateConstraints:@[widthConstraint, topConstraint, bottomConstraint, trailingConstraint]];
        self.sidebarTrailingConstraint = trailingConstraint;
        self.activeSidebarType = type;
        return;
    }
    
    // Create full screen overlay view
    MROverlayView *overlay = [[MROverlayView alloc] initWithFrame:self.view.bounds];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.wantsLayer = YES;
    overlay.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.0].CGColor;
    [self.view addSubview:overlay];
    self.sidebarOverlayView = overlay;
    self.activeSidebarType = type;
    
    // Fill superview constraints for overlay
    [NSLayoutConstraint activateConstraints:@[
        [overlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [overlay.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    
    // Set up click outside callback
    __weakSelf__
    overlay.onClickOutside = ^{
        __strongSelf__
        [self dismissSettingsSidebar];
    };
    
    [overlay addSubview:panel];
    overlay.innerPanelView = panel;
    
    // Set width to 320 and anchor top, bottom, and right (initially offscreen)
    NSLayoutConstraint *widthConstraint = [panel.widthAnchor constraintEqualToConstant:320];
    NSLayoutConstraint *topConstraint = [panel.topAnchor constraintEqualToAnchor:overlay.topAnchor];
    NSLayoutConstraint *bottomConstraint = [panel.bottomAnchor constraintEqualToAnchor:overlay.bottomAnchor];
    self.sidebarTrailingConstraint = [panel.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor constant:320];
    
    [NSLayoutConstraint activateConstraints:@[widthConstraint, topConstraint, bottomConstraint, self.sidebarTrailingConstraint]];
    
    [overlay layoutSubtreeIfNeeded];
    
    // Animate slide-in and background dimming
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
        context.duration = 0.3;
        context.allowsImplicitAnimation = YES;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        
        self.sidebarTrailingConstraint.animator.constant = 0;
        overlay.animator.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.25].CGColor;
    }];
}

- (void)presentSettingsSidebar
{
    [self presentSidebarWithType:MRSidebarTypeSettings];
}

- (void)dismissSettingsSidebar
{
    if (!self.sidebarOverlayView) return;
    
    MROverlayView *overlay = self.sidebarOverlayView;
    self.sidebarOverlayView = nil; // Clear reference to avoid races
    self.activeSidebarType = MRSidebarTypeNone;
    
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
        context.duration = 0.25;
        context.allowsImplicitAnimation = YES;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        
        self.sidebarTrailingConstraint.animator.constant = 320;
        overlay.animator.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.0].CGColor;
    } completionHandler:^{
        [overlay removeFromSuperview];
    }];
}

- (void)toggleTitleBar:(BOOL)show
{
    if (self.sidebarOverlayView) {
        show = YES;
    }
    
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
            self.upgradedCtrlPanel.animator.alphaValue = show ? 1.0 : 0.0;
            self.volumePillView.animator.alphaValue = show ? 1.0 : 0.0;
            self.leftScreenshotPillView.animator.alphaValue = show ? 1.0 : 0.0;
        }];
    }
}

- (void)trackingView:(MRTrackingView *)view mouseEntered:(NSEvent *)event
{
    if ([event locationInWindow].y > self.view.bounds.size.height - 35) {
        return;
    }
    [self toggleTitleBar:YES];
}

- (void)trackingView:(MRTrackingView *)view mouseMoved:(NSEvent *)event
{
    if ([event locationInWindow].y > self.view.bounds.size.height - 35) {
        return;
    }
    [self toggleTitleBar:YES];
}

- (void)trackingView:(MRTrackingView *)view mouseExited:(NSEvent *)event
{
    NSPoint location = [event locationInWindow];
    NSPoint localPoint = [self.view convertPoint:location fromView:nil];
    if (NSPointInRect(localPoint, self.view.bounds)) {
        return;
    }
    [self toggleTitleBar:NO];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        switch ([event keyCode]) {
            case kVK_LeftArrow:
            {
                [self playPrevious:nil];
                return YES;
            }
            case kVK_RightArrow:
            {
                [self playNext:nil];
                return YES;
            }
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
                return YES;
            }
            case kVK_ANSI_S:
            {
                [self onCaptureShot];
                return YES;
            }
            case kVK_ANSI_Period:
            {
                [self onStop];
                return YES;
            }
            case kVK_ANSI_H:
            {
                if (event.modifierFlags & NSEventModifierFlagShift) {
                    [self onToggleHUD:nil];
                    return YES;
                }
                break;
            }
            case kVK_ANSI_D:
            {
                [self retry];
                return YES;
            }
        }
    }
    return [super performKeyEquivalent:event];
}

- (void)keyDown:(NSEvent *)event
{
    if (event.window != self.view.window) {
        return;
    }
    
    if (event.modifierFlags & NSEventModifierFlagControl) {
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
    [self updatePlaylistView];
    self.seeking = NO;
    
    FSOptions *options = [FSOptions optionsByDefault];
    
    //isLive表示是直播还是点播
    if (isLive) {
        // Param for living
        [options setPlayerOptionIntValue:1 forKey:@"infbuf"];
        [options setPlayerOptionIntValue:0 forKey:@"packet-buffering"];
        //[options setFormatOptionValue:@"1000000" forKey:@"probesize"];
        [options setFormatOptionValue:@"600000" forKey:@"analyzeduration"];
        //issue https://github.com/debugly/fsplayer/issues/91
        [options setFormatOptionValue:@"5000000" forKey:@"rw_timeout"];
    } else {
        // Param for playback
        [options setPlayerOptionIntValue:0 forKey:@"infbuf"];
        [options setPlayerOptionIntValue:1 forKey:@"packet-buffering"];
        [options setFormatOptionValue:@"1000000" forKey:@"analyzeduration"];
        [options setFormatOptionValue:@"10000000" forKey:@"probesize"];
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
//    [options setFormatOptionValue:@"10000000" forKey:@"probesize"];
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
    //解决FFmpeg7代，百度云盘无法播放问题
    [options setFormatOptionIntValue:0 forKey:@"extension_picky"];
    //[options setFormatOptionValue:@"ts,png" forKey:@"allowed_segment_extensions"];
    //[options setFormatOptionValue:@"ts,png" forKey:@"allowed_extensions"];
    
    BOOL multiRenderer = [[NSUserDefaults standardUserDefaults] boolForKey:@"multi_renderer_enabled"];
    if (multiRenderer) {
        // Create two rendering views: one for main player screen, one for extra floating window
        UIView<FSVideoRenderingProtocol> *render1 = [FSVideoRenderView createMetalRenderView];
        UIView<FSVideoRenderingProtocol> *render2 = [FSVideoRenderView createMetalRenderView];
        
        MRRenderViewAuxProxy *videoAux = [[MRRenderViewAuxProxy alloc] init];
        [videoAux addRenderView:render1];
        [videoAux addRenderView:render2];
        
        self.player = [[FSPlayer alloc] initWithContent:urlStr options:options videoRendering:videoAux audioRendering:[FSAudioRendering createAudioQueueRendering]];
        
        // Setup videoAux in container
        videoAux.frame = self.playerContainer.bounds;
        videoAux.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.playerContainer addSubview:videoAux positioned:NSWindowBelow relativeTo:self.playerCtrlPanel];
        
        // Setup main render view inside videoAux
        NSView<FSVideoRenderingProtocol> *playerView = render1;
        playerView.frame = videoAux.bounds;
        playerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        playerView.allowHDRDirectDisplay = [MRCocoaBindingUserDefault open_hdr];
        [videoAux addSubview:playerView];
        
        playerView.backgroundBlurIterations = 3;
        playerView.backgroundBlurSigma = 30.0;
        playerView.backgroundImage = [NSImage imageNamed:@"demo-bg"];
        [playerView setDisplayDelegate:self];
        
        // Setup second render view in independent window
        if (!self.extraRenderWindow) {
            NSRect screenRect = [[NSScreen mainScreen] visibleFrame];
            NSRect windowRect = NSMakeRect(screenRect.origin.x + 50, screenRect.origin.y + screenRect.size.height - 250, 320, 180);
            NSWindowStyleMask styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
            self.extraRenderWindow = [[NSWindow alloc] initWithContentRect:windowRect
                                                                 styleMask:styleMask
                                                                   backing:NSBackingStoreBuffered
                                                                     defer:NO];
            self.extraRenderWindow.title = @"Extra Renderer Window";
            [[self.extraRenderWindow standardWindowButton:NSWindowCloseButton] setEnabled:NO];
            self.extraRenderWindow.releasedWhenClosed = NO;
            self.extraRenderWindow.movableByWindowBackground = YES;
            [self.extraRenderWindow makeKeyAndOrderFront:nil];
        }
        
        // Add render2 to extra window contentView
        render2.frame = self.extraRenderWindow.contentView.bounds;
        render2.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.extraRenderWindow.contentView addSubview:render2];
    } else {
        // Normal single player mode
        if (self.extraRenderWindow) {
            for (NSView *subview in [self.extraRenderWindow.contentView subviews]) {
                [subview removeFromSuperview];
            }
            [self.extraRenderWindow orderOut:nil];
            [self.extraRenderWindow close];
            self.extraRenderWindow = nil;
        }
        
        self.player = [[FSPlayer alloc] initWithContent:urlStr options:options];
        
        NSView <FSVideoRenderingProtocol>*playerView = self.player.view;
        playerView.frame = self.playerContainer.bounds;
        playerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        playerView.allowHDRDirectDisplay = [MRCocoaBindingUserDefault open_hdr];
        [self.playerContainer addSubview:playerView positioned:NSWindowBelow relativeTo:self.playerCtrlPanel];
        playerView.backgroundBlurIterations = 3;
        playerView.backgroundBlurSigma = 30.0;
        playerView.backgroundImage = [NSImage imageNamed:@"demo-bg"];
        [playerView setDisplayDelegate:self];
    }
    
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
            [MRCocoaBindingUserDefault setValue:@(NO) forKey:@"use_hw"];
            NSLog(@"decoder fatal:%@;close videotoolbox hwaccel and fall back to software decoder.", notifi.userInfo);
            [self.player switchVideoDecoder:NO];
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
    if (self.player == notifi.object) {
        if ([MRCocoaBindingUserDefault lock_screen_ratio]) {
            [self applyLockScreenRatio];
        } else {
            [self.view.window setResizeIncrements:NSMakeSize(1.0, 1.0)];
        }
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
                        [self updatePlayPauseBtnState:YES];
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
    if (duration > 0) {
        self.playedTimeLb.stringValue = [NSString stringWithFormat:@"%d:%02d / %d:%02d", (int)(currentPosition/60), (int)currentPosition%60, (int)duration/60, (int)duration%60];
    } else {
        self.playedTimeLb.stringValue = [NSString stringWithFormat:@"%d:%02d", (int)(currentPosition/60), (int)currentPosition%60];
    }
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
//    isLive = NO;
    [self perpareIJKPlayer:urlStr hwaccel:self.isUsingHardwareAccelerate isLive:isLive];
    NSString *videoName = [urlStr lastPathComponent];
    
    NSInteger idx = [self.playList indexOfObject:self.playingUrl] + 1;
    
    [[NSUserDefaults standardUserDefaults] setObject:videoName forKey:lastPlayedKey];
    
    NSString *title = [NSString stringWithFormat:@"(%ld/%ld)%@",(long)idx,[[self playList] count],videoName];
    [self.view.window setTitle:title];
    
    [self updatePlayPauseBtnState:NO];
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
    if ([url isFileURL]) {
        return [url path];
    }
    //不解析了，路径里可能包含 #33.mp3，原本#是编码的%23，走了下面的逻辑就导致解码了
    return [url absoluteString];
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
    NSString *firstOpenedExistingVideo = nil;
    
    for (NSDictionary *dic in bookmarkArr) {
        NSURL *url = dic[@"url"];
        if ([[[url pathExtension] lowercaseString] isEqualToString:@"xlist"]) {
            for (NSString *u in [MRUtil parseXPlayList:url]) {
                NSString *existing = [self existingInPlayList:u];
                if (existing || [videos containsObject:u]) {
                    if (existing && !firstOpenedExistingVideo) {
                        firstOpenedExistingVideo = existing;
                    }
                    continue;
                }
                [videos addObject:u];
            }
        } else if ([[[url pathExtension] lowercaseString] isEqualToString:@"zlist"]) {
            for (NSString *u in [MRUtil parseZPlayList:url]) {
                NSString *existing = [self existingInPlayList:u];
                if (existing || [videos containsObject:u]) {
                    if (existing && !firstOpenedExistingVideo) {
                        firstOpenedExistingVideo = existing;
                    }
                    continue;
                }
                [videos addObject:u];
            }
        } else if ([dic[@"type"] intValue] == 0) {
            NSString *str = [self decodeURL:url];
            NSString *existing = [self existingInPlayList:str];
            if (existing || [videos containsObject:str]) {
                if (existing && !firstOpenedExistingVideo) {
                    firstOpenedExistingVideo = existing;
                }
                continue;
            }
            [videos addObject:str];
        } else if ([dic[@"type"] intValue] == 1) {
            NSURL *url = dic[@"url"];
            if ([self existingInSubList:url] || [subtitles containsObject:url]) {
                continue;
            }
            [subtitles addObject:url];
        } else {
            NSAssert(NO, @"没有处理的文件:%@",url);
        }
    }
    
    if ([videos count] == 0) {
        [self.subtitles addObjectsFromArray:subtitles];
        if (firstOpenedExistingVideo) {
            [self playURL:firstOpenedExistingVideo];
        } else if (![self playFirstIfNeed]) {
            NSURL *url = [subtitles firstObject];
            if (url) {
                [self.player loadThenActiveSubtitle:url];
            }
        }
        [self updatePlaylistView];
        return;
    }
    
    [self.subtitles addObjectsFromArray:subtitles];
    [self.playList addObjectsFromArray:videos];
    
    if (!self.playingUrl && videos.count > 0) {
        [self playURL:videos.firstObject];
    } else {
        [self playFirstIfNeed];
    }
    [self updatePlaylistView];
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
            [self updatePlayPauseBtnState:YES];
        } else {
            [self.player play];
            [self updatePlayPauseBtnState:NO];
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
    [self onToggleSettingsSideBar:sender];
}

static BOOL useExact = NO;

- (void)startRecord:(NSString *)filePath
{
    int error;
    NSString *type;
    
    if (useExact) {
        type = @"exact";
        error = [self.player startExactRecord:filePath];
    } else {
        type = @"fast";
        error = [self.player startFastRecord:filePath];
    }
    
    if (error) {
        NSLog(@"开始录制 %@,error:%d" ,type ,error);
    } else {
        NSLog(@"开始录制 %@,path:%@" ,type ,filePath);
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
        [self startRecord:filePath];
    }
}

- (IBAction)onToggleMultiRenderer:(NSButton *)sender
{
    BOOL current = [[NSUserDefaults standardUserDefaults] boolForKey:@"multi_renderer_enabled"];
    BOOL newValue = !current;
    [[NSUserDefaults standardUserDefaults] setBool:newValue forKey:@"multi_renderer_enabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    if (self.playingUrl) {
        NSString *url = self.playingUrl;
        [self doStopPlay];
        [self playURL:url];
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
    if (self.extraRenderWindow) {
        for (NSView *subview in [self.extraRenderWindow.contentView subviews]) {
            [subview removeFromSuperview];
        }
        [self.extraRenderWindow orderOut:nil];
        [self.extraRenderWindow close];
        self.extraRenderWindow = nil;
    }
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
    self.playedTimeLb.stringValue = @"--:-- / --:--";
    self.durationTimeLb.stringValue = @"--:--";
    self.playerSlider.playedValue = 0;
    self.playerSlider.preloadValue = 0;
    self.playerSlider.maxValue = 0;
    self.playerSlider.tags = nil;
    self.hoverTimePill.hidden = YES;
    [self enableComputerSleep:YES];
    self.playCtrlBtn.state = NSControlStateValueOn;
    [self updatePlayPauseBtnState:YES];
}

- (void)resetPreferenceEachPlay
{
    self.usingHardwareAccelerate = [self preferHW];
    self.player.view.allowHDRDirectDisplay = [MRCocoaBindingUserDefault open_hdr];

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
    
    NSString *url = self.playList[idx];
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
        double duration = self.player.monitor.duration / 1000.0;
        if (duration > 0) {
            self.playedTimeLb.stringValue = [NSString stringWithFormat:@"%d:%02d / %d:%02d", (int)(interval/60), (int)(interval%60), (int)(duration/60), (int)((int)duration%60)];
        } else {
            self.playedTimeLb.stringValue = [NSString stringWithFormat:@"%d:%02d", (int)(interval/60), (int)(interval%60)];
        }
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
    double vol = [MRCocoaBindingUserDefault volume];
    self.player.playbackVolume = vol;
    if (self.volumeBtn) {
        [self updateVolumeButtonImage:self.volumeBtn];
    }
    if (self.volumeSlider) {
        self.volumeSlider.doubleValue = vol;
    }
}

#pragma mark 倍速设置

- (void)updateSpeed:(NSButton *)sender
{
    NSInteger tag = sender.tag;
    float speed = tag / 100.0;
    [MRCocoaBindingUserDefault setPlayback_speed:speed];
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
        float speed = [v floatValue];
        if (speed <= 0.0) speed = 1.0;
        self.player.playbackRate = speed;
    } forKey:@"playback_speed"];
    
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
        } else {
            [self.view.window setResizeIncrements:NSMakeSize(1.0, 1.0)];
        }
    } forKey:@"lock_screen_ratio"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        [self retry];
    } forKey:@"use_opengl"];
    
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull v, BOOL * _Nonnull r) {
        __strongSelf__
        BOOL use_hw = [v boolValue];
        self.usingHardwareAccelerate = use_hw;
        if (self.player) {
            [self.player switchVideoDecoder:use_hw];
        } else {
            [self retry];
        }
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
        BOOL allow = [MRCocoaBindingUserDefault open_hdr];
        self.player.view.allowHDRDirectDisplay = allow;
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
    NSURL *customURL = [MRCocoaBindingUserDefault snapshotDirectoryURL];
    if (customURL) {
        NSString *movieSubDir = [self.playingUrl lastPathComponent];
        if (!movieSubDir) movieSubDir = @"Captured";
        NSString *dirPath = [customURL.path stringByAppendingPathComponent:movieSubDir];
        [[NSFileManager defaultManager] createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:nil];
        return dirPath;
    }
    return [self saveDir:[self.playingUrl lastPathComponent]];
}

- (void)onCaptureShot
{
    CGImageRef img = [self.player.view snapshot:[MRCocoaBindingUserDefault snapshot_type]];
    if (img) {
        NSString *dir = [self dirForCurrentPlayingUrl];
        NSString *movieName = [self.playingUrl lastPathComponent];
        if (!movieName) movieName = @"capture";
        NSString *fmt = [[NSUserDefaults standardUserDefaults] stringForKey:@"snapshot_format"];
        if (!fmt) fmt = @"jpg";
        NSString *fileName = [NSString stringWithFormat:@"%@-%ld.%@", movieName, (long)(CFAbsoluteTimeGetCurrent() * 1000), fmt];
        NSString *filePath = [dir stringByAppendingPathComponent:fileName];
        NSLog(@"截屏:%@",filePath);
        [MRUtil saveImageToFile:img path:filePath];
    }
}


- (void)updateFullscreenButtonImage:(BOOL)isFullScreen {
    if (!self.fullscreenBtn) return;
    if (@available(macOS 11.0, *)) {
        if (isFullScreen) {
            self.fullscreenBtn.image = [NSImage imageWithSystemSymbolName:@"arrow.down.right.and.arrow.up.left" accessibilityDescription:nil];
        } else {
            self.fullscreenBtn.image = [NSImage imageWithSystemSymbolName:@"arrow.up.left.and.arrow.down.right" accessibilityDescription:nil];
        }
    } else {
        if (isFullScreen) {
            self.fullscreenBtn.image = [NSImage imageNamed:NSImageNameExitFullScreenTemplate];
        } else {
            self.fullscreenBtn.image = [NSImage imageNamed:NSImageNameEnterFullScreenTemplate];
        }
    }
}

@end
