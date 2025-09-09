//
//  MultiRenderSample.m
//  FSPlayerDemo
//
//  Created by debugly on 2023/4/6.
//  Copyright © 2023 debugly. All rights reserved.
//

#import "MultiRenderSample.h"
#import <FSPlayer/FSPlayerKit.h>
#import "MRRenderViewAuxProxy.h"

@interface MultiRenderSample ()

@property (nonatomic, strong) FSPlayer *player;

@end

@implementation MultiRenderSample

- (void)dealloc
{
    [self.player shutdown];
}

- (void)setContentURL:(NSURL *)contentURL
{
    if (_contentURL != contentURL) {
        _contentURL = contentURL;
        [self playURL:contentURL];
    }
}

- (void)playURL:(NSURL *)url
{
    if (self.player) {
        [self.player stop];
        self.player = nil;
    }
    
    FSOptions *options = [FSOptions optionsByDefault];
    //视频帧处理不过来的时候丢弃一些帧达到同步的效果
    [options setPlayerOptionIntValue:1 forKey:@"framedrop"];
    [options setPlayerOptionIntValue:6      forKey:@"video-pictq-size"];
    //    [options setPlayerOptionIntValue:50000      forKey:@"min-frames"];
    [options setPlayerOptionIntValue:119     forKey:@"max-fps"];
    // Param for playback
    [options setPlayerOptionIntValue:0 forKey:@"infbuf"];
    [options setPlayerOptionIntValue:1 forKey:@"packet-buffering"];
    
    [options setPlayerOptionIntValue:1 forKey:@"videotoolbox_hwaccel"];
    
    
    UIView<FSVideoRenderingProtocol> *render1 = [FSVideoRenderView createGLRenderView];
    UIView<FSVideoRenderingProtocol> *render2 = [FSVideoRenderView createMetalRenderView];
    
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
    
    MRRenderViewAuxProxy *videoAux = [[MRRenderViewAuxProxy alloc] init];
    
    [videoAux addRenderView:render1];
    [videoAux addRenderView:render2];
    
    self.player = [[FSPlayer alloc] initWithMoreContent:url withOptions:options withViewRendering:videoAux withAudioRendering:[FSAudioRendering createAudioQueueRendering]];
    
    videoAux.scalingMode = FSScalingModeAspectFill;
    self.player.shouldAutoplay = YES;
    [self.player prepareToPlay];
}

@end
