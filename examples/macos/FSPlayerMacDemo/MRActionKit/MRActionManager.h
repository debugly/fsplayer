//
//  MRActionManager.h
//  MRPlayer
//
//  Created by debugly on 2019/8/2.
//  Copyright © 2022 debugly. All rights reserved.
//

#import <Foundation/Foundation.h>

@class MRActionProcessor,MRActionItem;
@interface MRActionManager : NSObject

+ (BOOL)handleActionWithURL:(NSString *)url error:(NSError **)error;
+ (BOOL)handleActionWithItem:(MRActionItem *)item error:(NSError *__autoreleasing *)error;
+ (void)registerProcessor:(MRActionProcessor *)processor;

@end
