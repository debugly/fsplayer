//
//  MRPlayerSettingsViewController.h
//  AuraPlayer
//
//  Created by debugly on 2024/1/24.
//  Copyright © 2024 FSPlayer Mac. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef void(^MRPlayerSettingsExchangeStreamBlock)(int);
typedef void(^MRPlayerSettingsCloseStreamBlock)(NSString *);

@interface MRPlayerSettingsViewController : NSViewController

@property (nonatomic, assign) int deinterlace;
@property (nonatomic, copy, nullable) void (^onDeinterlaceChanged)(int mode);
@property (nonatomic, copy, nullable) void (^onMultiRendererToggled)(BOOL enabled);
@property (nonatomic, copy, nullable) void (^onHorizontalFlipChanged)(float degrees);
@property (nonatomic, copy, nullable) void (^onVerticalFlipChanged)(float degrees);

- (void)exchangeToNextSubtitle;
- (void)updateTracks:(NSDictionary *)dic;
- (void)onCloseCurrentStream:(MRPlayerSettingsCloseStreamBlock)block;
- (void)onExchangeSelectedStream:(MRPlayerSettingsExchangeStreamBlock)block;
- (void)onCaptureShot:(dispatch_block_t)block;

@end

NS_ASSUME_NONNULL_END
