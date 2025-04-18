//
//  MRActionProcessor.m
//  MRPlayer
//
//  Created by debugly on 2019/8/5.
//  Copyright © 2022 debugly. All rights reserved.
//

#import "MRActionProcessor.h"
#import "MRActionProcessorInternal.h"

@implementation MRActionProcessor

- (instancetype)initWithScheme:(NSString *)scheme
{
    self = [super init];
    if (self) {
        self.scheme = scheme;
    }
    return self;
}

- (void)registerHandler:(MRActionHandler)handler forPath:(NSString *)path
{
    NSParameterAssert(path);
    NSMutableDictionary *map = [NSMutableDictionary dictionaryWithCapacity:3];
    if (self.acitonHandlerMap) {
        [map addEntriesFromDictionary:self.acitonHandlerMap];
    }
    
    if (handler) {
        [map setObject:[handler copy] forKey:path];
    } else {
        [map removeObjectForKey:path];
    }
    
    self.acitonHandlerMap = [map copy];
}

@end
