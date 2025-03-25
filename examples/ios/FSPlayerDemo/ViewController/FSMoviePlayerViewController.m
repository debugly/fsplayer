/*
 * Copyright (C) 2013-2015 Bilibili
 * Copyright (C) 2013-2015 Zhang Rui <bbcallen@gmail.com>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "FSMoviePlayerViewController.h"
#import "FSMediaControl.h"
#import "FSCommon.h"
#import "FSDemoHistory.h"

@implementation FSVideoViewController

- (void)dealloc
{
}

+ (void)presentFromViewController:(UIViewController *)viewController withTitle:(NSString *)title URL:(NSURL *)url completion:(void (^)(void))completion {
    FSDemoHistoryItem *historyItem = [[FSDemoHistoryItem alloc] init];
    
    historyItem.title = title;
    historyItem.url = url;
    [[FSDemoHistory instance] add:historyItem];
    
    [viewController presentViewController:[[FSVideoViewController alloc] initWithURL:url] animated:YES completion:completion];
}

- (instancetype)initWithManifest: (NSString*)manifest_string {
    self = [self initWithNibName:@"FSMoviePlayerViewController" bundle:nil];
    if (self) {
        NSString *fake_url = @"http://fakeurl_for_manifest";
        NSURL   *url  = [NSURL URLWithString:fake_url];
        self.url = url;
    }
    self.manifest = manifest_string;
    return self;
}

- (instancetype)initWithURL:(NSURL *)url {
    self = [self initWithNibName:@"FSMoviePlayerViewController" bundle:nil];
    if (self) {
        self.url = url;
    }
    return self;
}

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        // Custom initialization
    }
    return self;
}

#define EXPECTED_IJKPLAYER_VERSION (1 << 16) & 0xFF) | 
- (void)viewDidLoad
{
    [super viewDidLoad];
    // Do any additional setup after loading the view from its nib.

//    [[UIApplication sharedApplication] setStatusBarHidden:YES];
//    [[UIApplication sharedApplication] setStatusBarOrientation:UIInterfaceOrientationLandscapeLeft animated:NO];

#ifdef DEBUG
    //[FSPlayer setLogReport:YES];
    [FSPlayer setLogLevel:FS_LOG_INFO];
#else
    [FSPlayer setLogReport:NO];
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

    if (self.manifest != nil){
        [options setFormatOptionValue:self.manifest forKey:@"manifest_string"];
        [options setPlayerOptionIntValue:1 forKey:@"is-manifest"];
    }
    options.metalRenderer = YES;
    self.player = [[FSPlayer alloc] initWithContentURL:self.url withOptions:options];
    self.player.view.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.player.view.frame = self.view.bounds;
//    self.player.view.frame = CGRectMake(0, 0, 414, 232);
    self.player.scalingMode = FSMPMovieScalingModeAspectFit;
    self.player.shouldAutoplay = YES;
    
    FSSDLSubtitlePreference p = self.player.subtitlePreference;
    p.PrimaryColour = 16776960;
    self.player.subtitlePreference = p;
    self.view.autoresizesSubviews = YES;
    [self.view addSubview:self.player.view];
    [self.view addSubview:self.mediaControl];

    self.mediaControl.delegatePlayer = self.player;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    [self installMovieNotificationObservers];

    [self.player prepareToPlay];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    
    [self.player shutdown];
    [self removeMovieNotificationObservers];
}

//- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation{
//    return UIInterfaceOrientationIsLandscape(toInterfaceOrientation);
//}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskLandscape;
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

#pragma mark IBAction

- (IBAction)onClickMediaControl:(id)sender
{
    [self.mediaControl showAndFade];
}

- (IBAction)onClickOverlay:(id)sender
{
    [self.mediaControl hide];
}

- (IBAction)onClickDone:(id)sender
{
    [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

- (IBAction)onClickHUD:(UIBarButtonItem *)sender
{
    if ([self.player isKindOfClass:[FSPlayer class]]) {
        FSPlayer *player = self.player;
        player.shouldShowHudView = !player.shouldShowHudView;
        
        sender.title = (player.shouldShowHudView ? @"HUD On" : @"HUD Off");
    }
}

- (IBAction)onClickPlay:(id)sender
{
    [self.player play];
    [self.mediaControl refreshMediaControl];
}

- (IBAction)onClickPause:(id)sender
{
    [self.player pause];
    [self.mediaControl refreshMediaControl];
}

- (IBAction)didSliderTouchDown
{
    [self.mediaControl beginDragMediaSlider];
}

- (IBAction)didSliderTouchCancel
{
    [self.mediaControl endDragMediaSlider];
}

- (IBAction)didSliderTouchUpOutside
{
    [self.mediaControl endDragMediaSlider];
}

- (IBAction)didSliderTouchUpInside
{
    self.player.currentPlaybackTime = self.mediaControl.mediaProgressSlider.value;
    [self.mediaControl endDragMediaSlider];
}

- (IBAction)didSliderValueChanged
{
    [self.mediaControl continueDragMediaSlider];
}

- (void)loadStateDidChange:(NSNotification*)notification
{
    //    MPMovieLoadStateUnknown        = 0,
    //    MPMovieLoadStatePlayable       = 1 << 0,
    //    MPMovieLoadStatePlaythroughOK  = 1 << 1, // Playback will be automatically started in this state when shouldAutoplay is YES
    //    MPMovieLoadStateStalled        = 1 << 2, // Playback will be automatically paused in this state, if started

    FSMPMovieLoadState loadState = _player.loadState;

    if ((loadState & FSMPMovieLoadStatePlaythroughOK) != 0) {
        NSLog(@"loadStateDidChange: FSMPMovieLoadStatePlaythroughOK: %d\n", (int)loadState);
    } else if ((loadState & FSMPMovieLoadStateStalled) != 0) {
        NSLog(@"loadStateDidChange: FSMPMovieLoadStateStalled: %d\n", (int)loadState);
    } else {
        NSLog(@"loadStateDidChange: ???: %d\n", (int)loadState);
    }
}

- (void)moviePlayBackDidFinish:(NSNotification*)notification
{
    //    MPMovieFinishReasonPlaybackEnded,
    //    MPMovieFinishReasonPlaybackError,
    //    MPMovieFinishReasonUserExited
    int reason = [[[notification userInfo] valueForKey:FSMPMoviePlayerPlaybackDidFinishReasonUserInfoKey] intValue];

    switch (reason)
    {
        case FSMPMovieFinishReasonPlaybackEnded:
            NSLog(@"playbackStateDidChange: FSMPMovieFinishReasonPlaybackEnded: %d\n", reason);
            break;

        case FSMPMovieFinishReasonUserExited:
            NSLog(@"playbackStateDidChange: FSMPMovieFinishReasonUserExited: %d\n", reason);
            break;

        case FSMPMovieFinishReasonPlaybackError:
            NSLog(@"playbackStateDidChange: FSMPMovieFinishReasonPlaybackError: %d\n", reason);
            break;

        default:
            NSLog(@"playbackPlayBackDidFinish: ???: %d\n", reason);
            break;
    }
}

- (void)mediaIsPreparedToPlayDidChange:(NSNotification*)notification
{
    NSLog(@"mediaIsPreparedToPlayDidChange\n");
}

- (void)moviePlayBackStateDidChange:(NSNotification*)notification
{
    //    MPMoviePlaybackStateStopped,
    //    MPMoviePlaybackStatePlaying,
    //    MPMoviePlaybackStatePaused,
    //    MPMoviePlaybackStateInterrupted,
    //    MPMoviePlaybackStateSeekingForward,
    //    MPMoviePlaybackStateSeekingBackward

    switch (_player.playbackState)
    {
        case FSMPMoviePlaybackStateStopped: {
            NSLog(@"FSMPMoviePlayBackStateDidChange %d: stoped", (int)_player.playbackState);
            break;
        }
        case FSMPMoviePlaybackStatePlaying: {
            NSLog(@"FSMPMoviePlayBackStateDidChange %d: playing", (int)_player.playbackState);
            break;
        }
        case FSMPMoviePlaybackStatePaused: {
            NSLog(@"FSMPMoviePlayBackStateDidChange %d: paused", (int)_player.playbackState);
            break;
        }
        case FSMPMoviePlaybackStateInterrupted: {
            NSLog(@"FSMPMoviePlayBackStateDidChange %d: interrupted", (int)_player.playbackState);
            break;
        }
        case FSMPMoviePlaybackStateSeekingForward:
        case FSMPMoviePlaybackStateSeekingBackward: {
            NSLog(@"FSMPMoviePlayBackStateDidChange %d: seeking", (int)_player.playbackState);
            break;
        }
        default: {
            NSLog(@"FSMPMoviePlayBackStateDidChange %d: unknown", (int)_player.playbackState);
            break;
        }
    }
}

#pragma mark Install Movie Notifications

/* Register observers for the various movie object notifications. */
-(void)installMovieNotificationObservers
{
	[[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(loadStateDidChange:)
                                                 name:FSMPMoviePlayerLoadStateDidChangeNotification
                                               object:_player];

	[[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(moviePlayBackDidFinish:)
                                                 name:FSMPMoviePlayerPlaybackDidFinishNotification
                                               object:_player];

	[[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(mediaIsPreparedToPlayDidChange:)
                                                 name:FSMPMediaPlaybackIsPreparedToPlayDidChangeNotification
                                               object:_player];

	[[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(moviePlayBackStateDidChange:)
                                                 name:FSMPMoviePlayerPlaybackStateDidChangeNotification
                                               object:_player];
}

#pragma mark Remove Movie Notification Handlers

/* Remove the movie notification observers from the movie object. */
-(void)removeMovieNotificationObservers
{
    [[NSNotificationCenter defaultCenter]removeObserver:self name:FSMPMoviePlayerLoadStateDidChangeNotification object:_player];
    [[NSNotificationCenter defaultCenter]removeObserver:self name:FSMPMoviePlayerPlaybackDidFinishNotification object:_player];
    [[NSNotificationCenter defaultCenter]removeObserver:self name:FSMPMediaPlaybackIsPreparedToPlayDidChangeNotification object:_player];
    [[NSNotificationCenter defaultCenter]removeObserver:self name:FSMPMoviePlayerPlaybackStateDidChangeNotification object:_player];
}

@end
