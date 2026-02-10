/*
 * Copyright (C) 2013-2015 Bilibili
 * Copyright (C) 2013-2015 Zhang Rui <bbcallen@gmail.com>
 * Copyright (c) 2019 debugly <qianlongxu@gmail.com>
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
#import <Photos/Photos.h>

@interface FSVideoViewController ()<FSVideoRenderingDelegate>

@end

@implementation FSVideoViewController

- (void)dealloc
{
}

+ (void)presentFromViewController:(UIViewController *)viewController withTitle:(NSString *)title URL:(NSString *)url completion:(void (^)(void))completion {
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
        self.url = fake_url;
    }
    self.manifest = manifest_string;
    return self;
}

- (instancetype)initWithURL:(NSString *)url {
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
        self.modalPresentationStyle = UIModalPresentationFullScreen;
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

    self.view.backgroundColor = UIColor.blackColor;
    
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
    options.automaticallySetupAudioSession = YES;
    options.currentPlaybackTimeNotificationInterval = 0.5;
    
    self.player = [[FSPlayer alloc] initWithContent:self.url options:options];
    self.player.playbackLoop = 2;
    //设置代理，拿到当前渲染帧
    [self.player.view setDisplayDelegate:self];
    self.player.scalingMode = FSScalingModeAspectFit;
    self.player.shouldAutoplay = YES;
    
    FSSubtitlePreference p = self.player.subtitlePreference;
    p.PrimaryColour = 16776960;
    self.player.subtitlePreference = p;
    
    self.player.view.frame = self.view.bounds;
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
    
    id<FSMediaPlayback> player = self.player;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        [player shutdown];
    });
    [self removeMovieNotificationObservers];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.player.view.frame = self.view.bounds;
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)videoRenderingDidDisplay:(id<FSVideoRenderingProtocol>)renderer attach:(FSOverlayAttach *)attach
{
    //NSLog(@"当前帧：%@",attach);
}

#pragma mark IBAction

- (UIStatusBarStyle)preferredStatusBarStyle
{
    return UIStatusBarStyleLightContent;
}

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

- (IBAction)onClickOrientation:(UIBarButtonItem *)sender
{
    if (@available(iOS 16.0, *)) {
        [self setNeedsUpdateOfSupportedInterfaceOrientations];
        
        UIInterfaceOrientationMask mask;
        if (UIInterfaceOrientationIsPortrait(self.view.window.windowScene.interfaceOrientation)) {
            mask = UIInterfaceOrientationMaskLandscapeRight;
        } else {
            mask = UIInterfaceOrientationMaskPortrait;
        }
        [self.view.window.windowScene requestGeometryUpdateWithPreferences:[[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask]
                                                              errorHandler:^(NSError * _Nonnull error) {
            
        }];
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

- (void)checkPhotoLibraryPermissions:(void(^)(BOOL granted))completion
{
    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
    
    switch (status) {
        case PHAuthorizationStatusAuthorized:
        {
            completion(YES);
        }
            
            break;
        case PHAuthorizationStatusNotDetermined:
        {
            [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
                completion(status == PHAuthorizationStatusAuthorized);
            }];
        }
            break;
        default:
        {
            completion(NO);
        }
            break;
    }
}

- (void)saveVideoWithAuthorization:(NSURL *)videoURL completion:(void(^)(BOOL success, NSError *error))completion {
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
        [request addResourceWithType:PHAssetResourceTypeVideo fileURL:videoURL options:nil];
    } completionHandler:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(success, error);
        });
    }];
}

- (void)saveToPhotosAlbum
{
    [self checkPhotoLibraryPermissions:^(BOOL granted) {
        if (granted) {
            [self saveVideoWithAuthorization:[NSURL URLWithString:recordVideoPath] completion:^(BOOL success, NSError *error) {
                [[NSFileManager defaultManager] removeItemAtPath:recordVideoPath error:NULL];
                if (error) {
                    NSLog(@"保存到相册失败：%@",error);
                } else {
                    NSLog(@"保存到相册成功");
                }
            }];
        } else {
            [[NSFileManager defaultManager] removeItemAtPath:recordVideoPath error:NULL];
        }
    }];
}

static NSString *recordVideoPath = nil;

- (IBAction)onRecord:(UIButton *)sender
{
//    test dar
//    int dar_num = 0;
//    int dar_den = 1;
//    
//    if (self.player.view.darPreference.ratio == 0) {
//        dar_num = 1;
//        dar_den = 1;
//        self.player.view.darPreference = (FSDARPreference){1.0 * dar_num/dar_den};
//    } else {
//        self.player.view.darPreference = (FSDARPreference){0.0};
//    }
//    return;
    
    if (sender.isSelected) {
        int error = [self.player stopFastRecord];
        NSLog(@"停止录制:%d", error);
        if (!error) {
            [self saveToPhotosAlbum];
        } else {
            [[NSFileManager defaultManager] removeItemAtPath:recordVideoPath error:NULL];
        }
    } else {
        // 获取Caches目录路径
        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *cacheDirectory = [paths firstObject];
        // 获取当前时间戳（毫秒级）
        NSDate *now = [NSDate date];
        long long timestamp = (long long)([now timeIntervalSince1970] * 1000);
        NSString *extension = [[self.player.content lastPathComponent] pathExtension];
        if (!extension) {
            extension = [[self.player getInputFormatExtensions] firstObject];
        }
        if (!extension) {
            extension = @"mkv";
        }
        // 格式化为字符串
        NSString *fileName = [NSString stringWithFormat:@"%lld.%@", timestamp, extension];
        // 构建完整文件路径
        NSString *filePath = [cacheDirectory stringByAppendingPathComponent:fileName];
        int error = [self.player startFastRecord:filePath];
        if (error) {
            NSLog(@"开始录制:%d",error);
        } else {
            NSLog(@"开始录制:%@",filePath);
            recordVideoPath = filePath;
        }
    }
    
    [sender setSelected:!sender.isSelected];
}

- (void)loadStateDidChange:(NSNotification*)notification
{
    //    MPMovieLoadStateUnknown        = 0,
    //    MPMovieLoadStatePlayable       = 1 << 0,
    //    MPMovieLoadStatePlaythroughOK  = 1 << 1, // Playback will be automatically started in this state when shouldAutoplay is YES
    //    MPMovieLoadStateStalled        = 1 << 2, // Playback will be automatically paused in this state, if started

    FSPlayerLoadState loadState = _player.loadState;

    if ((loadState & FSPlayerLoadStatePlaythroughOK) != 0) {
        NSLog(@"loadStateDidChange: FSPlayerLoadStatePlaythroughOK: %d\n", (int)loadState);
    } else if ((loadState & FSPlayerLoadStateStalled) != 0) {
        NSLog(@"loadStateDidChange: FSPlayerLoadStateStalled: %d\n", (int)loadState);
    } else {
        NSLog(@"loadStateDidChange: ???: %d\n", (int)loadState);
    }
}

- (void)moviePlayBackDidFinish:(NSNotification*)notification
{
    //    MPMovieFinishReasonPlaybackEnded,
    //    MPMovieFinishReasonPlaybackError,
    //    MPMovieFinishReasonUserExited
    int reason = [[[notification userInfo] valueForKey:FSPlayerDidFinishReasonUserInfoKey] intValue];

    switch (reason)
    {
        case FSFinishReasonPlaybackEnded:
            NSLog(@"playbackStateDidChange: FSFinishReasonPlaybackEnded: %d\n", reason);
            break;

        case FSFinishReasonUserExited:
            NSLog(@"playbackStateDidChange: FSFinishReasonUserExited: %d\n", reason);
            break;

        case FSFinishReasonPlaybackError:
            NSLog(@"playbackStateDidChange: FSFinishReasonPlaybackError: %d\n", reason);
            break;

        default:
            NSLog(@"playbackPlayBackDidFinish: ???: %d\n", reason);
            break;
    }
    
    [self.mediaControl refreshMediaControl];
}

- (void)mediaIsPreparedToPlayDidChange:(NSNotification*)notification
{
    NSLog(@"mediaIsPreparedToPlayDidChange\n");
}

- (void)moviePlayBackStateDidChange:(NSNotification*)notification
{
    switch (self.player.playbackSchedule) {
        case FSPlayerPlaybackScheduleIdle:
            NSLog(@"FSPlayerPlaybackSchedule:Idle");
            break;
        case FSPlayerPlaybackScheduleInitialized:
            NSLog(@"FSPlayerPlaybackSchedule:Initialized");
            break;
        case FSPlayerPlaybackSchedulePreparing:
            NSLog(@"FSPlayerPlaybackSchedule:Preparing");
            break;
        case FSPlayerPlaybackSchedulePrepared:
            NSLog(@"FSPlayerPlaybackSchedule:Prepared");
            break;
        case FSPlayerPlaybackScheduleStarted:
            NSLog(@"FSPlayerPlaybackSchedule:Started");
            break;
        case FSPlayerPlaybackSchedulePaused:
            NSLog(@"FSPlayerPlaybackSchedule:Paused");
            break;
        case FSPlayerPlaybackScheduleCompleted:
            NSLog(@"FSPlayerPlaybackSchedule:Completed");
            break;
        case FSPlayerPlaybackScheduleStopped:
            NSLog(@"FSPlayerPlaybackSchedule:Stopped");
            break;
        case FSPlayerPlaybackScheduleError:
            NSLog(@"FSPlayerPlaybackSchedule:Error");
            break;
    }
    
    switch (self.player.playbackState) {
        case FSPlayerPlaybackStatePaused:
            NSLog(@"FSPlayerPlaybackState:Paused");
            break;
        case FSPlayerPlaybackStatePlaying:
            NSLog(@"FSPlayerPlaybackState:Playing");
            break;
        case FSPlayerPlaybackStateStopped:
            NSLog(@"FSPlayerPlaybackState:Stopped");
            break;
        case FSPlayerPlaybackStateInterrupted:
            NSLog(@"FSPlayerPlaybackState:Interrupted");
            break;
        case FSPlayerPlaybackStateSeekingForward:
            NSLog(@"FSPlayerPlaybackState:SeekingForward");
            break;
        case FSPlayerPlaybackStateSeekingBackward:
            NSLog(@"FSPlayerPlaybackState:SeekingBackward");
            break;
    }
    
    [self.mediaControl refreshMediaControl];
}

- (void)moviePlayBackBufferingDidChange:(NSNotification*)notification {
    NSLog(@"bufferingDidChange: %ld",(long)_player.bufferingProgress);
}

- (void)moviePlayBackCurrentPlaybackTimeDidChange:(NSNotification*)notification {
    NSLog(@"currentPlaybackTimeDidChange: %f", _player.currentPlaybackTime);
    [self.mediaControl refreshMediaControl];
}

#pragma mark Install Movie Notifications

/* Register observers for the various movie object notifications. */
-(void)installMovieNotificationObservers
{
	[[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(loadStateDidChange:)
                                                 name:FSPlayerLoadStateDidChangeNotification
                                               object:_player];

	[[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(moviePlayBackDidFinish:)
                                                 name:FSPlayerDidFinishNotification
                                               object:_player];

	[[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(mediaIsPreparedToPlayDidChange:)
                                                 name:FSPlayerIsPreparedToPlayNotification
                                               object:_player];

	[[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(moviePlayBackStateDidChange:)
                                                 name:FSPlayerPlaybackStateDidChangeNotification
                                               object:_player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(moviePlayBackBufferingDidChange:)
                                                 name:FSPlayerBufferingDidChangeNotification
                                               object:_player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(moviePlayBackCurrentPlaybackTimeDidChange:)
                                                 name:FSPlayerCurrentPlaybackTimeDidChangeNotification
                                               object:_player];
}

#pragma mark Remove Movie Notification Handlers

/* Remove the movie notification observers from the movie object. */
-(void)removeMovieNotificationObservers
{
    [[NSNotificationCenter defaultCenter]removeObserver:self name:FSPlayerLoadStateDidChangeNotification object:_player];
    [[NSNotificationCenter defaultCenter]removeObserver:self name:FSPlayerDidFinishNotification object:_player];
    [[NSNotificationCenter defaultCenter]removeObserver:self name:FSPlayerIsPreparedToPlayNotification object:_player];
    [[NSNotificationCenter defaultCenter]removeObserver:self name:FSPlayerPlaybackStateDidChangeNotification object:_player];
    [[NSNotificationCenter defaultCenter]removeObserver:self name:FSPlayerBufferingDidChangeNotification object:_player];
    [[NSNotificationCenter defaultCenter]removeObserver:self name:FSPlayerCurrentPlaybackTimeDidChangeNotification object:_player];
}

@end
