/*
 * Copyright (c) 2019 debugly <qianlongxu@gmail.com>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One entry in the feed. `streamUrl` is what FSPlayer plays.
@interface FSVerticalFeedItem : NSObject

@property(nonatomic, copy) NSString *title;
@property(nonatomic, strong, nullable) UIColor *tintColor;
@property(nonatomic, copy) NSString *streamUrl;

/// Optional cover image, blurred to make the swipe backdrop. When absent the
/// demo falls back to a generated gradient so the backdrop is never empty.
@property(nonatomic, copy, nullable) NSString *coverUrl;

+ (nullable FSVerticalFeedItem *)itemWithDictionary:(NSDictionary *)dict;

@end

/// An ordered page of feed entries. Playback starts at the first entry.
@interface FSVerticalFeedPage : NSObject

@property(nonatomic, copy) NSArray<FSVerticalFeedItem *> *items;

/// Adjacent entries, or nil at the beginning/end of the feed.
- (nullable FSVerticalFeedItem *)itemAfterItem:(FSVerticalFeedItem *)item;
- (nullable FSVerticalFeedItem *)itemBeforeItem:(FSVerticalFeedItem *)item;

+ (nullable FSVerticalFeedPage *)pageWithData:(NSData *)data
                                       error:(NSError **)error;

@end

/// Serves the feed. Backed by a bundled JSON file so the demo runs offline;
/// swap the file, or point it at a URL, to change the feed without touching
/// the view code.
@interface FSVerticalFeedStore : NSObject

/// Bundle resource name, default `vertical_feed`.
@property(nonatomic, copy) NSString *resourceName;

/// When set, the store fetches this instead of reading the bundled file.
@property(nonatomic, copy, nullable) NSString *remoteURLString;

+ (instancetype)sharedStore;

/// Blocking; call off the main thread. Returns nil and fills `error` on
/// failure.
- (nullable FSVerticalFeedPage *)loadPageWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
