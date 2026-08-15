//
//  MRM3UParser.h
//  AuraPlayer
//
//  Created by Reasonix on 2025.
//  Copyright © 2025 FSPlayer Mac. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Parses M3U / M3U8 playlist files into structured media items.
/// Supports both local file paths and remote HTTP(S) URLs.
@interface MRM3UParser : NSObject

/// Synchronously parse raw M3U content text into an array of item dictionaries.
/// Each dictionary contains: url (NSString), title (NSString),
///   logo (NSString, optional), group (NSString, optional).
/// @param content  The raw M3U file content as a UTF-8 string.
/// @return Array of NSDictionary objects, one per playlist entry.
+ (NSArray<NSDictionary *> *)parseM3UContent:(NSString *)content;

/// Asynchronously download and parse an M3U playlist from a local file path
/// or a remote HTTP(S) URL.
/// @param urlString  Local file path (e.g. "/path/to/playlist.m3u") or remote URL.
/// @param completion Called on the main thread with parsed items and optional error.
+ (void)parseM3UURL:(NSString *)urlString
         completion:(void (^)(NSArray<NSDictionary *> * _Nullable items, NSError * _Nullable error))completion;

/// Check whether a URL string refers to an M3U playlist (by extension).
+ (BOOL)isM3UURL:(NSString *)urlString;

@end

NS_ASSUME_NONNULL_END
