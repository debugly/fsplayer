//
//  MRTextInfoViewController.m
//  IJKMediaMacDemo
//
//  Created by Reach Matt on 2023/5/25.
//  Copyright © 2023 IJK Mac. All rights reserved.
//

#import "MRTextInfoViewController.h"

@interface MRTextInfoViewController ()

@property (unsafe_unretained) IBOutlet NSTextView *textView;
@property (nonatomic, copy) NSString *text;

@end

@implementation MRTextInfoViewController

- (instancetype)initWithText:(NSString *)text
{
    self = [super initWithNibName:@"MRTextInfoViewController" bundle:nil];
    if (self) {
        self.text = text;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do view setup here.
    [self.view setWantsLayer:YES];
    self.view.layer.backgroundColor = [[NSColor whiteColor] CGColor];
}

- (void)viewWillAppear
{
    [super viewWillAppear];
    if (self.presentingViewController) {
        //使系统自带 titlebar 变高
        NSToolbar *toolBar = [[NSToolbar alloc] initWithIdentifier:@"custom"];
                [toolBar setSizeMode:NSToolbarSizeModeRegular];
                toolBar.showsBaselineSeparator = NO;
                toolBar.allowsUserCustomization = NO;
        self.view.window.toolbar = toolBar;
        
        //10.11上不透明，代码再设置下！
        [self.view.window setTitlebarAppearsTransparent:NO];
        [self.view.window setMovableByWindowBackground:YES];
        
        self.view.window.styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskBorderless | NSWindowStyleMaskClosable;
//        self.view.window.titleVisibility = NSWindowTitleHidden;
        
        //隐藏最大化、最小化按钮
        [[self.view.window standardWindowButton:NSWindowZoomButton] setHidden:YES];
        [[self.view.window standardWindowButton:NSWindowMiniaturizeButton]setHidden:YES];
        [self.view.window center];
//        self.view.window.backgroundColor = [NSColor redColor];
    }
    [self updateText:self.text];
}

- (void)updateText:(NSString *)text
{
    self.text = text;
    self.textView.string = text;
}

@end
