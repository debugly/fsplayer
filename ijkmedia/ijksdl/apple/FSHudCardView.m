/*
 * FSHudCardView.m
 *
 * Copyright (c) 2026 debugly <qianlongxu@gmail.com>
 *
 * This file is part of FSPlayer.
 *
 * FSPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * FSPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FSPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#import "FSHudCardView.h"
#include <sys/sysctl.h>

typedef NS_ENUM(NSUInteger, FSHudCategory) {
    FSHudCategoryFile = 0,
    FSHudCategoryAudio,
    FSHudCategoryVideo,
    FSHudCategoryDisplay,
    FSHudCategoryTCP,
    FSHudCategoryCount
};

static NSString *FSHudCategoryTitle(FSHudCategory cat) {
    switch (cat) {
        case FSHudCategoryFile:    return @"File:";
        case FSHudCategoryAudio:   return @"Audio:";
        case FSHudCategoryVideo:   return @"Video:";
        case FSHudCategoryDisplay: return @"Display:";
        case FSHudCategoryTCP:     return @"TCP / Network:";
        default:                   return @"Other:";
    }
}

static FSHudCategory FSHudCategoryForKey(NSString *key) {
    // 1. File
    if ([key isEqualToString:@"path"] ||
        [key hasPrefix:@"cache-file"] || [key hasPrefix:@"cache-bytes"] ||
        [key hasPrefix:@"cache-physical"] || [key hasPrefix:@"cache-forwards"] ||
        [key hasPrefix:@"async-"]) {
        return FSHudCategoryFile;
    }
    
    // Display / Render
    if ([key isEqualToString:@"v-renderer"] || [key isEqualToString:@"renderer"] ||
        [key isEqualToString:@"delay-avdiff"] || [key hasPrefix:@"fps"] ||
        [key hasPrefix:@"drop-frame"] || [key hasPrefix:@"frames"] ||
        [key isEqualToString:@"v-cache"] || [key isEqualToString:@"a-cache"] ||
        [key isEqualToString:@"prepared"] || [key isEqualToString:@"first-frame"]) {
        return FSHudCategoryDisplay;
    }
    
    // 3. Video
    if ([key isEqualToString:@"vdec"] || [key hasPrefix:@"v-"] ||
        [key isEqualToString:@"resolution"] || [key isEqualToString:@"size"]) {
        return FSHudCategoryVideo;
    }
    
    // 2. Audio
    if ([key hasPrefix:@"a-"]) {
        return FSHudCategoryAudio;
    }
    
    // 5. TCP / Network
    if ([key hasPrefix:@"tcp"] || [key hasPrefix:@"t-"] || [key hasPrefix:@"http"]) {
        return FSHudCategoryTCP;
    }
    
    return FSHudCategoryFile;
}

@interface HudViewCellData : NSObject
@property(nonatomic, copy) NSString *key;
@property(nonatomic, copy) NSString *value;
@end

@implementation HudViewCellData
@end

static NSString *FSGetDeviceChipName(void) {
#if TARGET_OS_OSX
    char buffer[256] = {0};
    size_t size = sizeof(buffer);
    if (sysctlbyname("machdep.cpu.brand_string", buffer, &size, NULL, 0) == 0 && strlen(buffer) > 0) {
        NSString *brand = [NSString stringWithUTF8String:buffer];
        brand = [brand stringByReplacingOccurrencesOfString:@"(TM)" withString:@""];
        brand = [brand stringByReplacingOccurrencesOfString:@"(R)" withString:@""];
        brand = [brand stringByReplacingOccurrencesOfString:@"CPU " withString:@""];
        brand = [brand stringByReplacingOccurrencesOfString:@"@ " withString:@""];
        brand = [brand stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (brand.length > 0) {
            return brand;
        }
    }
    return @"Apple Mac";
#elif TARGET_OS_IOS
    return [UIDevice currentDevice].model ?: @"iOS Device";
#elif TARGET_OS_TV
    return @"Apple TV";
#else
    return @"Apple Device";
#endif
}

#if TARGET_OS_OSX

@interface FSMetalHudSectionHeaderView : NSView
@property (nonatomic, strong) NSTextField *titleLb;
@end

@implementation FSMetalHudSectionHeaderView

- (NSView *)hitTest:(NSPoint)point { return nil; }

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        NSTextField *titleLb = [[NSTextField alloc] init];
        titleLb.editable = NO;
        titleLb.focusRingType = NSFocusRingTypeNone;
        titleLb.bordered = NO;
        titleLb.drawsBackground = NO;
        titleLb.font = [NSFont fontWithName:@"Menlo-Bold" size:11] ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightBold];
        titleLb.usesSingleLineMode = YES;
        titleLb.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [self addSubview:titleLb];
        _titleLb = titleLb;
    }
    return self;
}

- (void)layout
{
    [super layout];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    _titleLb.frame = CGRectMake(10.0, (h - 16) / 2.0, w - 20.0, 16);
}

@end


@interface FSMetalHudRowView : NSView
@property (nonatomic, strong) NSTextField *valueLb;
@end

@implementation FSMetalHudRowView

- (NSView *)hitTest:(NSPoint)point { return nil; }

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        
        NSTextField *valueLb = [[NSTextField alloc] init];
        valueLb.editable = NO;
        valueLb.focusRingType = NSFocusRingTypeNone;
        valueLb.bordered = NO;
        valueLb.drawsBackground = NO;
        valueLb.font = [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        valueLb.textColor = [NSColor whiteColor];
        valueLb.alignment = NSTextAlignmentLeft;
        valueLb.usesSingleLineMode = YES;
        valueLb.lineBreakMode = NSLineBreakByTruncatingMiddle;
        
        [self addSubview:valueLb];
        _valueLb = valueLb;
    }
    return self;
}

- (void)layout
{
    [super layout];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat padding = 10.0;
    _valueLb.frame = CGRectMake(padding, (h - 16) / 2.0, w - padding * 2, 16);
}

@end


@interface FSHudCardView ()

@property (nonatomic, strong) NSTextField *deviceLb;

@property (nonatomic, strong) NSMutableDictionary *keyIndexes;
@property (nonatomic, strong) NSMutableArray<HudViewCellData *> *hudDataArray;

@property (nonatomic, strong) NSMutableArray<FSMetalHudSectionHeaderView *> *sectionHeaderViews;
@property (nonatomic, strong) NSMutableArray<FSMetalHudRowView *> *rowViews;

@end

@implementation FSHudCardView

- (NSView *)hitTest:(NSPoint)point { return nil; }

- (BOOL)isFlipped { return YES; }

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        _keyIndexes = [NSMutableDictionary dictionary];
        _hudDataArray = [NSMutableArray array];
        _sectionHeaderViews = [NSMutableArray array];
        _rowViews = [NSMutableArray array];
        [self setupUI];
    }
    return self;
}

- (void)setupUI
{
    self.wantsLayer = YES;
    self.layer.cornerRadius = 10.0;
    self.layer.masksToBounds = YES;
    self.layer.backgroundColor = [NSColor colorWithRed:12/255.0 green:14/255.0 blue:18/255.0 alpha:0.88].CGColor;
    self.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.15].CGColor;
    self.layer.borderWidth = 1.0;
    
    NSColor *orangeColor = [NSColor colorWithRed:255/255.0 green:149/255.0 blue:0/255.0 alpha:1.0];
    _deviceLb = [self createLabelWithFontSize:12.0 bold:YES textColor:orangeColor];
    _deviceLb.stringValue = FSGetDeviceChipName();
    
    [self addSubview:_deviceLb];
    
    for (NSUInteger cat = 0; cat < FSHudCategoryCount; cat++) {
        FSMetalHudSectionHeaderView *headerView = [[FSMetalHudSectionHeaderView alloc] init];
        headerView.titleLb.stringValue = FSHudCategoryTitle((FSHudCategory)cat);
        headerView.titleLb.textColor = [NSColor colorWithWhite:0.65 alpha:1.0];
        [self addSubview:headerView];
        [_sectionHeaderViews addObject:headerView];
    }
}

- (NSTextField *)createLabelWithFontSize:(CGFloat)size bold:(BOOL)bold textColor:(NSColor *)color
{
    NSTextField *label = [[NSTextField alloc] init];
    label.editable = NO;
    label.focusRingType = NSFocusRingTypeNone;
    label.bordered = NO;
    label.drawsBackground = NO;
    if (bold) {
        label.font = [NSFont fontWithName:@"Menlo-Bold" size:size] ?: [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightBold];
    } else {
        label.font = [NSFont fontWithName:@"Menlo" size:size] ?: [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
    }
    label.usesSingleLineMode = YES;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    label.textColor = color;
    return label;
}

- (void)setDeviceName:(NSString *)deviceName
{
    if (deviceName && deviceName.length > 0) {
        self.deviceLb.stringValue = deviceName;
    }
}

- (void)setHudValue:(NSString *)value forKey:(NSString *)key
{
    if (!key) return;
    
    if ([key isEqualToString:@"v-renderer"] || [key isEqualToString:@"renderer"]) {
        return;
    }
    
    NSNumber *index = [self.keyIndexes objectForKey:key];
    HudViewCellData *data = nil;
    if (index == nil) {
        data = [[HudViewCellData alloc] init];
        data.key = key;
        [self.keyIndexes setObject:@(self.hudDataArray.count) forKey:key];
        [self.hudDataArray addObject:data];
    } else {
        data = [self.hudDataArray objectAtIndex:[index unsignedIntegerValue]];
    }
    data.value = value ?: @"";
    
    [self reloadRowViews];
}

- (void)reloadRowViews
{
    while (self.rowViews.count < self.hudDataArray.count) {
        FSMetalHudRowView *rowView = [[FSMetalHudRowView alloc] init];
        [self addSubview:rowView];
        [self.rowViews addObject:rowView];
    }
    
    self.needsLayout = YES;
    [self invalidateIntrinsicContentSize];
}

- (NSDictionary *)allHudItem
{
    NSMutableDictionary *dic = [NSMutableDictionary dictionary];
    for (HudViewCellData *data in self.hudDataArray) {
        if (data.key && data.value) {
            [dic setValue:data.value forKey:data.key];
        }
    }
    return [dic copy];
}

- (void)layout
{
    [super layout];
    CGFloat w = self.bounds.size.width;
    CGFloat padding = 10.0;
    
    _deviceLb.frame = CGRectMake(padding, 8, w - padding * 2, 16);
    
    NSMutableArray<NSMutableArray<HudViewCellData *> *> *categorizedData = [NSMutableArray arrayWithCapacity:FSHudCategoryCount];
    for (NSUInteger cat = 0; cat < FSHudCategoryCount; cat++) {
        [categorizedData addObject:[NSMutableArray array]];
    }
    
    for (HudViewCellData *data in self.hudDataArray) {
        FSHudCategory cat = FSHudCategoryForKey(data.key);
        [categorizedData[cat] addObject:data];
    }
    
    CGFloat currentY = 28.0;
    CGFloat headerH = 18.0;
    CGFloat rowH = 17.0;
    
    NSUInteger globalRowIndex = 0;
    for (NSUInteger cat = 0; cat < FSHudCategoryCount; cat++) {
        NSArray<HudViewCellData *> *items = categorizedData[cat];
        FSMetalHudSectionHeaderView *secHeader = self.sectionHeaderViews[cat];
        
        if (items.count > 0) {
            secHeader.frame = CGRectMake(0, currentY, w, headerH);
            secHeader.hidden = NO;
            currentY += headerH;
            
            for (HudViewCellData *data in items) {
                if (globalRowIndex < self.rowViews.count) {
                    FSMetalHudRowView *rowView = self.rowViews[globalRowIndex];
                    rowView.valueLb.stringValue = data.value ?: @"";
                    rowView.frame = CGRectMake(0, currentY, w, rowH);
                    rowView.hidden = NO;
                    globalRowIndex++;
                }
                currentY += rowH;
            }
            currentY += 4.0; // Inter-section padding
        } else {
            secHeader.hidden = YES;
        }
    }
    
    while (globalRowIndex < self.rowViews.count) {
        self.rowViews[globalRowIndex].hidden = YES;
        globalRowIndex++;
    }
}

- (CGSize)intrinsicContentSize
{
    NSMutableArray<NSMutableArray<HudViewCellData *> *> *categorizedData = [NSMutableArray arrayWithCapacity:FSHudCategoryCount];
    for (NSUInteger cat = 0; cat < FSHudCategoryCount; cat++) {
        [categorizedData addObject:[NSMutableArray array]];
    }
    for (HudViewCellData *data in self.hudDataArray) {
        FSHudCategory cat = FSHudCategoryForKey(data.key);
        [categorizedData[cat] addObject:data];
    }
    
    CGFloat totalH = 28.0; // Header Y offset
    for (NSUInteger cat = 0; cat < FSHudCategoryCount; cat++) {
        NSUInteger count = categorizedData[cat].count;
        if (count > 0) {
            totalH += 18.0; // Section header
            totalH += count * 17.0; // Section items
            totalH += 4.0; // Padding
        }
    }
    totalH += 6.0; // Bottom card margin
    return CGSizeMake(300.0, totalH);
}

@end

#else

// UIKit Implementation (iOS/tvOS)

@interface FSMetalHudSectionHeaderView : UIView
@property (nonatomic, strong) UILabel *titleLb;
@end

@implementation FSMetalHudSectionHeaderView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        UILabel *titleLb = [[UILabel alloc] init];
        titleLb.font = [UIFont fontWithName:@"Menlo-Bold" size:11] ?: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightBold];
        [self addSubview:titleLb];
        _titleLb = titleLb;
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    _titleLb.frame = CGRectMake(10.0, (h - 16) / 2.0, w - 20.0, 16);
}

@end


@interface FSMetalHudRowView : UIView
@property (nonatomic, strong) UILabel *valueLb;
@end

@implementation FSMetalHudRowView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        
        UILabel *valueLb = [[UILabel alloc] init];
        valueLb.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        valueLb.textColor = [UIColor whiteColor];
        valueLb.textAlignment = NSTextAlignmentLeft;
        valueLb.lineBreakMode = NSLineBreakByTruncatingMiddle;
        
        [self addSubview:valueLb];
        _valueLb = valueLb;
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat padding = 10.0;
    _valueLb.frame = CGRectMake(padding, (h - 16) / 2.0, w - padding * 2, 16);
}

@end


@interface FSHudCardView ()

@property (nonatomic, strong) UILabel *deviceLb;

@property (nonatomic, strong) NSMutableDictionary *keyIndexes;
@property (nonatomic, strong) NSMutableArray<HudViewCellData *> *hudDataArray;

@property (nonatomic, strong) NSMutableArray<FSMetalHudSectionHeaderView *> *sectionHeaderViews;
@property (nonatomic, strong) NSMutableArray<FSMetalHudRowView *> *rowViews;

@end

@implementation FSHudCardView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        _keyIndexes = [NSMutableDictionary dictionary];
        _hudDataArray = [NSMutableArray array];
        _sectionHeaderViews = [NSMutableArray array];
        _rowViews = [NSMutableArray array];
        [self setupUI];
    }
    return self;
}

- (void)setupUI
{
    self.backgroundColor = [UIColor colorWithRed:12/255.0 green:14/255.0 blue:18/255.0 alpha:0.88];
    self.layer.cornerRadius = 10.0;
    self.layer.masksToBounds = YES;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
    self.layer.borderWidth = 1.0;
    
    UIColor *orangeColor = [UIColor colorWithRed:255/255.0 green:149/255.0 blue:0/255.0 alpha:1.0];
    _deviceLb = [self createLabelWithFontSize:12.0 bold:YES textColor:orangeColor];
    _deviceLb.text = FSGetDeviceChipName();
    
    [self addSubview:_deviceLb];
    
    for (NSUInteger cat = 0; cat < FSHudCategoryCount; cat++) {
        FSMetalHudSectionHeaderView *headerView = [[FSMetalHudSectionHeaderView alloc] init];
        headerView.titleLb.text = FSHudCategoryTitle((FSHudCategory)cat);
        headerView.titleLb.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
        [self addSubview:headerView];
        [_sectionHeaderViews addObject:headerView];
    }
}

- (UILabel *)createLabelWithFontSize:(CGFloat)size bold:(BOOL)bold textColor:(UIColor *)color
{
    UILabel *label = [[UILabel alloc] init];
    if (bold) {
        label.font = [UIFont fontWithName:@"Menlo-Bold" size:size] ?: [UIFont monospacedSystemFontOfSize:size weight:UIFontWeightBold];
    } else {
        label.font = [UIFont fontWithName:@"Menlo" size:size] ?: [UIFont monospacedSystemFontOfSize:size weight:UIFontWeightRegular];
    }
    label.textColor = color;
    return label;
}

- (void)setDeviceName:(NSString *)deviceName
{
    if (deviceName && deviceName.length > 0) {
        self.deviceLb.text = deviceName;
    }
}

- (void)setHudValue:(NSString *)value forKey:(NSString *)key
{
    if (!key) return;
    
    if ([key isEqualToString:@"v-renderer"] || [key isEqualToString:@"renderer"]) {
        return;
    }
    
    if (value == nil || value.length == 0) {
        value = @"N/A";
    } else if ([value containsString:@"(null)"]) {
        value = [value stringByReplacingOccurrencesOfString:@"(null)" withString:@"N/A"];
    }
    
    NSNumber *index = [self.keyIndexes objectForKey:key];
    HudViewCellData *data = nil;
    if (index == nil) {
        data = [[HudViewCellData alloc] init];
        data.key = key;
        [self.keyIndexes setObject:@(self.hudDataArray.count) forKey:key];
        [self.hudDataArray addObject:data];
    } else {
        data = [self.hudDataArray objectAtIndex:[index unsignedIntegerValue]];
    }
    data.value = value ?: @"";
    
    [self reloadRowViews];
}

- (void)reloadRowViews
{
    while (self.rowViews.count < self.hudDataArray.count) {
        FSMetalHudRowView *rowView = [[FSMetalHudRowView alloc] init];
        [self addSubview:rowView];
        [self.rowViews addObject:rowView];
    }
    
    [self setNeedsLayout];
    [self invalidateIntrinsicContentSize];
}

- (NSDictionary *)allHudItem
{
    NSMutableDictionary *dic = [NSMutableDictionary dictionary];
    for (HudViewCellData *data in self.hudDataArray) {
        if (data.key && data.value) {
            [dic setValue:data.value forKey:data.key];
        }
    }
    return [dic copy];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat padding = 10.0;
    
    _deviceLb.frame = CGRectMake(padding, 8, w - padding * 2, 16);
    
    NSMutableArray<NSMutableArray<HudViewCellData *> *> *categorizedData = [NSMutableArray arrayWithCapacity:FSHudCategoryCount];
    for (NSUInteger cat = 0; cat < FSHudCategoryCount; cat++) {
        [categorizedData addObject:[NSMutableArray array]];
    }
    
    for (HudViewCellData *data in self.hudDataArray) {
        FSHudCategory cat = FSHudCategoryForKey(data.key);
        [categorizedData[cat] addObject:data];
    }
    
    CGFloat currentY = 28.0;
    CGFloat headerH = 18.0;
    CGFloat rowH = 17.0;
    
    NSUInteger globalRowIndex = 0;
    for (NSUInteger cat = 0; cat < FSHudCategoryCount; cat++) {
        NSArray<HudViewCellData *> *items = categorizedData[cat];
        FSMetalHudSectionHeaderView *secHeader = self.sectionHeaderViews[cat];
        
        if (items.count > 0) {
            secHeader.frame = CGRectMake(0, currentY, w, headerH);
            secHeader.hidden = NO;
            currentY += headerH;
            
            for (HudViewCellData *data in items) {
                if (globalRowIndex < self.rowViews.count) {
                    FSMetalHudRowView *rowView = self.rowViews[globalRowIndex];
                    rowView.valueLb.text = data.value ?: @"";
                    rowView.frame = CGRectMake(0, currentY, w, rowH);
                    rowView.hidden = NO;
                    globalRowIndex++;
                }
                currentY += rowH;
            }
            currentY += 4.0; // Inter-section padding
        } else {
            secHeader.hidden = YES;
        }
    }
    
    while (globalRowIndex < self.rowViews.count) {
        self.rowViews[globalRowIndex].hidden = YES;
        globalRowIndex++;
    }
}

- (CGSize)intrinsicContentSize
{
    NSMutableArray<NSMutableArray<HudViewCellData *> *> *categorizedData = [NSMutableArray arrayWithCapacity:FSHudCategoryCount];
    for (NSUInteger cat = 0; cat < FSHudCategoryCount; cat++) {
        [categorizedData addObject:[NSMutableArray array]];
    }
    for (HudViewCellData *data in self.hudDataArray) {
        FSHudCategory cat = FSHudCategoryForKey(data.key);
        [categorizedData[cat] addObject:data];
    }
    
    CGFloat totalH = 28.0; // Header Y offset
    for (NSUInteger cat = 0; cat < FSHudCategoryCount; cat++) {
        NSUInteger count = categorizedData[cat].count;
        if (count > 0) {
            totalH += 18.0; // Section header
            totalH += count * 17.0; // Section items
            totalH += 4.0; // Padding
        }
    }
    totalH += 6.0; // Bottom card margin
    return CGSizeMake(300.0, totalH);
}

@end

#endif
