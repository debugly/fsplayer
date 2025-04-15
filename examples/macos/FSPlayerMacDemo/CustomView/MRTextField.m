//
//  MRTextField.m
//  FSPlayerMacDemo
//
//  Created by Reach Matt on 2025/4/15.
//  Copyright © 2025 FSPlayer. All rights reserved.
//

#import "MRTextField.h"

@implementation MRTextField

- (BOOL)becomeFirstResponder
{
    BOOL success = [super becomeFirstResponder];
    if (success) {
        NSTextView * textView = (NSTextView *)[self currentEditor];
        //光标放到末尾
        [textView moveToEndOfLine:nil];
    }
    return success;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    // The command key is the ONLY modifier key being pressed.
    if (([event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask) == NSEventModifierFlagCommand) {
        SEL action = NULL;
        NSString *character = [event charactersIgnoringModifiers];
        if ([character isEqualToString:@"x"]) {
            action = @selector(cut:);
        } else if ([character isEqualToString:@"c"]) {
            action = @selector(copy:);
        } else if ([character isEqualToString:@"v"]) {
            action = @selector(paste:);
        } else if ([character isEqualToString:@"a"]) {
            action = @selector(selectAll:);
        }
        id target = [[self window] firstResponder];
        if ([target respondsToSelector:action]) {
            return [NSApp sendAction:action to:target from:self];
        }
    }

    return [super performKeyEquivalent:event];
}
@end
