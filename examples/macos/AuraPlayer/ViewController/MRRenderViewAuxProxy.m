//
//  MRRenderViewAuxProxy.m
//  AuraPlayer
//
//  Created by debugly on 2023/4/6.
//  Copyright © 2023 FSPlayer Mac. All rights reserved.
//

#import "MRRenderViewAuxProxy.h"
#import <FSPlayer/FSVideoRenderView.h>

@interface MRRenderViewAuxProxy ()

@property (nonatomic, strong) NSMutableArray *renderViewArr;
@property (nonatomic, strong) NSLock *lock;

@end

@implementation MRRenderViewAuxProxy

- (void)dealloc
{
    
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        self.renderViewArr = [NSMutableArray array];
        self.lock = [[NSLock alloc] init];
    }
    return self;
}

- (void)addRenderView:(NSView<FSVideoRenderingProtocol> *)view
{
    if (view) {
        [self.lock lock];
        [self.renderViewArr addObject:view];
        [self.lock unlock];
    }
}

- (void)removeRenderView:(NSView<FSVideoRenderingProtocol> *)view
{
    if (view) {
        [self.lock lock];
        [self.renderViewArr removeObject:view];
        [self.lock unlock];
    }
}

- (BOOL)displayAttach:(FSOverlayAttach *)attach
{
    [self.lock lock];
    NSArray *renderViewArr = [self.renderViewArr copy];
    [self.lock unlock];
    [renderViewArr makeObjectsPerformSelector:_cmd withObject:attach];
    return YES;
}

- (NSString *)name
{
    return @"render-aux";
}

- (id)context 
{
    return nil;
}

@end
