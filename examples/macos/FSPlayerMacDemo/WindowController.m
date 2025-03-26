//
//  WindowController.m
//  FSPlayerDemo
//
//  Created by debugly on 2021/11/2.
//  Copyright © 2021 debugly. All rights reserved.
//

#import "WindowController.h"

@interface WindowController ()

@end

@implementation WindowController

- (void)keyDown:(NSEvent *)event
{
    if (self.window.contentViewController) {
        if ([self.window.contentViewController respondsToSelector:@selector(keyDown:)]) {
            [self.window.contentViewController keyDown:event];
            return;
        }
    }
    return [super keyDown:event];
}

@end
