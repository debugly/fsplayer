/*
 * FSPlayerDef.m
 *
 * Copyright (c) 2013 Bilibili
 * Copyright (c) 2013 Zhang Rui <bbcallen@gmail.com>
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

#import "FSPlayerDef.h"
#include "../ijkmedia/ijkplayer/ff_ffmsg_queue.h"

@implementation FSPlayerMessage
{
    @public
    AVMessage m_msg;
}

- (AVMessage *)msg
{
    return &m_msg;
}

@end

@implementation FSPlayerMessagePool{
    NSMutableArray *_array;
}

- (FSPlayerMessagePool *)init
{
    self = [super init];
    if (self) {
        _array = [[NSMutableArray alloc] init];
    }
    return self;
}

- (FSPlayerMessage *) obtain
{
    FSPlayerMessage *msg = nil;

    @synchronized(self) {
        NSUInteger count = [_array count];
        if (count > 0) {
            msg = [_array objectAtIndex:count - 1];
            [_array removeLastObject];
        }
    }

    if (!msg)
        msg = [[FSPlayerMessage alloc] init];

    return msg;
}

- (void) recycle:(FSPlayerMessage *)msg
{
    if (!msg)
        return;
    msg_free_res(msg.msg);
    @synchronized(self) {
        if ([_array count] <= 10)
            [_array addObject:msg];
    }
}

@end
