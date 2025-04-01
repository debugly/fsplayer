/*
 * FSSDLHudControl.h
 *
 * Copyright (c) 2013-2014 Bilibili
 * Copyright (c) 2013-2014 Zhang Rui <bbcallen@gmail.com>
 * Copyright (c) 2019 debugly <qianlongxu@gmail.com>
 *
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

#import "FSSDLHudControl.h"
#if TARGET_OS_OSX
#import "FSHudRowView.h"
typedef NSScrollView HudContentView;
typedef NSTableView UITableView;
#else
#import "FSSDLHudViewCell.h"
typedef UITableView HudContentView;
#endif

@interface HudViewCellData : NSObject
@property(nonatomic) NSString *key;
@property(nonatomic) NSString *value;
@end

@implementation HudViewCellData
@end


@interface FSSDLHudControl ()
#if TARGET_OS_OSX
<NSTableViewDelegate,NSTableViewDataSource>
#else
<UITableViewDelegate,UITableViewDataSource>
#endif

@property (nonatomic, strong) NSMutableDictionary *keyIndexes;
@property (nonatomic, strong) NSMutableArray *hudDataArray;
@property (nonatomic, strong) HudContentView *view;

@end

@implementation FSSDLHudControl

- (NSMutableDictionary *)keyIndexes
{
    if (!_keyIndexes) {
        _keyIndexes = [NSMutableDictionary dictionary];
    }
    return _keyIndexes;
}

- (NSMutableArray *)hudDataArray
{
    if (!_hudDataArray) {
        _hudDataArray = [NSMutableArray array];
    }
    return _hudDataArray;
}

- (UIView *)contentView
{
    if (!self.view) {
        self.view = [self prepareContentView];
    }
    return self.view;
}

- (void)destroyContentView
{
    [self.view removeFromSuperview];
    self.view = nil;
}

- (void)setHudValue:(NSString *)value forKey:(NSString *)key
{
    HudViewCellData *data = nil;
    NSNumber *index = [self.keyIndexes objectForKey:key];
    if (index == nil) {
        data = [[HudViewCellData alloc] init];
        data.key = key;
        [self.keyIndexes setObject:[NSNumber numberWithUnsignedInteger:self.hudDataArray.count]
                        forKey:key];
        [self.hudDataArray addObject:data];
    } else {
        data = [self.hudDataArray objectAtIndex:[index unsignedIntegerValue]];
    }

    data.value = value;
    [self.tableView reloadData];
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

#if TARGET_OS_OSX
- (NSScrollView *)prepareContentView
{
    NSScrollView * scrollView = [[NSScrollView alloc] initWithFrame:CGRectMake(0, 0, 200, 300)];
    scrollView.hasVerticalScroller = NO;
    scrollView.hasHorizontalScroller = NO;
    scrollView.drawsBackground = NO;
    NSTableView *tableView = [[NSTableView alloc] initWithFrame:self.view.bounds];
    tableView.autoresizingMask = NSViewHeightSizable | NSViewWidthSizable;
    tableView.intercellSpacing = NSMakeSize(0, 0);
    tableView.delegate = self;
    tableView.dataSource = self;
    tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    tableView.headerView = nil;
    tableView.usesAlternatingRowBackgroundColors = NO;
    tableView.rowSizeStyle = NSTableViewRowSizeStyleCustom;
    tableView.backgroundColor = [NSColor colorWithWhite:5/255.0 alpha:0.5];
    tableView.rowHeight = 25;
    scrollView.contentView.documentView = tableView;
    return scrollView;
}

- (UITableView *)tableView
{
    return self.view.contentView.documentView;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return [self.hudDataArray count];
}

- (nullable NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(nullable NSTableColumn *)tableColumn row:(NSInteger)row
{
    return nil;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row
{
    FSHudRowView *rowView = [tableView makeViewWithIdentifier:@"Row" owner:self];
    if (rowView == nil) {
        rowView = [[FSHudRowView alloc]init];
        rowView.identifier = @"Row";
    }
    if (row < [self.hudDataArray count]) {
        HudViewCellData *data = [self.hudDataArray objectAtIndex:row];
        [rowView updateTitle:data.key];
        [rowView updateDetail:data.value];
    }
    
    return rowView;
}

#else
- (UITableView *)tableView
{
    return self.view;
}

- (UITableView *)prepareContentView
{
    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, 200, 300) style:UITableViewStylePlain];
    if (@available(tvOS 13.0, iOS 13.0, *)) {
        tableView.automaticallyAdjustsScrollIndicatorInsets = NO;
    }
    tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    tableView.contentInset = UIEdgeInsetsZero;
    tableView.scrollIndicatorInsets = tableView.contentInset;
    tableView.layoutMargins = UIEdgeInsetsMake(10, 0, 10, 0);
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.preservesSuperviewLayoutMargins = NO;
    tableView.cellLayoutMarginsFollowReadableWidth = NO;
    tableView.insetsContentViewsToSafeArea = NO;
    tableView.insetsLayoutMarginsFromSafeArea = NO;
    tableView.backgroundColor = [[UIColor alloc] initWithRed:.5f green:.5f blue:.5f alpha:.7f];
    
#if TARGET_OS_IOS
    tableView.separatorStyle  = UITableViewCellSeparatorStyleNone;
#elif TARGET_OS_TV
    tableView.allowsSelection = NO;
#endif
    return tableView;
}

#pragma mark UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    assert(section == 0);
    return _hudDataArray.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    assert(indexPath.section == 0);

    FSSDLHudViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"hud"];
    if (cell == nil) {
        cell = [[FSSDLHudViewCell alloc] init];
    }

    HudViewCellData *data = [_hudDataArray objectAtIndex:indexPath.item];

    [cell setHudValue:data.value forKey:data.key];

    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
#if TARGET_OS_IOS
    return 16.f;
#elif TARGET_OS_TV
    return 36.f;
#endif
}

#endif

@end
