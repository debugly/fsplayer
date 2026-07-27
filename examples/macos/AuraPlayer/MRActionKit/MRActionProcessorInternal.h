//
//  MRActionProcessorInternal.h
//  MRPlayer
//
//  Created by debugly on 2019/8/5.
//  Copyright © 2022 debugly. All rights reserved.
//

#import "MRActionProcessor.h"

@interface MRActionProcessor ()

@property (nonatomic, strong) NSDictionary *acitonHandlerMap;
@property (nonatomic, copy, readwrite) NSString *scheme;

@end
