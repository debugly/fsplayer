//
//  MRRenderViewAuxProxy.h
//  FSPlayerMediaMacDemo
//
//  Created by debugly on 2023/4/6.
//  Copyright © 2023 FSPlayer Mac. All rights reserved.
//

#import <FSPlayer/FSVideoRenderingProtocol.h>

NS_ASSUME_NONNULL_BEGIN

@interface MRRenderViewAuxProxy : NSView <FSVideoRenderingProtocol>

- (void)addRenderView:(NSView<FSVideoRenderingProtocol> *)view;
- (void)removeRenderView:(NSView<FSVideoRenderingProtocol> *)view;

@end

NS_ASSUME_NONNULL_END
