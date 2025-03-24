//
//  MRPlayerSettingsView.h
//  IJKMediaMacDemo
//
//  Created by Reach Matt on 2024/5/16.
//  Copyright © 2024 IJK Mac. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface MRPlayerSettingsView : NSView

- (void)exchangeToNextSubtitle;

- (void)addAudioItemWithTitle:(NSString *)title;
- (void)addVideoItemWithTitle:(NSString *)title;
- (void)addSubtitleItemWithTitle:(NSString *)title;

- (void)removeAllAudioItems;
- (void)removeAllVideoItems;
- (void)removeAllSubtileItems;
- (void)removeAllItems;

- (void)selectAudioItemWithTitle:(NSString *)title;
- (void)selectVideoItemWithTitle:(NSString *)title;
- (void)selectSubtitleItemWithTitle:(NSString *)title;

@end

NS_ASSUME_NONNULL_END
