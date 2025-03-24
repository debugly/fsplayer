//
//  MRPlayerSettingsViewController.h
//  IJKMediaMacDemo
//
//  Created by Reach Matt on 2024/1/24.
//  Copyright © 2024 IJK Mac. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef void(^MRPlayerSettingsExchangeStreamBlock)(int);
typedef void(^MRPlayerSettingsCloseStreamBlock)(NSString *);

@interface MRPlayerSettingsViewController : NSViewController

- (void)exchangeToNextSubtitle;
- (void)updateTracks:(NSDictionary *)dic;
- (void)onCloseCurrentStream:(MRPlayerSettingsCloseStreamBlock)block;
- (void)onExchangeSelectedStream:(MRPlayerSettingsExchangeStreamBlock)block;
- (void)onCaptureShot:(dispatch_block_t)block;

@end

NS_ASSUME_NONNULL_END
