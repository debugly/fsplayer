//
//  MRMediaItem.m
//  AuraPlayer
//
//  Created by Reasonix on 2025.
//  Copyright © 2025 FSPlayer Mac. All rights reserved.
//

#import "MRMediaItem.h"

@implementation MRMediaItem

- (instancetype)initWithURL:(NSString *)url
                      title:(NSString *)title
                       logo:(nullable NSString *)logo
                      group:(nullable NSString *)group
{
    self = [super init];
    if (self) {
        _url = [url copy];
        _title = [title copy] ?: @"";
        _logo = [logo copy];
        _group = [group copy];
    }
    return self;
}

+ (instancetype)itemWithURL:(NSString *)url
{
    NSString *title = [url lastPathComponent] ?: url;
    return [[self alloc] initWithURL:url title:title logo:nil group:nil];
}

+ (NSArray<NSString *> *)urlsFromItems:(NSArray<MRMediaItem *> *)items
{
    NSMutableArray *urls = [NSMutableArray arrayWithCapacity:items.count];
    for (MRMediaItem *item in items) {
        [urls addObject:item.url];
    }
    return [urls copy];
}

+ (NSDictionary<NSString *, NSDictionary *> *)metadataMapFromItems:(NSArray<MRMediaItem *> *)items
{
    NSMutableDictionary *map = [NSMutableDictionary dictionaryWithCapacity:items.count];
    for (MRMediaItem *item in items) {
        NSMutableDictionary *meta = [NSMutableDictionary dictionaryWithCapacity:3];
        meta[@"title"] = item.title ?: @"";
        if (item.logo) meta[@"logo"] = item.logo;
        if (item.group) meta[@"group"] = item.group;
        map[item.url] = [meta copy];
    }
    return [map copy];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<MRMediaItem: %@ — \"%@\"%@%@>",
            _url, _title,
            _group ? [NSString stringWithFormat:@" [%@]", _group] : @"",
            _logo ? @" 📷" : @""];
}

@end
