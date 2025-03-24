//
//  MultiRenderSample.m
//  IJKMediaMacDemo
//
//  Created by Reach Matt on 2023/4/6.
//  Copyright © 2023 IJK Mac. All rights reserved.
//

#import "MultiRenderSample.h"
#import <IJKMediaPlayerKit/IJKMediaPlayerKit.h>
#import "MRRenderViewAuxProxy.h"

@interface MultiRenderSample ()

@property (nonatomic, strong) IJKFFMoviePlayerController *player;

@end

@implementation MultiRenderSample

- (void)dealloc
{
    [self.player stop];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do view setup here.
}

- (void)playURL:(NSURL *)url
{
    if (self.player) {
        [self.player stop];
        self.player = nil;
    }
    
    IJKFFOptions *options = [IJKFFOptions optionsByDefault];
    //视频帧处理不过来的时候丢弃一些帧达到同步的效果
    [options setPlayerOptionIntValue:1 forKey:@"framedrop"];
    [options setPlayerOptionIntValue:6      forKey:@"video-pictq-size"];
    //    [options setPlayerOptionIntValue:50000      forKey:@"min-frames"];
    [options setPlayerOptionIntValue:119     forKey:@"max-fps"];
    // Param for playback
    [options setPlayerOptionIntValue:0 forKey:@"infbuf"];
    [options setPlayerOptionIntValue:1 forKey:@"packet-buffering"];
    
    [options setPlayerOptionIntValue:1 forKey:@"videotoolbox_hwaccel"];
    
    
    UIView<IJKVideoRenderingProtocol> *render1 = [IJKInternalRenderView createGLRenderView];
    UIView<IJKVideoRenderingProtocol> *render2 = [IJKInternalRenderView createMetalRenderView];
    
    {
        CGRect rect = self.view.bounds;
        int width = (int)(CGRectGetWidth(rect) / 2);
        rect.size.width = width;
        render1.frame = rect;
        render1.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.view addSubview:render1 positioned:NSWindowBelow relativeTo:nil];
        [render1 setBackgroundColor:100 g:10 b:20];
    }
    
    {
        CGRect rect = self.view.bounds;
        int width = (int)(CGRectGetWidth(rect) / 2);
        rect.size.width = width;
        rect.origin.x = width;
        render2.frame = rect;
        render2.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.view addSubview:render2 positioned:NSWindowBelow relativeTo:nil];
        [render2 setBackgroundColor:20 g:100 b:20];
    }
    
    MRRenderViewAuxProxy *aux = [[MRRenderViewAuxProxy alloc] init];
    
    [aux addRenderView:render1];
    [aux addRenderView:render2];
    
    self.player = [[IJKFFMoviePlayerController alloc] initWithMoreContent:url withOptions:options withGLView:aux];
    
    aux.scalingMode = IJKMPMovieScalingModeAspectFill;
    self.player.shouldAutoplay = YES;
    [self.player prepareToPlay];
}

@end
