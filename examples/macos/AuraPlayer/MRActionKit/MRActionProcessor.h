//
//  MRActionProcessor.h
//  MRPlayer
//
//  Created by debugly on 2019/8/5.
//  Copyright © 2022 debugly. All rights reserved.
//

#import <Foundation/Foundation.h>

@class MRActionItem;

typedef void (^MRActionHandler)(MRActionItem *item);

@interface MRActionProcessor : NSObject

@property (nonatomic, copy, readonly) NSString *scheme;

- (instancetype)initWithScheme:(NSString *)scheme;

- (void)registerHandler:(MRActionHandler)handler forPath:(NSString *)path;

@end
