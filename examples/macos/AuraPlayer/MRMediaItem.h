//
//  MRMediaItem.h
//  AuraPlayer
//
//  Created by Reasonix on 2025.
//  Copyright © 2025 FSPlayer Mac. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Represents a single media item in the playlist, enriched with metadata
/// parsed from M3U playlists (channel name, logo, group).
@interface MRMediaItem : NSObject

@property (nonatomic, copy, readonly) NSString *url;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly, nullable) NSString *logo;
@property (nonatomic, copy, readonly, nullable) NSString *group;

- (instancetype)initWithURL:(NSString *)url
                      title:(NSString *)title
                       logo:(nullable NSString *)logo
                      group:(nullable NSString *)group;

/// Convenience: title = lastPathComponent (or url itself), no logo/group.
+ (instancetype)itemWithURL:(NSString *)url;

/// Convert an array of MRMediaItem to an array of url strings (for existing playlist code).
+ (NSArray<NSString *> *)urlsFromItems:(NSArray<MRMediaItem *> *)items;

/// Build a metadata dictionary mapping url → {title, logo, group} for playlist display.
+ (NSDictionary<NSString *, NSDictionary *> *)metadataMapFromItems:(NSArray<MRMediaItem *> *)items;

@end

NS_ASSUME_NONNULL_END
