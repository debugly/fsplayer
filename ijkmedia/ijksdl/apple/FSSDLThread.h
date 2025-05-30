/*
 * FSSDLThread.h
 *
 * Copyright (c) 2013-2014 Bilibili
 * Copyright (c) 2013-2014 Zhang Rui <bbcallen@gmail.com>
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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FSSDLThread : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong, readonly) NSThread *thread;

- (instancetype)initWithName:(NSString *)name;

- (void)performSelector:(SEL)aSelector
             withTarget:(nullable id)target
             withObject:(nullable id)arg
          waitUntilDone:(BOOL)wait;

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
