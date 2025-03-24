//
//  MRTextInfoViewController.h
//  IJKMediaMacDemo
//
//  Created by Reach Matt on 2023/5/25.
//  Copyright © 2023 IJK Mac. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface MRTextInfoViewController : NSViewController

- (instancetype)initWithText:(NSString *)text;
- (void)updateText:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
