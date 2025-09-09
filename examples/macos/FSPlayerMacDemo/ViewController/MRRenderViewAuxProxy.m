//
//  MRRenderViewAuxProxy.m
//  FSPlayerMacDemo
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

@synthesize colorPreference = _colorPreference;

@synthesize darPreference = _darPreference;

@synthesize preventDisplay = _preventDisplay;

@synthesize rotatePreference = _rotatePreference;

@synthesize scalingMode = _scalingMode;

@synthesize showHdrAnimation = _showHdrAnimation;

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

- (void)setNeedsRefreshCurrentPic
{
    [self.lock lock];
    NSArray *renderViewArr = [self.renderViewArr copy];
    [self.lock unlock];
    [renderViewArr makeObjectsPerformSelector:_cmd];
}

- (CGImageRef)snapshot:(FSSnapshotType)aType
{
    [self.lock lock];
    NSArray *renderViewArr = [self.renderViewArr copy];
    [self.lock unlock];
    NSView<FSVideoRenderingProtocol> *view = [renderViewArr firstObject];
    return [view snapshot:aType];
}

- (id)context 
{
    return nil;
}

- (void)setColorPreference:(FSColorConvertPreference)colorPreference
{
    _colorPreference = colorPreference;
    
    [self.lock lock];
    NSArray *renderViewArr = [self.renderViewArr copy];
    [self.lock unlock];
    
    for (NSView<FSVideoRenderingProtocol> *view in renderViewArr) {
        [view setColorPreference:colorPreference];
    }
}

- (void)setDarPreference:(FSDARPreference)darPreference
{
    _darPreference = darPreference;
    
    [self.lock lock];
    NSArray *renderViewArr = [self.renderViewArr copy];
    [self.lock unlock];
    
    for (NSView<FSVideoRenderingProtocol> *view in renderViewArr) {
        [view setDarPreference:darPreference];
    }
}

- (void)setPreventDisplay:(BOOL)preventDisplay
{
    _preventDisplay = preventDisplay;
    
    [self.lock lock];
    NSArray *renderViewArr = [self.renderViewArr copy];
    [self.lock unlock];
    
    for (NSView<FSVideoRenderingProtocol> *view in renderViewArr) {
        [view setPreventDisplay:preventDisplay];
    }
}

- (void)setRotatePreference:(FSRotatePreference)rotatePreference
{
    _rotatePreference = rotatePreference;
    
    [self.lock lock];
    NSArray *renderViewArr = [self.renderViewArr copy];
    [self.lock unlock];
    
    for (NSView<FSVideoRenderingProtocol> *view in renderViewArr) {
        [view setRotatePreference:rotatePreference];
    }
}

- (void)setScalingMode:(FSScalingMode)scalingMode
{
    _scalingMode = scalingMode;
    
    [self.lock lock];
    NSArray *renderViewArr = [self.renderViewArr copy];
    [self.lock unlock];
    
    for (NSView<FSVideoRenderingProtocol> *view in renderViewArr) {
        [view setScalingMode:scalingMode];
    }
}

@end
