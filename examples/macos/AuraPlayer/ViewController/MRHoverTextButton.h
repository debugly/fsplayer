//
//  MRHoverTextButton.h
//  AuraPlayer
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface MRHoverTextButton : NSButton

@property (nonatomic, strong) NSColor *normalColor;
@property (nonatomic, strong) NSColor *hoverColor;

@end

NS_ASSUME_NONNULL_END
