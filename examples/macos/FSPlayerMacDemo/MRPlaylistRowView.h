//
//  MRPlaylistRowView.h
//  IJKMediaMacDemo
//
//  Created by Reach Matt on 2024/1/24.
//  Copyright © 2024 IJK Mac. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef enum : NSUInteger {
    KSeparactorStyleFull,
    KSeparactorStyleHeadPadding,
    KSeparactorStyleNone,
} KSeparactorStyle;

@interface MRPlaylistRowData : NSObject

@property(nonatomic) NSString *key;
@property(nonatomic) NSString *value;

@end

@interface MRPlaylistRowView : NSTableRowView <NSUserInterfaceItemIdentification>

@property KSeparactorStyle sepStyle;

- (void)updateData:(MRPlaylistRowData *)data;

@end

NS_ASSUME_NONNULL_END
