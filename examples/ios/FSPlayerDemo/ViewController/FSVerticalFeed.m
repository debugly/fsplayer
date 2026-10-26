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

#import "FSVerticalFeed.h"

static NSString *const kFSVerticalFeedErrorDomain = @"FSVerticalFeed";

@implementation FSVerticalFeedItem

+ (instancetype)itemWithDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSString *url = [self stringIn:dict forKeys:@[@"streamUrl", @"url", @"playUrl"]];

    // A stream URL is required for playback.
    if (url.length == 0) {
        return nil;
    }

    FSVerticalFeedItem *item = [[FSVerticalFeedItem alloc] init];
    item.streamUrl = url;
    item.title = [self stringIn:dict forKeys:@[@"title"]];
    item.coverUrl = [self stringIn:dict forKeys:@[@"coverUrl", @"cover", @"pic"]];

    id tint = dict[@"tint"];
    if ([tint isKindOfClass:[NSString class]]) {
        unsigned int rgb = 0;
        if ([[NSScanner scannerWithString:tint] scanHexInt:&rgb]) {
            item.tintColor = [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                                             green:((rgb >> 8) & 0xFF) / 255.0
                                              blue:(rgb & 0xFF) / 255.0
                                             alpha:1.0];
        }
    }
    return item;
}

+ (NSString *)stringIn:(NSDictionary *)dict forKeys:(NSArray<NSString *> *)keys {
    for (NSString *key in keys) {
        id value = dict[key];
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            return value;
        }
        // Accept numeric metadata as strings as well.
        if ([value isKindOfClass:[NSNumber class]]) {
            return [value stringValue];
        }
    }
    return nil;
}

@end

@implementation FSVerticalFeedPage

- (FSVerticalFeedItem *)itemAfterItem:(FSVerticalFeedItem *)item {
    NSUInteger index = [self.items indexOfObjectIdenticalTo:item];
    if (index == NSNotFound || index + 1 >= self.items.count) {
        return nil;
    }
    return self.items[index + 1];
}

- (FSVerticalFeedItem *)itemBeforeItem:(FSVerticalFeedItem *)item {
    NSUInteger index = [self.items indexOfObjectIdenticalTo:item];
    if (index == NSNotFound || index == 0) {
        return nil;
    }
    return self.items[index - 1];
}

+ (instancetype)pageWithData:(NSData *)data error:(NSError **)error {
    if (data.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:kFSVerticalFeedErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"feed data is empty"}];
        }
        return nil;
    }

    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![root isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:kFSVerticalFeedErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"unexpected feed root: %@",
                                                     jsonError ?: @"not an object"]}];
        }
        return nil;
    }

    NSArray *rawItems = root[@"items"];
    if (![rawItems isKindOfClass:[NSArray class]]) {
        if (error) {
            *error = [NSError errorWithDomain:kFSVerticalFeedErrorDomain
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"feed has no \"items\" array"}];
        }
        return nil;
    }

    NSMutableArray<FSVerticalFeedItem *> *items = [NSMutableArray arrayWithCapacity:rawItems.count];
    for (id raw in rawItems) {
        FSVerticalFeedItem *item = [FSVerticalFeedItem itemWithDictionary:raw];
        if (item) {
            [items addObject:item];
        }
    }

    if (items.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:kFSVerticalFeedErrorDomain
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"every feed entry lacked a streamUrl"}];
        }
        return nil;
    }

    FSVerticalFeedPage *page = [[self alloc] init];
    page.items = items;
    return page;
}

@end

@implementation FSVerticalFeedStore

+ (instancetype)sharedStore {
    static FSVerticalFeedStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[FSVerticalFeedStore alloc] init];
    });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _resourceName = @"vertical_feed";
    }
    return self;
}

- (FSVerticalFeedPage *)loadPageWithError:(NSError **)error {
    NSData *data = nil;

    if (self.remoteURLString.length > 0) {
        NSURL *url = [NSURL URLWithString:self.remoteURLString];
        data = [NSData dataWithContentsOfURL:url options:0 error:error];
    } else {
        NSURL *resource = [[NSBundle mainBundle] URLForResource:self.resourceName
                                                  withExtension:@"json"];
        if (!resource) {
            if (error) {
                *error = [NSError errorWithDomain:kFSVerticalFeedErrorDomain
                                             code:5
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                        [NSString stringWithFormat:
                                                         @"%@.json is not in the app bundle",
                                                         self.resourceName]}];
            }
            return nil;
        }
        data = [NSData dataWithContentsOfURL:resource options:0 error:error];
    }

    return [FSVerticalFeedPage pageWithData:data error:error];
}

@end
