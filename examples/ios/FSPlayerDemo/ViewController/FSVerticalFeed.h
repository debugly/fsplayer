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

/// One entry in the feed. `roomId` is the identity used when swiping;
/// `streamUrl` is what FSPlayer plays.
@interface FSVerticalFeedItem : NSObject

@property(nonatomic, copy) NSString *roomId;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *anchor;
@property(nonatomic, strong, nullable) UIColor *tintColor;
@property(nonatomic, copy) NSString *streamUrl;

/// Optional cover image, blurred to make the swipe backdrop. When absent the
/// demo falls back to a generated gradient so the backdrop is never empty.
@property(nonatomic, copy, nullable) NSString *coverUrl;

+ (nullable FSVerticalFeedItem *)itemWithDictionary:(NSDictionary *)dict;

@end

/// A page of the feed plus the ids of the neighbours of `currentRoomId`.
///
/// The shape mirrors what a real live service returns: it answers "what is
/// before and after the room you are in", not "give me a list". That is what
/// lets the demo switch rooms on a swipe without fetching the whole feed.
@interface FSVerticalFeedPage : NSObject

@property(nonatomic, copy) NSString *currentRoomId;
@property(nonatomic, copy) NSArray<FSVerticalFeedItem *> *items;

/// The item after `currentRoomId`, or nil when the feed ends.
- (nullable FSVerticalFeedItem *)itemAfterRoomId:(NSString *)roomId;
- (nullable FSVerticalFeedItem *)itemBeforeRoomId:(NSString *)roomId;
- (nullable FSVerticalFeedItem *)itemForRoomId:(NSString *)roomId;

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
- (nullable FSVerticalFeedPage *)loadPageForRoomId:(NSString *)roomId
                                             error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END