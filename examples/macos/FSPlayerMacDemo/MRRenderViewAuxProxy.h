//
//  MRRenderViewAuxProxy.h
//  IJKMediaMacDemo
//
//  Created by Reach Matt on 2023/4/6.
//  Copyright © 2023 IJK Mac. All rights reserved.
//

#import <IJKMediaPlayerKit/IJKVideoRenderingProtocol.h>

NS_ASSUME_NONNULL_BEGIN

@interface MRRenderViewAuxProxy : NSView <IJKVideoRenderingProtocol>

- (void)addRenderView:(NSView<IJKVideoRenderingProtocol> *)view;
- (void)removeRenderView:(NSView<IJKVideoRenderingProtocol> *)view;

@end

NS_ASSUME_NONNULL_END
