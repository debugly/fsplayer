/*
 * FSOptions.m
 *
 * Copyright (c) 2013-2015 Bilibili
 * Copyright (c) 2013-2015 Zhang Rui <bbcallen@gmail.com>
 * Copyright (c) 2019 debugly <qianlongxu@gmail.com>
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

#import "FSOptions.h"
#include "ijkplayer/apple/ijkplayer_ios.h"

@implementation FSOptions {
    NSMutableDictionary *_optionCategories;
    NSMutableDictionary *_playerOptions;
    NSMutableDictionary *_formatOptions;
    NSMutableDictionary *_codecOptions;
    NSMutableDictionary *_swsOptions;
    NSMutableDictionary *_swrOptions;
}

+ (FSOptions *)optionsByDefault
{
    FSOptions *options = [[FSOptions alloc] init];

    [options setPlayerOptionIntValue:30     forKey:@"max-fps"];
    [options setPlayerOptionIntValue:0      forKey:@"framedrop"];
    [options setPlayerOptionIntValue:3      forKey:@"video-pictq-size"];
    
    [options setFormatOptionIntValue:0                  forKey:@"auto_convert"];
    [options setFormatOptionIntValue:1                  forKey:@"reconnect"];
    [options setFormatOptionIntValue:30 * 1000 * 1000   forKey:@"timeout"];
    //the user-agent option is deprecated, please use user_agent option
    [options setFormatOptionValue:@"ijkplayer"          forKey:@"user_agent"];

    options.showHudView   = NO;
    options.metalRenderer = YES;
    return options;
}

- (id)init
{
    self = [super init];
    if (self) {
        _playerOptions      = [[NSMutableDictionary alloc] init];
        _formatOptions      = [[NSMutableDictionary alloc] init];
        _codecOptions       = [[NSMutableDictionary alloc] init];
        _swsOptions         = [[NSMutableDictionary alloc] init];
        _swrOptions         = [[NSMutableDictionary alloc] init];

        _optionCategories   = [[NSMutableDictionary alloc] init];
        _optionCategories[@(FSMP_OPT_CATEGORY_PLAYER)] = _playerOptions;
        _optionCategories[@(FSMP_OPT_CATEGORY_FORMAT)] = _formatOptions;
        _optionCategories[@(FSMP_OPT_CATEGORY_CODEC)]  = _codecOptions;
        _optionCategories[@(FSMP_OPT_CATEGORY_SWS)]    = _swsOptions;
        _optionCategories[@(FSMP_OPT_CATEGORY_SWR)]    = _swrOptions;
    }
    return self;
}

- (void)applyTo:(IjkMediaPlayer *)mediaPlayer
{
    [_optionCategories enumerateKeysAndObjectsUsingBlock:^(id categoryKey, id categoryDict, BOOL *stopOuter) {
        [categoryDict enumerateKeysAndObjectsUsingBlock:^(id optKey, id optValue, BOOL *stop) {
            if ([optValue isKindOfClass:[NSNumber class]]) {
                ijkmp_set_option_int(mediaPlayer,
                                     (int)[categoryKey integerValue],
                                     [optKey UTF8String],
                                     [optValue longLongValue]);
            } else if ([optValue isKindOfClass:[NSString class]]) {
                ijkmp_set_option(mediaPlayer,
                                 (int)[categoryKey integerValue],
                                 [optKey UTF8String],
                                 [optValue UTF8String]);
            }
        }];
    }];
}

- (void)setOptionValue:(NSString *)value
                forKey:(NSString *)key
            ofCategory:(FSOptionCategory)category
{
    if (!key)
        return;

    NSMutableDictionary *options = [_optionCategories objectForKey:@(category)];
    if (options) {
        if (value) {
            [options setObject:value forKey:key];
        } else {
            [options removeObjectForKey:key];
        }
    }
}

- (void)setOptionIntValue:(int64_t)value
                   forKey:(NSString *)key
               ofCategory:(FSOptionCategory)category
{
    if (!key)
        return;

    NSMutableDictionary *options = [_optionCategories objectForKey:@(category)];
    if (options) {
        [options setObject:@(value) forKey:key];
    }
}


#pragma mark Common Helper

-(void)setFormatOptionValue:(NSString *)value forKey:(NSString *)key
{
    [self setOptionValue:value forKey:key ofCategory:kIJKFFOptionCategoryFormat];
}

-(void)setCodecOptionValue:(NSString *)value forKey:(NSString *)key
{
    [self setOptionValue:value forKey:key ofCategory:kIJKFFOptionCategoryCodec];
}

-(void)setSwsOptionValue:(NSString *)value forKey:(NSString *)key
{
    [self setOptionValue:value forKey:key ofCategory:kIJKFFOptionCategorySws];
}

-(void)setPlayerOptionValue:(NSString *)value forKey:(NSString *)key
{
    [self setOptionValue:value forKey:key ofCategory:kIJKFFOptionCategoryPlayer];
}

-(void)setFormatOptionIntValue:(int64_t)value forKey:(NSString *)key
{
    [self setOptionIntValue:value forKey:key ofCategory:kIJKFFOptionCategoryFormat];
}

-(void)setCodecOptionIntValue:(int64_t)value forKey:(NSString *)key
{
    [self setOptionIntValue:value forKey:key ofCategory:kIJKFFOptionCategoryCodec];
}

-(void)setSwsOptionIntValue:(int64_t)value forKey:(NSString *)key
{
    [self setOptionIntValue:value forKey:key ofCategory:kIJKFFOptionCategorySws];
}

-(void)setPlayerOptionIntValue:(int64_t)value forKey:(NSString *)key
{
    [self setOptionIntValue:value forKey:key ofCategory:kIJKFFOptionCategoryPlayer];
}

@end
