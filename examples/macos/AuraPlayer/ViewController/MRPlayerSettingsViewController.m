//
//  MRPlayerSettingsViewController.m
//  AuraPlayer
//
//  Created by debugly on 2024/1/24.
//  Copyright © 2024 FSPlayer Mac. All rights reserved.
//

#import "MRPlayerSettingsViewController.h"
#import <FSPlayer/FSPlayer.h>
#import "MRCocoaBindingUserDefault.h"
#import <objc/runtime.h>

static NSButton *MRCreateSwitch(void) {
    if (@available(macOS 10.15, *)) {
        NSSwitch *sw = [[NSSwitch alloc] init];
        sw.translatesAutoresizingMaskIntoConstraints = NO;
        sw.controlSize = NSControlSizeMini;
        return (NSButton *)sw;
    } else {
        NSButton *chk = [[NSButton alloc] init];
        chk.translatesAutoresizingMaskIntoConstraints = NO;
        chk.buttonType = NSButtonTypeOnOff;
        chk.title = @"";
        return chk;
    }
}

@interface MRPlayerSettingsViewController ()

@property (nonatomic, strong) NSScrollView *scrollView;

// Private views and controllers
@property (nonatomic, strong) NSView *bottomTabBar;
@property (nonatomic, strong) NSButton *videoTabBtn;
@property (nonatomic, strong) NSButton *audioTabBtn;
@property (nonatomic, strong) NSButton *subtitleTabBtn;
@property (nonatomic, strong) NSButton *moreTabBtn;
@property (nonatomic, strong) NSArray<NSButton *> *tabButtons;

@property (nonatomic, strong) NSStackView *videoDocView;
@property (nonatomic, strong) NSStackView *audioDocView;
@property (nonatomic, strong) NSStackView *subtitleDocView;
@property (nonatomic, strong) NSStackView *moreDocView;

// PopUp buttons (re-used tags and names)
@property (nonatomic, strong) NSPopUpButton *subtitlePopUpBtn;
@property (nonatomic, strong) NSPopUpButton *audioPopUpBtn;
@property (nonatomic, strong) NSPopUpButton *videoPopUpBtn;

// Callbacks (reused from legacy)
@property (nonatomic, copy) MRPlayerSettingsCloseStreamBlock closeCurrentStream;
@property (nonatomic, copy) MRPlayerSettingsExchangeStreamBlock exchangeSelectedStream;
@property (nonatomic, copy) dispatch_block_t captureShot;

@property (nonatomic, strong) NSFont *font;

@end

@implementation MRPlayerSettingsViewController

- (void)loadView
{
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 600)];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self setupViewLayout];
}

- (void)setupViewLayout
{
    // 1. Background Blur (Glassmorphism)
    NSVisualEffectView *vibrantView = [[NSVisualEffectView alloc] initWithFrame:self.view.bounds];
    vibrantView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    vibrantView.material = NSVisualEffectMaterialHUDWindow;
    vibrantView.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    vibrantView.state = NSVisualEffectStateActive;
    [self.view addSubview:vibrantView];

    // 2. Bottom Fixed Tab Bar Container
    self.bottomTabBar = [[NSView alloc] init];
    self.bottomTabBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.bottomTabBar.wantsLayer = YES;
    self.bottomTabBar.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.2].CGColor;
    [self.view addSubview:self.bottomTabBar];

    // Bottom tab bar top border separator
    NSView *bottomBorder = [[NSView alloc] init];
    bottomBorder.translatesAutoresizingMaskIntoConstraints = NO;
    bottomBorder.wantsLayer = YES;
    bottomBorder.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.12].CGColor;
    [self.bottomTabBar addSubview:bottomBorder];

    // 3. Tab Buttons
    self.videoTabBtn = [[NSButton alloc] init];
    self.videoTabBtn.title = @"视频";
    self.videoTabBtn.bordered = NO;
    self.videoTabBtn.target = self;
    self.videoTabBtn.action = @selector(onTabClicked:);
    self.videoTabBtn.translatesAutoresizingMaskIntoConstraints = NO;

    self.audioTabBtn = [[NSButton alloc] init];
    self.audioTabBtn.title = @"音频";
    self.audioTabBtn.bordered = NO;
    self.audioTabBtn.target = self;
    self.audioTabBtn.action = @selector(onTabClicked:);
    self.audioTabBtn.translatesAutoresizingMaskIntoConstraints = NO;

    self.subtitleTabBtn = [[NSButton alloc] init];
    self.subtitleTabBtn.title = @"字幕";
    self.subtitleTabBtn.bordered = NO;
    self.subtitleTabBtn.target = self;
    self.subtitleTabBtn.action = @selector(onTabClicked:);
    self.subtitleTabBtn.translatesAutoresizingMaskIntoConstraints = NO;

    self.moreTabBtn = [[NSButton alloc] init];
    self.moreTabBtn.title = @"更多";
    self.moreTabBtn.bordered = NO;
    self.moreTabBtn.target = self;
    self.moreTabBtn.action = @selector(onTabClicked:);
    self.moreTabBtn.translatesAutoresizingMaskIntoConstraints = NO;

    self.tabButtons = @[self.videoTabBtn, self.audioTabBtn, self.subtitleTabBtn, self.moreTabBtn];

    NSStackView *tabsStack = [[NSStackView alloc] init];
    tabsStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    tabsStack.distribution = NSStackViewDistributionFillEqually;
    tabsStack.spacing = 0;
    tabsStack.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *btn in self.tabButtons) {
        [tabsStack addArrangedSubview:btn];
    }
    [self.bottomTabBar addSubview:tabsStack];

    // 4. Scroll View for Content Area
    self.scrollView = [[NSScrollView alloc] init];
    self.scrollView.borderType = NSNoBorder;
    self.scrollView.drawsBackground = NO;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.scrollView];

    // Align content constraints
    [NSLayoutConstraint activateConstraints:@[
        // Scrollview at the top
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.bottomTabBar.topAnchor],

        // Bottom fixed tab bar at bottom
        [self.bottomTabBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.bottomTabBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.bottomTabBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.bottomTabBar.heightAnchor constraintEqualToConstant:54],

        // Tab bar separator
        [bottomBorder.topAnchor constraintEqualToAnchor:self.bottomTabBar.topAnchor],
        [bottomBorder.leadingAnchor constraintEqualToAnchor:self.bottomTabBar.leadingAnchor],
        [bottomBorder.trailingAnchor constraintEqualToAnchor:self.bottomTabBar.trailingAnchor],
        [bottomBorder.heightAnchor constraintEqualToConstant:1],

        // Tab stack centering
        [tabsStack.topAnchor constraintEqualToAnchor:self.bottomTabBar.topAnchor constant:4],
        [tabsStack.leadingAnchor constraintEqualToAnchor:self.bottomTabBar.leadingAnchor],
        [tabsStack.trailingAnchor constraintEqualToAnchor:self.bottomTabBar.trailingAnchor],
        [tabsStack.bottomAnchor constraintEqualToAnchor:self.bottomTabBar.bottomAnchor constant:-4]
    ]];

    // 5. Instantiate Track Popup Buttons
    self.videoPopUpBtn = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.videoPopUpBtn.tag = 2;
    self.videoPopUpBtn.target = self;
    self.videoPopUpBtn.action = @selector(onSelectTrack:);

    self.audioPopUpBtn = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.audioPopUpBtn.tag = 1;
    self.audioPopUpBtn.target = self;
    self.audioPopUpBtn.action = @selector(onSelectTrack:);

    self.subtitlePopUpBtn = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.subtitlePopUpBtn.tag = 3;
    self.subtitlePopUpBtn.target = self;
    self.subtitlePopUpBtn.action = @selector(onSelectTrack:);

    // 6. Build the Four Pages (as NSStackViews)
    [self buildVideoPage];
    [self buildAudioPage];
    [self buildSubtitlePage];
    [self buildMorePage];

    // Default to the first page (Video)
    [self onTabClicked:self.videoTabBtn];
}

- (void)onTabClicked:(NSButton *)sender
{
    for (NSButton *btn in self.tabButtons) {
        [self setButton:btn selected:(btn == sender)];
    }

    NSView *selectedDoc = nil;
    if (sender == self.videoTabBtn) {
        selectedDoc = self.videoDocView;
    } else if (sender == self.audioTabBtn) {
        selectedDoc = self.audioDocView;
    } else if (sender == self.subtitleTabBtn) {
        selectedDoc = self.subtitleDocView;
    } else if (sender == self.moreTabBtn) {
        selectedDoc = self.moreDocView;
    }

    if (selectedDoc) {
        self.scrollView.documentView = selectedDoc;
        [selectedDoc.widthAnchor constraintEqualToAnchor:self.scrollView.contentView.widthAnchor].active = YES;
        
        // Force Auto Layout to compute the new frame sizes immediately
        [self.scrollView layoutSubtreeIfNeeded];
        
        // Scroll to the top of the non-flipped page (top of bounds is height - clipViewHeight)
        CGFloat documentHeight = selectedDoc.bounds.size.height > 0 ? selectedDoc.bounds.size.height : selectedDoc.frame.size.height;
        CGFloat clipViewHeight = self.scrollView.contentView.bounds.size.height;
        CGFloat targetY = MAX(0, documentHeight - clipViewHeight);
        
        [self.scrollView.contentView scrollToPoint:NSMakePoint(0, targetY)];
        [self.scrollView reflectScrolledClipView:self.scrollView.contentView];
    }
}

- (void)setButton:(NSButton *)button selected:(BOOL)selected
{
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = NSTextAlignmentCenter;

    NSDictionary *attrs = @{
        NSForegroundColorAttributeName: selected ? [NSColor whiteColor] : [NSColor secondaryLabelColor],
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:selected ? NSFontWeightBold : NSFontWeightRegular],
        NSParagraphStyleAttributeName: style
    };

    button.attributedTitle = [[NSAttributedString alloc] initWithString:button.title attributes:attrs];
}

#pragma mark - Page Construction Helper Methods

- (NSTextField *)createLabelWithText:(NSString *)text
{
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    label.textColor = [NSColor secondaryLabelColor];
    label.alignment = NSTextAlignmentRight;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [label.widthAnchor constraintEqualToConstant:85].active = YES;
    return label;
}

- (NSView *)createPopUpRowWithLabel:(NSString *)labelTitle popUpButton:(NSPopUpButton *)popUp
{
    NSView *row = [[NSView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.heightAnchor constraintEqualToConstant:24].active = YES;

    NSTextField *lbl = [self createLabelWithText:labelTitle];
    [row addSubview:lbl];

    popUp.controlSize = NSControlSizeSmall;
    popUp.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:popUp];

    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [lbl.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [popUp.leadingAnchor constraintEqualToAnchor:lbl.trailingAnchor constant:8],
        [popUp.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [popUp.widthAnchor constraintEqualToConstant:190],
    ]];

    return row;
}

- (NSSegmentedControl *)createSegmentedWithItems:(NSArray<NSString *> *)items defaultKey:(NSString *)key tags:(NSArray<NSNumber *> *)tags
{
    NSSegmentedControl *seg = [NSSegmentedControl segmentedControlWithLabels:items trackingMode:NSSegmentSwitchTrackingSelectOne target:nil action:nil];
    seg.controlSize = NSControlSizeSmall;
    seg.translatesAutoresizingMaskIntoConstraints = NO;
    [seg.widthAnchor constraintEqualToConstant:190].active = YES;

    [seg bind:@"selectedTag"
       toObject:[NSUserDefaultsController sharedUserDefaultsController]
    withKeyPath:[NSString stringWithFormat:@"values.%@", key]
        options:nil];

    if (tags && tags.count == items.count) {
        for (NSInteger i = 0; i < items.count; i++) {
            [seg setTag:[tags[i] integerValue] forSegment:i];
        }
    }
    return seg;
}

- (NSView *)createSegmentedRowWithLabel:(NSString *)labelTitle segmented:(NSSegmentedControl *)seg
{
    NSView *row = [[NSView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.heightAnchor constraintEqualToConstant:24].active = YES;

    NSTextField *lbl = [self createLabelWithText:labelTitle];
    [row addSubview:lbl];
    [row addSubview:seg];

    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [lbl.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [seg.leadingAnchor constraintEqualToAnchor:lbl.trailingAnchor constant:8],
        [seg.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];

    return row;
}

- (NSView *)createCheckboxRowWithLabel:(NSString *)labelTitle checkbox:(NSButton *)check
{
    NSView *row = [[NSView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.heightAnchor constraintEqualToConstant:24].active = YES;

    NSTextField *lbl = [self createLabelWithText:labelTitle];
    [row addSubview:lbl];
    [row addSubview:check];

    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [lbl.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [check.leadingAnchor constraintEqualToAnchor:lbl.trailingAnchor constant:8],
        [check.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];

    return row;
}

- (NSButton *)createCheckboxWithTitle:(NSString *)title defaultKey:(NSString *)key
{
    NSButton *btn = [NSButton checkboxWithTitle:title target:nil action:nil];
    btn.font = [NSFont systemFontOfSize:11];
    btn.controlSize = NSControlSizeSmall;
    btn.translatesAutoresizingMaskIntoConstraints = NO;

    [btn bind:NSValueBinding
     toObject:[NSUserDefaultsController sharedUserDefaultsController]
  withKeyPath:[NSString stringWithFormat:@"values.%@", key]
      options:nil];

    return btn;
}

- (NSView *)createSliderRowWithLabel:(NSString *)labelTitle defaultKey:(NSString *)key min:(double)minValue max:(double)maxValue defaultValue:(double)defValue format:(NSString *)format
{
    NSView *row = [[NSView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.heightAnchor constraintEqualToConstant:24].active = YES;

    NSTextField *lbl = [self createLabelWithText:labelTitle];
    [row addSubview:lbl];

    NSSlider *slider = [[NSSlider alloc] init];
    slider.controlSize = NSControlSizeMini;
    slider.minValue = minValue;
    slider.maxValue = maxValue;
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:slider];

    NSTextField *valLbl = [NSTextField labelWithString:@""];
    valLbl.font = [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular];
    valLbl.textColor = [NSColor secondaryLabelColor];
    valLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:valLbl];

    // Reset button
    NSButton *resetBtn = [[NSButton alloc] init];
    resetBtn.bezelStyle = NSBezelStyleRecessed;
    resetBtn.controlSize = NSControlSizeMini;
    resetBtn.translatesAutoresizingMaskIntoConstraints = NO;
    resetBtn.bordered = NO;
    if (@available(macOS 11.0, *)) {
        resetBtn.image = [NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:nil];
    } else {
        resetBtn.title = @"↺";
    }
    [row addSubview:resetBtn];

    // Bind slider
    [slider bind:NSValueBinding
        toObject:[NSUserDefaultsController sharedUserDefaultsController]
     withKeyPath:[NSString stringWithFormat:@"values.%@", key]
         options:nil];

    // Observe changes to update text
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull val, BOOL * _Nonnull r) {
        double dVal = [val doubleValue];
        valLbl.stringValue = [NSString stringWithFormat:format, dVal];
    } forKey:key init:YES];

    // Setup reset
    resetBtn.target = self;
    resetBtn.action = @selector(onResetSliderRow:);
    objc_setAssociatedObject(resetBtn, "reset_key", key, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(resetBtn, "reset_val", @(defValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [lbl.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [slider.leadingAnchor constraintEqualToAnchor:lbl.trailingAnchor constant:8],
        [slider.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [slider.widthAnchor constraintEqualToConstant:105],

        [valLbl.leadingAnchor constraintEqualToAnchor:slider.trailingAnchor constant:6],
        [valLbl.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [valLbl.widthAnchor constraintEqualToConstant:35],

        [resetBtn.leadingAnchor constraintEqualToAnchor:valLbl.trailingAnchor constant:4],
        [resetBtn.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [resetBtn.widthAnchor constraintEqualToConstant:20],
        [resetBtn.heightAnchor constraintEqualToConstant:20],
    ]];

    return row;
}

- (void)onResetSliderRow:(NSButton *)sender
{
    NSString *key = objc_getAssociatedObject(sender, "reset_key");
    NSNumber *val = objc_getAssociatedObject(sender, "reset_val");
    if (key && val) {
        [MRCocoaBindingUserDefault setValue:val forKey:key];
    }
}

- (NSView *)createSectionHeaderWithTitle:(NSString *)title
{
    NSTextField *lbl = [NSTextField labelWithString:title];
    lbl.font = [NSFont systemFontOfSize:12 weight:NSFontWeightBold];
    lbl.textColor = [NSColor whiteColor];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *header = [[NSView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:lbl];

    [NSLayoutConstraint activateConstraints:@[
        [header.heightAnchor constraintEqualToConstant:24],
        [lbl.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:4],
        [lbl.centerYAnchor constraintEqualToAnchor:header.centerYAnchor]
    ]];
    return header;
}

- (NSView *)createSeparatorLine
{
    NSView *line = [[NSView alloc] init];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [line.heightAnchor constraintEqualToConstant:1].active = YES;
    line.wantsLayer = YES;
    line.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.08].CGColor;
    return line;
}

#pragma mark - Page Creators

- (void)buildVideoPage
{
    self.videoDocView = [[NSStackView alloc] init];
    self.videoDocView.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoDocView.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.videoDocView.alignment = NSLayoutAttributeLeading;
    self.videoDocView.spacing = 10;
    self.videoDocView.edgeInsets = NSEdgeInsetsMake(15, 16, 15, 16);

    // Section 1: Track
    [self.videoDocView addArrangedSubview:[self createSectionHeaderWithTitle:@"轨道设置"]];
    [self.videoDocView addArrangedSubview:[self createPopUpRowWithLabel:@"选择视轨:" popUpButton:self.videoPopUpBtn]];

    [self.videoDocView addArrangedSubview:[self createSeparatorLine]];

    // Section 2: Picture Mode
    [self.videoDocView addArrangedSubview:[self createSectionHeaderWithTitle:@"画面调节"]];

    NSSegmentedControl *aspectSeg = [self createSegmentedWithItems:@[@"原始", @"4:3", @"16:9", @"1:1"] defaultKey:@"picture_wh_ratio" tags:@[@0, @1, @2, @3]];
    [self.videoDocView addArrangedSubview:[self createSegmentedRowWithLabel:@"画面比例:" segmented:aspectSeg]];

    NSSegmentedControl *scaleSeg = [self createSegmentedWithItems:@[@"适应", @"填充", @"拉伸"] defaultKey:@"picture_fill_mode" tags:@[@0, @1, @2]];
    [self.videoDocView addArrangedSubview:[self createSegmentedRowWithLabel:@"适应模式:" segmented:scaleSeg]];

    NSSegmentedControl *rotateSeg = [self createSegmentedWithItems:@[@"0°", @"90°", @"180°", @"270°"] defaultKey:@"picture_ratate_mode" tags:@[@0, @1, @2, @3]];
    [self.videoDocView addArrangedSubview:[self createSegmentedRowWithLabel:@"画面旋转:" segmented:rotateSeg]];

    [self.videoDocView addArrangedSubview:[self createSeparatorLine]];

    // Section 3: Speed Settings
    [self.videoDocView addArrangedSubview:[self createSectionHeaderWithTitle:@"倍速调节"]];
    [self.videoDocView addArrangedSubview:[self createSpeedRow]];

    [self.videoDocView addArrangedSubview:[self createSeparatorLine]];

    // Section 4: Hardware / Decoding Grouped Card
    [self.videoDocView addArrangedSubview:[self createSectionHeaderWithTitle:@"解码设置"]];
    [self.videoDocView addArrangedSubview:[self createDecodingGroupedCard]];
    
    [self.videoDocView addArrangedSubview:[self createSeparatorLine]];

    // Section 4: Equalizer
    [self.videoDocView addArrangedSubview:[self createSectionHeaderWithTitle:@"色彩调节"]];
    [self.videoDocView addArrangedSubview:[self createSliderRowWithLabel:@"画面亮度:" defaultKey:@"color_adjust_brightness" min:0.5 max:1.5 defaultValue:1.0 format:@"%.2f"]];
    [self.videoDocView addArrangedSubview:[self createSliderRowWithLabel:@"对比亮度:" defaultKey:@"color_adjust_contrast" min:0.5 max:1.5 defaultValue:1.0 format:@"%.2f"]];
    [self.videoDocView addArrangedSubview:[self createSliderRowWithLabel:@"画面饱和:" defaultKey:@"color_adjust_saturation" min:0.5 max:1.5 defaultValue:1.0 format:@"%.2f"]];
}

- (void)buildAudioPage
{
    self.audioDocView = [[NSStackView alloc] init];
    self.audioDocView.translatesAutoresizingMaskIntoConstraints = NO;
    self.audioDocView.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.audioDocView.alignment = NSLayoutAttributeLeading;
    self.audioDocView.spacing = 10;
    self.audioDocView.edgeInsets = NSEdgeInsetsMake(15, 16, 15, 16);

    // Section 1: Track
    [self.audioDocView addArrangedSubview:[self createSectionHeaderWithTitle:@"轨道设置"]];
    [self.audioDocView addArrangedSubview:[self createPopUpRowWithLabel:@"选择音轨:" popUpButton:self.audioPopUpBtn]];

    [self.audioDocView addArrangedSubview:[self createSeparatorLine]];

    // Section 2: Audio Adjustments
    [self.audioDocView addArrangedSubview:[self createSectionHeaderWithTitle:@"音频延迟"]];
    [self.audioDocView addArrangedSubview:[self createSliderRowWithLabel:@"声音延迟:" defaultKey:@"audio_delay" min:-5.0 max:5.0 defaultValue:0.0 format:@"%.2f s"]];
}

- (void)buildSubtitlePage
{
    self.subtitleDocView = [[NSStackView alloc] init];
    self.subtitleDocView.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleDocView.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.subtitleDocView.alignment = NSLayoutAttributeLeading;
    self.subtitleDocView.spacing = 10;
    self.subtitleDocView.edgeInsets = NSEdgeInsetsMake(15, 16, 15, 16);

    // Section 1: Track
    [self.subtitleDocView addArrangedSubview:[self createSectionHeaderWithTitle:@"轨道设置"]];
    [self.subtitleDocView addArrangedSubview:[self createPopUpRowWithLabel:@"选择字幕:" popUpButton:self.subtitlePopUpBtn]];

    [self.subtitleDocView addArrangedSubview:[self createSeparatorLine]];

    // Section 2: Subtitle Adjustments
    [self.subtitleDocView addArrangedSubview:[self createSectionHeaderWithTitle:@"字幕偏好"]];
    [self.subtitleDocView addArrangedSubview:[self createSliderRowWithLabel:@"字幕延迟:" defaultKey:@"subtitle_delay" min:-5.0 max:5.0 defaultValue:0.0 format:@"%.2f s"]];
    [self.subtitleDocView addArrangedSubview:[self createSliderRowWithLabel:@"垂直位置:" defaultKey:@"subtitle_bottom_margin" min:5 max:80 defaultValue:15 format:@"%.0f pt"]];
    [self.subtitleDocView addArrangedSubview:[self createSliderRowWithLabel:@"字幕大小:" defaultKey:@"subtitle_scale" min:0.5 max:2.5 defaultValue:1.0 format:@"%.2f x"]];

    [self.subtitleDocView addArrangedSubview:[self createSeparatorLine]];

    // Section 3: Styles Override
    [self.subtitleDocView addArrangedSubview:[self createSectionHeaderWithTitle:@"字幕样式覆盖"]];
    NSButton *overrideCheck = [self createCheckboxWithTitle:@"启用样式覆盖" defaultKey:@"force_override"];
    [self.subtitleDocView addArrangedSubview:[self createCheckboxRowWithLabel:@"强制样式:" checkbox:overrideCheck]];

    // Font selection button
    NSView *fontRow = [[NSView alloc] init];
    fontRow.translatesAutoresizingMaskIntoConstraints = NO;
    [fontRow.heightAnchor constraintEqualToConstant:24].active = YES;
    NSTextField *fontLbl = [self createLabelWithText:@"字体选项:"];
    [fontRow addSubview:fontLbl];

    NSButton *fontBtn = [NSButton buttonWithTitle:@"选择字体..." target:self action:@selector(onSelectFont:)];
    fontBtn.controlSize = NSControlSizeSmall;
    fontBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [fontRow addSubview:fontBtn];

    [NSLayoutConstraint activateConstraints:@[
        [fontLbl.leadingAnchor constraintEqualToAnchor:fontRow.leadingAnchor],
        [fontLbl.centerYAnchor constraintEqualToAnchor:fontRow.centerYAnchor],
        [fontBtn.leadingAnchor constraintEqualToAnchor:fontLbl.trailingAnchor constant:8],
        [fontBtn.centerYAnchor constraintEqualToAnchor:fontRow.centerYAnchor]
    ]];
    [self.subtitleDocView addArrangedSubview:fontRow];

    // Colors Row (Primary, Secondary, Background)
    [self.subtitleDocView addArrangedSubview:[self createColorsRow]];
}

- (void)buildMorePage
{
    self.moreDocView = [[NSStackView alloc] init];
    self.moreDocView.translatesAutoresizingMaskIntoConstraints = NO;
    self.moreDocView.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.moreDocView.alignment = NSLayoutAttributeLeading;
    self.moreDocView.spacing = 10;
    self.moreDocView.edgeInsets = NSEdgeInsetsMake(15, 16, 15, 16);

    // Section 1: Log Level
    [self.moreDocView addArrangedSubview:[self createSectionHeaderWithTitle:@"日志配置"]];
    
    NSPopUpButton *logPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    NSArray *logItems = @[@"default", @"verbose", @"debug", @"info", @"warn", @"error", @"fatal", @"silent"];
    for (NSString *item in logItems) {
        [logPopUp addItemWithTitle:item];
    }
    logPopUp.controlSize = NSControlSizeSmall;
    logPopUp.translatesAutoresizingMaskIntoConstraints = NO;
    [logPopUp bind:@"selectedValue"
          toObject:[NSUserDefaultsController sharedUserDefaultsController]
       withKeyPath:@"values.log_level"
           options:nil];
           
    [self.moreDocView addArrangedSubview:[self createPopUpRowWithLabel:@"日志级别:" popUpButton:logPopUp]];

    [self.moreDocView addArrangedSubview:[self createSeparatorLine]];

    // Section 2: Screenshot Settings
    [self.moreDocView addArrangedSubview:[self createSectionHeaderWithTitle:@"截图设置"]];
    
    // Save Directory Row
    NSView *dirRow = [[NSView alloc] init];
    dirRow.translatesAutoresizingMaskIntoConstraints = NO;
    [dirRow.heightAnchor constraintEqualToConstant:24].active = YES;
    
    NSTextField *dirLbl = [self createLabelWithText:@"保存目录:"];
    [dirRow addSubview:dirLbl];
    
    NSPathControl *pathCtrl = [[NSPathControl alloc] init];
    pathCtrl.pathStyle = NSPathStylePopUp;
    pathCtrl.controlSize = NSControlSizeSmall;
    pathCtrl.translatesAutoresizingMaskIntoConstraints = NO;
    NSURL *savedURL = [MRCocoaBindingUserDefault snapshotDirectoryURL];
    if (savedURL) {
        pathCtrl.URL = savedURL;
    }
    pathCtrl.target = self;
    pathCtrl.action = @selector(onPathCtrlChanged:);
    [dirRow addSubview:pathCtrl];
    
    [NSLayoutConstraint activateConstraints:@[
        [dirLbl.leadingAnchor constraintEqualToAnchor:dirRow.leadingAnchor],
        [dirLbl.centerYAnchor constraintEqualToAnchor:dirRow.centerYAnchor],
        
        [pathCtrl.leadingAnchor constraintEqualToAnchor:dirLbl.trailingAnchor constant:8],
        [pathCtrl.centerYAnchor constraintEqualToAnchor:dirRow.centerYAnchor],
        [pathCtrl.widthAnchor constraintEqualToConstant:190]
    ]];
    [self.moreDocView addArrangedSubview:dirRow];
    
    // Save Format Row
    NSPopUpButton *fmtPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [fmtPopUp addItemWithTitle:@"jpg"];
    [fmtPopUp addItemWithTitle:@"jpeg"];
    [fmtPopUp addItemWithTitle:@"png"];
    [fmtPopUp addItemWithTitle:@"tiff"];
    [fmtPopUp addItemWithTitle:@"bmp"];
    [fmtPopUp addItemWithTitle:@"gif"];
    [fmtPopUp addItemWithTitle:@"pdf"];
    fmtPopUp.controlSize = NSControlSizeSmall;
    fmtPopUp.translatesAutoresizingMaskIntoConstraints = NO;
    [fmtPopUp bind:@"selectedValue"
          toObject:[NSUserDefaultsController sharedUserDefaultsController]
       withKeyPath:@"values.snapshot_format"
           options:nil];
    [self.moreDocView addArrangedSubview:[self createPopUpRowWithLabel:@"保存格式:" popUpButton:fmtPopUp]];
    
    // Screenshot Method Row
    NSPopUpButton *typePopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [typePopUp addItemWithTitle:@"origin"];
    [typePopUp.lastItem setTag:0];
    [typePopUp addItemWithTitle:@"screen"];
    [typePopUp.lastItem setTag:1];
    [typePopUp addItemWithTitle:@"origin+subtitle"];
    [typePopUp.lastItem setTag:2];
    [typePopUp addItemWithTitle:@"origin+subtitle+effect"];
    [typePopUp.lastItem setTag:3];
    typePopUp.controlSize = NSControlSizeSmall;
    typePopUp.translatesAutoresizingMaskIntoConstraints = NO;
    [typePopUp bind:@"selectedTag"
          toObject:[NSUserDefaultsController sharedUserDefaultsController]
       withKeyPath:@"values.snapshot_type"
           options:nil];
    [self.moreDocView addArrangedSubview:[self createPopUpRowWithLabel:@"截图方式:" popUpButton:typePopUp]];

    [self.moreDocView addArrangedSubview:[self createSeparatorLine]];

    // Section 3: Player Settings
    [self.moreDocView addArrangedSubview:[self createSectionHeaderWithTitle:@"播放器设置"]];
    
    // Playback History Row with NSSwitch
    NSView *historyRow = [[NSView alloc] init];
    historyRow.translatesAutoresizingMaskIntoConstraints = NO;
    [historyRow.heightAnchor constraintEqualToConstant:24].active = YES;
    
    NSTextField *historyLbl = [self createLabelWithText:@"播放记录:"];
    [historyRow addSubview:historyLbl];
    
    NSButton *toggle = MRCreateSwitch();
    [toggle bind:@"value"
        toObject:[NSUserDefaultsController sharedUserDefaultsController]
     withKeyPath:@"values.play_from_history"
         options:nil];
    [historyRow addSubview:toggle];
    
    NSButton *resetBtn = [[NSButton alloc] init];
    resetBtn.title = @"重置";
    resetBtn.bezelStyle = NSBezelStyleRounded;
    resetBtn.controlSize = NSControlSizeSmall;
    resetBtn.translatesAutoresizingMaskIntoConstraints = NO;
    resetBtn.target = self;
    resetBtn.action = @selector(onResetHistory:);
    [historyRow addSubview:resetBtn];
    
    [NSLayoutConstraint activateConstraints:@[
        [historyLbl.leadingAnchor constraintEqualToAnchor:historyRow.leadingAnchor],
        [historyLbl.centerYAnchor constraintEqualToAnchor:historyRow.centerYAnchor],
        
        [toggle.leadingAnchor constraintEqualToAnchor:historyLbl.trailingAnchor constant:8],
        [toggle.centerYAnchor constraintEqualToAnchor:historyRow.centerYAnchor],
        
        [resetBtn.trailingAnchor constraintEqualToAnchor:historyRow.leadingAnchor constant:275],
        [resetBtn.centerYAnchor constraintEqualToAnchor:historyRow.centerYAnchor],
        [resetBtn.widthAnchor constraintEqualToConstant:54]
    ]];
    [self.moreDocView addArrangedSubview:historyRow];
    
    // Accurate Seek Row with NSSwitch
    NSView *seekRow = [[NSView alloc] init];
    seekRow.translatesAutoresizingMaskIntoConstraints = NO;
    [seekRow.heightAnchor constraintEqualToConstant:24].active = YES;
    
    NSTextField *seekLbl = [self createLabelWithText:@"精准Seek:"];
    [seekRow addSubview:seekLbl];
    
    NSButton *seekToggle = MRCreateSwitch();
    [seekToggle bind:@"value"
        toObject:[NSUserDefaultsController sharedUserDefaultsController]
     withKeyPath:@"values.accurate_seek"
         options:nil];
    [seekRow addSubview:seekToggle];
    
    [NSLayoutConstraint activateConstraints:@[
        [seekLbl.leadingAnchor constraintEqualToAnchor:seekRow.leadingAnchor],
        [seekLbl.centerYAnchor constraintEqualToAnchor:seekRow.centerYAnchor],
        [seekToggle.leadingAnchor constraintEqualToAnchor:seekLbl.trailingAnchor constant:8],
        [seekToggle.centerYAnchor constraintEqualToAnchor:seekRow.centerYAnchor]
    ]];
    [self.moreDocView addArrangedSubview:seekRow];
    
    // Lock Ratio Row with NSSwitch
    NSView *ratioRow = [[NSView alloc] init];
    ratioRow.translatesAutoresizingMaskIntoConstraints = NO;
    [ratioRow.heightAnchor constraintEqualToConstant:24].active = YES;
    
    NSTextField *ratioLbl = [self createLabelWithText:@"锁定比例:"];
    [ratioRow addSubview:ratioLbl];
    
    NSButton *ratioToggle = MRCreateSwitch();
    [ratioToggle bind:@"value"
        toObject:[NSUserDefaultsController sharedUserDefaultsController]
     withKeyPath:@"values.lock_screen_ratio"
         options:nil];
    [ratioRow addSubview:ratioToggle];
    
    [NSLayoutConstraint activateConstraints:@[
        [ratioLbl.leadingAnchor constraintEqualToAnchor:ratioRow.leadingAnchor],
        [ratioLbl.centerYAnchor constraintEqualToAnchor:ratioRow.centerYAnchor],
        [ratioToggle.leadingAnchor constraintEqualToAnchor:ratioLbl.trailingAnchor constant:8],
        [ratioToggle.centerYAnchor constraintEqualToAnchor:ratioRow.centerYAnchor]
    ]];
    [self.moreDocView addArrangedSubview:ratioRow];

    // Multi-renderer Row
    NSView *mrRow = [[NSView alloc] init];
    mrRow.translatesAutoresizingMaskIntoConstraints = NO;
    [mrRow.heightAnchor constraintEqualToConstant:24].active = YES;
    
    NSTextField *mrLbl = [self createLabelWithText:@"多路渲染:"];
    [mrRow addSubview:mrLbl];
    
    BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"multi_renderer_enabled"];
    NSButton *mrToggle = MRCreateSwitch();
    mrToggle.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    mrToggle.target = self;
    mrToggle.action = @selector(onMultiRendererSwitchToggled:);
    [mrRow addSubview:mrToggle];
    
    [NSLayoutConstraint activateConstraints:@[
        [mrLbl.leadingAnchor constraintEqualToAnchor:mrRow.leadingAnchor],
        [mrLbl.centerYAnchor constraintEqualToAnchor:mrRow.centerYAnchor],
        
        [mrToggle.leadingAnchor constraintEqualToAnchor:mrLbl.trailingAnchor constant:8],
        [mrToggle.centerYAnchor constraintEqualToAnchor:mrRow.centerYAnchor]
    ]];
    [self.moreDocView addArrangedSubview:mrRow];
}

- (void)onPathCtrlChanged:(NSPathControl *)sender
{
    NSURL *selectedURL = sender.URL;
    if (selectedURL) {
        [MRCocoaBindingUserDefault setSnapshotDirectoryURL:selectedURL];
    }
}

- (void)onMultiRendererSwitchToggled:(NSButton *)sender
{
    BOOL enabled = sender.state == NSControlStateValueOn;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"multi_renderer_enabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (self.onMultiRendererToggled) {
        self.onMultiRendererToggled(enabled);
    }
}

- (void)onResetHistory:(NSButton *)sender
{
    [MRCocoaBindingUserDefault clearAllPlaybackHistory];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"提示";
    alert.informativeText = @"播放历史记录已成功清除！";
    [alert addButtonWithTitle:@"确定"];
    [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
}

- (NSView *)createColorsRow
{
    NSView *row = [[NSView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.heightAnchor constraintEqualToConstant:24].active = YES;

    NSTextField *lbl = [self createLabelWithText:@"字幕颜色:"];
    [row addSubview:lbl];

    NSDictionary *colorBindingOptions = @{ NSValueTransformerNameBindingOption : @"NSKeyedUnarchiveFromData" };

    NSColorWell *c1 = [[NSColorWell alloc] init];
    c1.translatesAutoresizingMaskIntoConstraints = NO;
    [c1.widthAnchor constraintEqualToConstant:50].active = YES;
    [c1.heightAnchor constraintEqualToConstant:22].active = YES;
    [c1 bind:@"value" toObject:[NSUserDefaultsController sharedUserDefaultsController] withKeyPath:@"values.PrimaryColour" options:colorBindingOptions];

    NSColorWell *c2 = [[NSColorWell alloc] init];
    c2.translatesAutoresizingMaskIntoConstraints = NO;
    [c2.widthAnchor constraintEqualToConstant:50].active = YES;
    [c2.heightAnchor constraintEqualToConstant:22].active = YES;
    [c2 bind:@"value" toObject:[NSUserDefaultsController sharedUserDefaultsController] withKeyPath:@"values.SecondaryColour" options:colorBindingOptions];

    NSColorWell *c3 = [[NSColorWell alloc] init];
    c3.translatesAutoresizingMaskIntoConstraints = NO;
    [c3.widthAnchor constraintEqualToConstant:50].active = YES;
    [c3.heightAnchor constraintEqualToConstant:22].active = YES;
    [c3 bind:@"value" toObject:[NSUserDefaultsController sharedUserDefaultsController] withKeyPath:@"values.BackColour" options:colorBindingOptions];

    NSStackView *wellsStack = [[NSStackView alloc] init];
    wellsStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    wellsStack.spacing = 10;
    wellsStack.translatesAutoresizingMaskIntoConstraints = NO;
    [wellsStack addArrangedSubview:c1];
    [wellsStack addArrangedSubview:c2];
    [wellsStack addArrangedSubview:c3];
    [row addSubview:wellsStack];

    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [lbl.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [wellsStack.leadingAnchor constraintEqualToAnchor:lbl.trailingAnchor constant:8],
        [wellsStack.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];

    return row;
}

#pragma mark - Legacy Forwarded Callbacks

- (void)updateTracks:(NSDictionary *)mediaMeta
{
    int audioIdx = [mediaMeta[FS_VAL_TYPE__AUDIO] intValue];
    NSLog(@"当前音频：%d", audioIdx);
    int videoIdx = [mediaMeta[FS_VAL_TYPE__VIDEO] intValue];
    NSLog(@"当前视频：%d", videoIdx);
    int subtitleIdx = [mediaMeta[FS_VAL_TYPE__SUBTITLE] intValue];
    NSLog(@"当前字幕：%d", subtitleIdx);

    [self removeAllItems];

    NSString *currentSubtitle = @"选择字幕";
    [self addSubtitleItemWithTitle:currentSubtitle];
    NSString *currentAudio = @"选择音轨";
    [self addAudioItemWithTitle:currentAudio];
    NSString *currentVideo = @"选择视轨";
    [self addVideoItemWithTitle:currentVideo];

    for (NSDictionary *stream in mediaMeta[FS_KEY_STREAMS]) {
        NSString *type = stream[FS_KEY_STREAM_TYPE];
        int streamIdx = [stream[FS_KEY_STREAM_IDX] intValue];
        if ([type isEqualToString:FS_VAL_TYPE__SUBTITLE]) {
            NSLog(@"subtile meta:%@", stream);
            NSString *url = stream[FS_KEY_EX_SUBTITLE_URL];
            NSString *title = nil;
            if (url) {
                title = [[url lastPathComponent] stringByRemovingPercentEncoding];
            } else {
                title = stream[FS_KEY_TITLE];
                if (title.length == 0) {
                    title = stream[FS_KEY_LANGUAGE];
                }
                if (title.length == 0) {
                    title = @"未知";
                }
            }
            title = [NSString stringWithFormat:@"%@-%d", title, streamIdx];
            if ([mediaMeta[FS_VAL_TYPE__SUBTITLE] intValue] == streamIdx) {
                currentSubtitle = title;
            }
            [self addSubtitleItemWithTitle:title];
        } else if ([type isEqualToString:FS_VAL_TYPE__AUDIO]) {
            NSLog(@"audio meta:%@", stream);
            NSString *title = stream[FS_KEY_TITLE];
            if (title.length == 0) {
                title = stream[FS_KEY_LANGUAGE];
            }
            if (title.length == 0) {
                title = @"未知";
            }
            title = [NSString stringWithFormat:@"%@-%d", title, streamIdx];
            if ([mediaMeta[FS_VAL_TYPE__AUDIO] intValue] == streamIdx) {
                currentAudio = title;
            }
            [self addAudioItemWithTitle:title];
        } else if ([type isEqualToString:FS_VAL_TYPE__VIDEO]) {
            NSLog(@"video meta:%@", stream);
            NSString *title = stream[FS_KEY_TITLE];
            if (title.length == 0) {
                title = stream[FS_KEY_LANGUAGE];
            }
            if (title.length == 0) {
                title = @"未知";
            }
            title = [NSString stringWithFormat:@"%@-%d", title, streamIdx];
            if ([mediaMeta[FS_VAL_TYPE__VIDEO] intValue] == streamIdx) {
                currentVideo = title;
            }
            [self addVideoItemWithTitle:title];
        }
    }
    [self selectAudioItemWithTitle:currentAudio];
    [self selectVideoItemWithTitle:currentVideo];
    [self selectSubtitleItemWithTitle:currentSubtitle];
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

- (void)onSelectTrack:(NSPopUpButton*)sender
{
    if (sender.indexOfSelectedItem == 0) {
        if (self.closeCurrentStream) {
            if (sender.tag == 1) {
                self.closeCurrentStream(FS_VAL_TYPE__AUDIO);
            } else if (sender.tag == 2) {
                self.closeCurrentStream(FS_VAL_TYPE__VIDEO);
            } else if (sender.tag == 3) {
                self.closeCurrentStream(FS_VAL_TYPE__SUBTITLE);
            }
        }
    } else {
        NSString *title = sender.selectedItem.title;
        NSArray *items = [title componentsSeparatedByString:@"-"];
        int idx = [[items lastObject] intValue];
        if (sender.tag == 1) {
            NSLog(@"SelectAudioTrack:%d", idx);
        } else if (sender.tag == 2) {
            NSLog(@"SelectVideoTrack:%d", idx);
        } else if (sender.tag == 3) {
            NSLog(@"SelectSubtitleTrack:%d", idx);
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

#pragma mark - Track popup modifications

- (void)exchangeToNextSubtitle
{
    NSInteger idx = [self.subtitlePopUpBtn indexOfSelectedItem];
    idx++;
    if (idx >= [self.subtitlePopUpBtn numberOfItems]) {
        idx = 0;
    }
    NSMenuItem *item = [self.subtitlePopUpBtn itemAtIndex:idx];
    if (item) {
        [self.subtitlePopUpBtn selectItem:item];
        [self onSelectTrack:self.subtitlePopUpBtn];
    }
}

- (void)removeAllItems
{
    [self.audioPopUpBtn removeAllItems];
    [self.videoPopUpBtn removeAllItems];
    [self.subtitlePopUpBtn removeAllItems];
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

#pragma mark - Speed Control Row

- (NSView *)createSpeedRow
{
    NSView *row = [[NSView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.heightAnchor constraintEqualToConstant:46].active = YES;
    
    // 1. Slider (exponent from -2.0 to 4.0)
    NSSlider *slider = [[NSSlider alloc] init];
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    slider.controlSize = NSControlSizeMini;
    slider.minValue = -2.0;
    slider.maxValue = 4.0;
    slider.numberOfTickMarks = 7;
    slider.tickMarkPosition = NSTickMarkPositionBelow;
    slider.allowsTickMarkValuesOnly = NO;
    [row addSubview:slider];
    
    // 2. Labels below slider: 0.25x, 1x, 4x, 16x
    NSTextField *lbl025 = [NSTextField labelWithString:@"0.25x"];
    lbl025.translatesAutoresizingMaskIntoConstraints = NO;
    lbl025.font = [NSFont systemFontOfSize:8 weight:NSFontWeightRegular];
    lbl025.textColor = [NSColor secondaryLabelColor];
    [row addSubview:lbl025];
    
    NSTextField *lbl1 = [NSTextField labelWithString:@"1x"];
    lbl1.translatesAutoresizingMaskIntoConstraints = NO;
    lbl1.font = [NSFont systemFontOfSize:8 weight:NSFontWeightRegular];
    lbl1.textColor = [NSColor secondaryLabelColor];
    [row addSubview:lbl1];
    
    NSTextField *lbl4 = [NSTextField labelWithString:@"4x"];
    lbl4.translatesAutoresizingMaskIntoConstraints = NO;
    lbl4.font = [NSFont systemFontOfSize:8 weight:NSFontWeightRegular];
    lbl4.textColor = [NSColor secondaryLabelColor];
    [row addSubview:lbl4];
    
    NSTextField *lbl16 = [NSTextField labelWithString:@"16x"];
    lbl16.translatesAutoresizingMaskIntoConstraints = NO;
    lbl16.font = [NSFont systemFontOfSize:8 weight:NSFontWeightRegular];
    lbl16.textColor = [NSColor secondaryLabelColor];
    [row addSubview:lbl16];
    
    // 3. Capsule input field on the right
    NSView *capsuleBg = [[NSView alloc] init];
    capsuleBg.translatesAutoresizingMaskIntoConstraints = NO;
    capsuleBg.wantsLayer = YES;
    capsuleBg.layer.cornerRadius = 6;
    capsuleBg.layer.backgroundColor = [NSColor colorWithWhite:0.12 alpha:0.55].CGColor;
    [row addSubview:capsuleBg];
    
    NSTextField *inputField = [[NSTextField alloc] init];
    inputField.translatesAutoresizingMaskIntoConstraints = NO;
    inputField.bezeled = NO;
    inputField.drawsBackground = NO;
    inputField.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    inputField.textColor = [NSColor whiteColor];
    inputField.alignment = NSTextAlignmentCenter;
    [capsuleBg addSubview:inputField];
    
    NSTextField *xSuffix = [NSTextField labelWithString:@"x"];
    xSuffix.translatesAutoresizingMaskIntoConstraints = NO;
    xSuffix.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    xSuffix.textColor = [NSColor whiteColor];
    [row addSubview:xSuffix];
    
    // Block-safe UI updater
    __weak typeof(slider) weakSlider = slider;
    __weak typeof(inputField) weakInputField = inputField;
    
    __block BOOL isUpdating = NO;
    
    void (^updateUI)(double speed) = ^(double speed) {
        if (isUpdating) return;
        isUpdating = YES;
        
        // Format to 2 decimal places, but strip trailing zeros
        NSString *speedStr = [NSString stringWithFormat:@"%.2f", speed];
        if ([speedStr hasSuffix:@".00"]) {
            speedStr = [speedStr substringToIndex:speedStr.length - 3];
        } else if ([speedStr hasSuffix:@"0"] && [speedStr containsString:@"."]) {
            speedStr = [speedStr substringToIndex:speedStr.length - 1];
        }
        weakInputField.stringValue = speedStr;
        
        // Update slider exponent: v = log2(speed)
        double v = log2(speed);
        if (v < -2.0) v = -2.0;
        if (v > 4.0) v = 4.0;
        weakSlider.doubleValue = v;
        
        isUpdating = NO;
    };
    
    slider.target = self;
    slider.action = @selector(onSpeedSliderChanged:);
    objc_setAssociatedObject(slider, "update_block", updateUI, OBJC_ASSOCIATION_COPY_NONATOMIC);
    
    inputField.target = self;
    inputField.action = @selector(onSpeedTextChanged:);
    objc_setAssociatedObject(inputField, "update_block", updateUI, OBJC_ASSOCIATION_COPY_NONATOMIC);
    
    // Register observation
    [[MRCocoaBindingUserDefault sharedDefault] onChange:^(id _Nonnull val, BOOL * _Nonnull r) {
        double speed = [val doubleValue];
        if (speed <= 0.0) speed = 1.0;
        dispatch_async(dispatch_get_main_queue(), ^{
            updateUI(speed);
        });
    } forKey:@"playback_speed" init:YES];
    
    // Constraints matching precisely 288pt content area width
    [NSLayoutConstraint activateConstraints:@[
        [slider.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:2],
        [slider.topAnchor constraintEqualToAnchor:row.topAnchor constant:4],
        [slider.widthAnchor constraintEqualToConstant:200],
        
        [lbl025.leadingAnchor constraintEqualToAnchor:slider.leadingAnchor constant:2],
        [lbl025.topAnchor constraintEqualToAnchor:slider.bottomAnchor constant:1],
        
        [lbl1.centerXAnchor constraintEqualToAnchor:slider.leadingAnchor constant:67],
        [lbl1.topAnchor constraintEqualToAnchor:slider.bottomAnchor constant:1],
        
        [lbl4.centerXAnchor constraintEqualToAnchor:slider.leadingAnchor constant:133],
        [lbl4.topAnchor constraintEqualToAnchor:slider.bottomAnchor constant:1],
        
        [lbl16.trailingAnchor constraintEqualToAnchor:slider.trailingAnchor constant:-2],
        [lbl16.topAnchor constraintEqualToAnchor:slider.bottomAnchor constant:1],
        
        [capsuleBg.centerYAnchor constraintEqualToAnchor:slider.centerYAnchor],
        [capsuleBg.trailingAnchor constraintEqualToAnchor:xSuffix.leadingAnchor constant:-6],
        [capsuleBg.widthAnchor constraintEqualToConstant:50],
        [capsuleBg.heightAnchor constraintEqualToConstant:22],
        
        [inputField.leadingAnchor constraintEqualToAnchor:capsuleBg.leadingAnchor constant:2],
        [inputField.trailingAnchor constraintEqualToAnchor:capsuleBg.trailingAnchor constant:-2],
        [inputField.centerYAnchor constraintEqualToAnchor:capsuleBg.centerYAnchor],
        
        [xSuffix.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-2],
        [xSuffix.centerYAnchor constraintEqualToAnchor:slider.centerYAnchor],
    ]];
    
    return row;
}

- (void)onSpeedSliderChanged:(NSSlider *)sender
{
    double exponent = sender.doubleValue;
    double speed = pow(2, exponent);
    speed = round(speed * 100.0) / 100.0;
    
    [MRCocoaBindingUserDefault setPlayback_speed:speed];
    
    void (^updateUI)(double) = objc_getAssociatedObject(sender, "update_block");
    if (updateUI) {
        updateUI(speed);
    }
}

- (void)onSpeedTextChanged:(NSTextField *)sender
{
    double speed = [sender doubleValue];
    if (speed < 0.25) speed = 0.25;
    if (speed > 16.0) speed = 16.0;
    speed = round(speed * 100.0) / 100.0;
    
    [MRCocoaBindingUserDefault setPlayback_speed:speed];
    
    void (^updateUI)(double) = objc_getAssociatedObject(sender, "update_block");
    if (updateUI) {
        updateUI(speed);
    }
}

- (NSView *)createDecodingGroupedCard
{
    NSView *card = [[NSView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.wantsLayer = YES;
    card.layer.cornerRadius = 10;
    card.layer.backgroundColor = [NSColor colorWithWhite:0.18 alpha:0.35].CGColor;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [NSColor colorWithWhite:0.3 alpha:0.18].CGColor;
    
    NSStackView *cardStack = [[NSStackView alloc] init];
    cardStack.translatesAutoresizingMaskIntoConstraints = NO;
    cardStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    cardStack.alignment = NSLayoutAttributeLeading;
    cardStack.spacing = 0;
    cardStack.edgeInsets = NSEdgeInsetsMake(0, 16, 0, 16);
    [card addSubview:cardStack];
    
    id (^createCardRow)(NSString *, NSString *) = ^id(NSString *title, NSString *keyPath) {
        NSView *row = [[NSView alloc] init];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [row.heightAnchor constraintEqualToConstant:38].active = YES;
        
        NSTextField *label = [[NSTextField alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.bezeled = NO;
        label.drawsBackground = NO;
        label.editable = NO;
        label.selectable = NO;
        label.stringValue = title;
        label.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
        label.textColor = [NSColor whiteColor];
        [row addSubview:label];
        
        NSButton *toggle = MRCreateSwitch();
        [toggle bind:NSValueBinding
            toObject:[NSUserDefaultsController sharedUserDefaultsController]
         withKeyPath:[NSString stringWithFormat:@"values.%@", keyPath]
             options:nil];
        [row addSubview:toggle];
        
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [toggle.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [toggle.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
        ]];
        
        return row;
    };
    
    NSView *row1 = createCardRow(@"Hardware Decoding", @"use_hw");
    NSView *row2 = createCardRow(@"Deinterlace", @"de_interlace");
    NSView *row3 = createCardRow(@"HDR", @"open_hdr");
    
    NSView *sep1 = [[NSView alloc] init];
    sep1.translatesAutoresizingMaskIntoConstraints = NO;
    sep1.wantsLayer = YES;
    sep1.layer.backgroundColor = [NSColor colorWithWhite:0.3 alpha:0.15].CGColor;
    [sep1.heightAnchor constraintEqualToConstant:1].active = YES;
    
    NSView *sep2 = [[NSView alloc] init];
    sep2.translatesAutoresizingMaskIntoConstraints = NO;
    sep2.wantsLayer = YES;
    sep2.layer.backgroundColor = [NSColor colorWithWhite:0.3 alpha:0.15].CGColor;
    [sep2.heightAnchor constraintEqualToConstant:1].active = YES;
    
    [cardStack addArrangedSubview:row1];
    [cardStack addArrangedSubview:sep1];
    [cardStack addArrangedSubview:row2];
    [cardStack addArrangedSubview:sep2];
    [cardStack addArrangedSubview:row3];
    
    [NSLayoutConstraint activateConstraints:@[
        [cardStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [cardStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [cardStack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [cardStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        
        [sep1.leadingAnchor constraintEqualToAnchor:cardStack.leadingAnchor constant:16],
        [sep1.trailingAnchor constraintEqualToAnchor:cardStack.trailingAnchor constant:-16],
        
        [sep2.leadingAnchor constraintEqualToAnchor:cardStack.leadingAnchor constant:16],
        [sep2.trailingAnchor constraintEqualToAnchor:cardStack.trailingAnchor constant:-16],
        
        [row1.widthAnchor constraintEqualToAnchor:cardStack.widthAnchor constant:-32],
        [row2.widthAnchor constraintEqualToAnchor:cardStack.widthAnchor constant:-32],
        [row3.widthAnchor constraintEqualToAnchor:cardStack.widthAnchor constant:-32]
    ]];
    
    return card;
}

@end
