//
//  MRInputURLViewController.m
//  FSPlayerMacDemo
//
//  Created by Reach Matt on 2025/4/15.
//  Copyright © 2025 FSPlayer. All rights reserved.
//

#import "MRInputURLViewController.h"
#import <Carbon/Carbon.h>
#import "MRGlobalNotification.h"

@interface MRInputURLViewController ()<NSTextFieldDelegate>

@property (weak) IBOutlet NSTextField *inputTextFiled;

@end

@implementation MRInputURLViewController

- (void)dealloc
{
    
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.inputTextFiled.focusRingType = NSFocusRingTypeNone;
    NSTextView * textView = (NSTextView *)[self.inputTextFiled currentEditor];
    [textView setInsertionPointColor:[NSColor colorWithWhite:1 alpha:0.45]];
    
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    if ([[pasteboard types] containsObject:NSPasteboardTypeString]) {
        NSString *str = [pasteboard stringForType:NSPasteboardTypeString];
        self.inputTextFiled.stringValue = str;
    }
}

- (void)viewWillAppear
{
    [super viewWillAppear];
    if (self.presentingViewController) {
        //10.11上不透明，代码再设置下！
        [self.view.window setTitlebarAppearsTransparent:YES];
        [self.view.window setMovableByWindowBackground:YES];
        self.view.window.styleMask &= ~NSWindowStyleMaskResizable;
        self.view.window.styleMask |= NSWindowStyleMaskFullSizeContentView;
        self.view.window.title = @"";
        
        //隐藏最大化、最小化按钮
        [[self.view.window standardWindowButton:NSWindowZoomButton] setHidden:YES];
        [[self.view.window standardWindowButton:NSWindowMiniaturizeButton]setHidden:YES];
        [[self.view.window standardWindowButton:NSWindowCloseButton] setHidden:YES];
        self.view.window.backgroundColor = [NSColor clearColor];
        //使系统自带 titlebar 变高
        NSToolbar *toolBar = [[NSToolbar alloc] initWithIdentifier:@"custom"];
        [toolBar setSizeMode:NSToolbarSizeModeRegular];
        toolBar.showsBaselineSeparator = NO;
        toolBar.allowsUserCustomization = NO;
        self.view.window.toolbar = toolBar;
        
        //在父视图上居中
        CGRect mainRect = self.presentingViewController.view.window.frame;
        CGRect rect = self.view.window.frame;
        
        rect.origin.x = mainRect.origin.x + (mainRect.size.width - rect.size.width)/2;
        rect.origin.y = mainRect.origin.y + (mainRect.size.height - rect.size.height)/2;
        [self.view.window setFrame:rect display:YES];
    }
    
    [self.view.window makeFirstResponder:self.inputTextFiled];
}

- (void)cancelOperation:(id)sender
{
    self.inputTextFiled.delegate = nil;
    [self.presentingViewController dismissViewController:self];
}

- (void)insertNewline:(id)sender
{
    self.inputTextFiled.delegate = nil;
    [self playTheContent];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector
{
    if (@selector(cancelOperation:) == commandSelector) {
        [self cancelOperation:control];
        return YES;
    } else if (@selector(insertNewline:) == commandSelector) {
        [self insertNewline:control];
        return YES;
    }
    return NO;
}

- (void)playTheContent
{
    NSString *url = self.inputTextFiled.stringValue;
    if (url.length > 0) {
        [self.inputTextFiled.window makeFirstResponder:nil];
        
        NSMutableDictionary *dic = [NSMutableDictionary new];
        [dic setObject:@[url] forKey:@"links"];
        POST_NOTIFICATION(kPlayNetMovieNotificationName_G, self, dic);
        [self.presentingViewController dismissViewController:self];
    }
}

@end
