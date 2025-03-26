//
//  ViewController.m
//  FSPlayerTVDemo
//
//  Created by debugly on 2024/5/23.
//

#import "ViewController.h"
#import <FSPlayer/FSPlayerKit.h>

#define kURL @"http://devimages.apple.com.edgekey.net/streaming/examples/bipbop_16x9/gear5/prog_index.m3u8"

@interface ViewController ()

@property(atomic, retain) id<FSMediaPlayback> player;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    
#ifdef DEBUG
    [FSPlayer setLogLevel:FS_LOG_DEBUG];
#else
    [FSPlayer setLogLevel:FS_LOG_WARN];
#endif
    
    [FSPlayer checkIfFFmpegVersionMatch:YES];
    // [FSPlayer checkIfPlayerVersionMatch:YES major:1 minor:0 micro:0];

    FSOptions *options = [FSOptions optionsByDefault];
    
    BOOL isVideoToolBox = YES;
    if (isVideoToolBox) {
        [options setPlayerOptionIntValue:3840    forKey:@"videotoolbox-max-frame-width"];
    } else {
        [options setPlayerOptionValue:@"fcc-i420" forKey:@"overlay-format"];
        [options setPlayerOptionValue:@"fcc-j420" forKey:@"overlay-format"];
        [options setPlayerOptionValue:@"fcc-yv12" forKey:@"overlay-format"];
        [options setPlayerOptionValue:@"fcc-nv12" forKey:@"overlay-format"];
        [options setPlayerOptionValue:@"fcc-bgra" forKey:@"overlay-format"];
        [options setPlayerOptionValue:@"fcc-bgr0" forKey:@"overlay-format"];
        [options setPlayerOptionValue:@"fcc-_es2" forKey:@"overlay-format"];
    }
    //开启硬解
    [options setPlayerOptionIntValue:isVideoToolBox forKey:@"videotoolbox_hwaccel"];

    options.metalRenderer = YES;
    self.player = [[FSPlayer alloc] initWithContentURL:[NSURL URLWithString:kURL] withOptions:options];
    self.player.view.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.player.view.frame = self.view.bounds;
//    self.player.view.frame = CGRectMake(0, 0, 414, 232);
    self.player.scalingMode = FSScalingModeAspectFit;
    self.player.shouldAutoplay = YES;
    
    FSSDLSubtitlePreference p = self.player.subtitlePreference;
    p.PrimaryColour = 16776960;
    self.player.subtitlePreference = p;
    self.view.autoresizesSubviews = YES;
    [self.view addSubview:self.player.view];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.player prepareToPlay];
}

- (void)viewDidDisappear:(BOOL)animated 
{
    [super viewDidDisappear:animated];
    [self.player shutdown];
}

@end
