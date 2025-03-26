/*
 * FSSDLThread.m
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
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#import "FSSDLThread.h"

@interface FSSDLThread ()

@property (nonatomic, strong) NSThread *thread;
@property (atomic, assign) BOOL shouldStop;

@end

@implementation FSSDLThread

- (void)dealloc
{
    
}

- (instancetype)initWithName:(NSString *)name
{
    self = [super init];
    if (self) {
        self.name = name;
    }
    return self;
}

- (void)start
{
    if (!_thread) {
        _shouldStop = NO;
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(main) object:nil];
        if (self.name) {
            [_thread setName:self.name];
        } else {
            [_thread setName:[NSString stringWithFormat:@"%@",NSStringFromClass([self class])]];
        }
        [_thread start];
    }
}

- (void)main
{
    [[NSRunLoop currentRunLoop] addPort:[[NSPort alloc] init] forMode:NSDefaultRunLoopMode];

    while (!self.shouldStop) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
    }
    
    CFRunLoopStop(CFRunLoopGetCurrent());
}

- (void)_stop
{
    self.shouldStop = YES;
}

- (void)stop
{
    //fix crash target thread exited while waiting for the perform
    [self performSelector:@selector(_stop) onThread:_thread withObject:nil waitUntilDone:YES];
}

- (void)performSelector:(SEL)aSelector
             withTarget:(nullable id)target
             withObject:(nullable id)arg
          waitUntilDone:(BOOL)wait
{
    if (self.shouldStop) {
        return;
    }
    [target performSelector:aSelector
                   onThread:_thread
                 withObject:arg
              waitUntilDone:wait];
}

@end
