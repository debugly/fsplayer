//
//  MRPlaylistViewController.h
//  AuraPlayer
//
//  Created by debugly on 2024/1/24.
//  Copyright © 2024 FSPlayer Mac. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface MRPlaylistViewController : NSViewController

@property (nonatomic, copy, readonly) NSArray<NSString *> *playlistItems;
@property (nonatomic, copy, readonly, nullable) NSString *currentlyPlayingUrl;

@property (nonatomic, copy, nullable) void (^onSelectPlayItem)(NSString *url, NSInteger index);
@property (nonatomic, copy, nullable) void (^onRemovePlayItem)(NSInteger index);
@property (nonatomic, copy, nullable) void (^onClearPlaylist)(void);
@property (nonatomic, copy, nullable) void (^onAddFilesRequested)(void);
@property (nonatomic, copy, nullable) void (^onFilesDropped)(NSArray<NSURL *> *fileUrls);

- (void)updatePlaylist:(NSArray<NSString *> *)playlist currentlyPlaying:(nullable NSString *)playingUrl;

@end

NS_ASSUME_NONNULL_END
