//
//  MRBaseView.m
//  FSPlayerMacDemo
//
//  Created by debugly on 2022/2/25.
//  Copyright © 2022 FSPlayer Mac. All rights reserved.
//

#import "MRBaseView.h"

@implementation MRBaseView

IB_DESIGNABLE;

- (void)setCornerRadius:(CGFloat)radius
{
    if (_cornerRadius != radius) {
        _cornerRadius = radius;
        if (_cornerRadius > 0) {
            [self setWantsLayer:YES];
            self.layer.cornerRadius = radius;
            self.layer.masksToBounds = YES;
        }
    }
}

@end
