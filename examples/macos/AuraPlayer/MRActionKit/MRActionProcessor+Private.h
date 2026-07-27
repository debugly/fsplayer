//
//  MRActionProcessor+Private.h
//  MRPlayer
//
//  Created by debugly on 2019/8/5.
//  Copyright © 2022 debugly. All rights reserved.
//

#import "MRActionProcessor.h"

@interface MRActionProcessor (Private)

- (MRActionHandler)handlerForPath:(NSString *)path;

@end
