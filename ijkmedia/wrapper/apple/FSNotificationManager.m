/*
 * FSNotificationManager.m
 *
 * Copyright (c) 2016 Bilibili
 * Copyright (c) 2016 Zhang Rui <bbcallen@gmail.com>
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
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#import "FSNotificationManager.h"

@implementation FSNotificationManager
{
    NSMutableDictionary *_registeredNotifications;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _registeredNotifications = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)addObserver:(id)observer
           selector:(SEL)aSelector
               name:(NSString *)aName
             object:(id)anObject
{
    [[NSNotificationCenter defaultCenter] addObserver:observer
                                             selector:aSelector
                                                 name:aName
                                               object:anObject];

    [_registeredNotifications setValue:aName forKey:aName];
}

- (void)removeAllObservers:(nonnull id)observer
{
    for (NSString *name in [_registeredNotifications allKeys]) {
        [[NSNotificationCenter defaultCenter] removeObserver:observer
                                                        name:name
                                                      object:nil];
    }
}

@end
