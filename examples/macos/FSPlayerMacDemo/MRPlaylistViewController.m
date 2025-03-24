//
//  MRPlaylistViewController.m
//  IJKMediaMacDemo
//
//  Created by Reach Matt on 2024/1/24.
//  Copyright © 2024 IJK Mac. All rights reserved.
//

#import "MRPlaylistViewController.h"
#import "MRPlaylistRowView.h"

@interface MRPlaylistViewController ()<NSTableViewDelegate, NSTableViewDataSource>

@property (nonatomic, strong) NSMutableArray *hudDataArray;

@end

@implementation MRPlaylistViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do view setup here.
}

- (NSMutableArray *)hudDataArray
{
    if (!_hudDataArray) {
        _hudDataArray = [NSMutableArray array];
    }
    return _hudDataArray;
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
    MRPlaylistRowView *rowView = [tableView makeViewWithIdentifier:@"Row" owner:self];
    if (rowView == nil) {
        rowView = [[MRPlaylistRowView alloc]init];
        rowView.identifier = @"Row";
    }
    if (row < [self.hudDataArray count]) {
        MRPlaylistRowData *data = [self.hudDataArray objectAtIndex:row];
        [rowView updateData:data];
    }
    
    return rowView;
}
@end
