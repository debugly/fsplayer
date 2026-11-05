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
#import <AVKit/AVKit.h>

@interface FSVideoViewController ()<FSVideoRenderingDelegate>

@property(nonatomic,strong) NSURL *temporaryMovieURL;
#if !TARGET_OS_TV
/// 工具栏上的画中画入口（xib 里的 “PiP” barButtonItem）
@property(nonatomic,weak) UIBarButtonItem *pipBarButtonItem;
/// 系统正在从画中画恢复本页（用户点了画中画窗口的“返回 App”）。置位时，
/// viewWillAppear 不再重新 prepareToPlay，退出画中画时也不关闭播放器。
@property(nonatomic,assign) BOOL pipRestoring;
/// 为“发起新播放”而主动丢弃本页：置位后停止画中画时不再把本页 present 回来，
/// 直接随画中画结束关闭旧播放器。避免旧页被 restore 回调重新弹出、与新播放页叠加。
@property(nonatomic,assign) BOOL pipDiscarding;
#endif

@end

#if !TARGET_OS_TV
// 画中画激活期间，本页会被 dismiss 以隐藏播放界面。dismiss 后原 presenting VC 不再
// 持有本页，这里用一个强引用兜住它，保证本页与它持有的 FSPlayer 在画中画期间存活；
// 退出画中画（返回或关闭）后再释放。
static FSVideoViewController *sPictureInPictureHoldingController = nil;
#endif

@implementation FSVideoViewController

- (void)dealloc
{
#if !TARGET_OS_TV
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:FSPlayerPictureInPictureStateDidChangeNotification
                                                  object:nil];
#endif
    if (_temporaryMovieURL) {
        [[NSFileManager defaultManager] removeItemAtURL:_temporaryMovieURL error:NULL];
    }
}

+ (void)presentFromViewController:(UIViewController *)viewController withTitle:(NSString *)title URL:(NSString *)url completion:(void (^)(void))completion {
    FSDemoHistoryItem *historyItem = [[FSDemoHistoryItem alloc] init];
    
    historyItem.title = title;
    historyItem.url = url;
    [[FSDemoHistory instance] add:historyItem];
    
    [viewController presentViewController:[[FSVideoViewController alloc] initWithURL:url] animated:YES completion:completion];
}

- (instancetype)initWithURL:(NSString *)url {
    self = [self initWithNibName:@"FSMoviePlayerViewController" bundle:nil];
    if (self) {
        self.url = url;
    }
    return self;
}

- (instancetype)initWithTemporaryMovieURL:(NSURL *)movieURL {
    self = [self initWithURL:movieURL.path];
    if (self) {
        _temporaryMovieURL = movieURL;
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

#if !TARGET_OS_TV
    // 不论从哪个入口创建新的播放页（有的入口直接 alloc/present，不走
    // presentFromViewController:），只要上一条播放还停留在画中画，就先把它结束，
    // 避免旧画中画与新播放页并存。pipDiscarding 让旧页在停止 PiP 时不被 restore
    // 回调重新 present 回来。
    FSVideoViewController *holding = sPictureInPictureHoldingController;
    if (holding && holding != self && [holding.player isKindOfClass:[FSPlayer class]]) {
        holding.pipDiscarding = YES;
        [(FSPlayer *)holding.player stopPictureInPicture];
    }
#endif

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

    NSLog(@"ffmpegVersion:%@", [FSPlayer ffmpegVersion]);
    NSLog(@"playerVersion:%@", [FSPlayer playerVersion]);
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

    options.automaticallySetupAudioSession = YES;
    options.currentPlaybackTimeNotificationInterval = 0.5;
    
    self.player = [[FSPlayer alloc] initWithContent:self.url options:options];
    self.player.playbackLoop = 2;
    //设置代理，拿到当前渲染帧
    if ([self.player.view conformsToProtocol:@protocol(FSVideoRenderingProtocol)]) {
        UIView<FSVideoRenderingProtocol>* renderingView = (UIView<FSVideoRenderingProtocol>*)self.player.view;
        [renderingView setDisplayDelegate:self];
    }
    
    self.player.scalingMode = FSScalingModeAspectFit;
    self.player.shouldAutoplay = YES;
    //自动恢复
    [self.player autoResumeOnForeground:YES];
    FSSubtitlePreference p = self.player.subtitlePreference;
    p.PrimaryColour = 16776960;
    self.player.subtitlePreference = p;
    
    self.player.view.frame = self.view.bounds;
    [self.view addSubview:self.player.view];
    [self.view addSubview:self.mediaControl];

    self.mediaControl.delegatePlayer = self.player;

#if !TARGET_OS_TV
    // 画中画状态观察者随 VC 生命周期常驻（在 dealloc 注销），而不是跟着
    // viewWillAppear/viewDidDisappear 装卸：进入画中画后本页会被隐藏，仍需在隐藏
    // 期间收到“画中画已停止”的回调来决定恢复界面还是关闭播放器。
    if ([self.player isKindOfClass:[FSPlayer class]]) {
        FSPlayer *player = (FSPlayer *)self.player;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(pictureInPictureStateDidChange:)
                                                     name:FSPlayerPictureInPictureStateDidChangeNotification
                                                   object:player];
        // 系统请求从画中画返回 App 时，由本页重新把自己 present 回来，再回调系统完成。
        __weak typeof(self) weakSelf = self;
        player.pictureInPictureRestoreUIHandler = ^(void (^completionHandler)(BOOL restored)) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.pipDiscarding) {
                // 本页正被丢弃（为新播放让路）：不恢复界面，直接告知系统未恢复。
                completionHandler(NO);
                return;
            }
            strongSelf.pipRestoring = YES;
            UIViewController *presenter = [UIApplication sharedApplication].keyWindow.rootViewController;
            while (presenter.presentedViewController) {
                presenter = presenter.presentedViewController;
            }
            [presenter presentViewController:strongSelf animated:YES completion:^{
                completionHandler(YES);
            }];
        };
    }
#endif
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [self installMovieNotificationObservers];

#if !TARGET_OS_TV
    if (self.pipRestoring) {
        // 从画中画返回：播放器一直在运行，不要重新 prepare（会打断播放）。
        return;
    }
#endif
    [self.player prepareToPlay];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];

    // 平衡 viewWillAppear 里安装的播放通知观察者（画中画状态观察者在 dealloc 注销，不在此处）。
    [self removeMovieNotificationObservers];

#if !TARGET_OS_TV
    // 进入画中画会 dismiss 本页以隐藏播放界面，但播放器必须继续运行，否则
    // ff_vout 停止解码，画中画窗口会定格在最后一帧。此时不要关闭播放器。
    if ([self.player isKindOfClass:[FSPlayer class]] &&
        ((FSPlayer *)self.player).isPictureInPictureActive) {
        return;
    }
#endif

    id<FSMediaPlayback> player = self.player;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        // Keep the controller and its temporary file alive until playback shuts down.
        [player shutdownSync:self.temporaryMovieURL != nil];
    });
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

- (void)videoRenderingDidDisplay:(id<FSVideoRenderingProtocol>)renderer attach:(id<FSVideoRenderFrame>)attach
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
#ifdef __IPHONE_16_0
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
#endif
}

#if !TARGET_OS_TV
- (IBAction)onClickPictureInPicture:(UIBarButtonItem *)sender
{
    self.pipBarButtonItem = sender;
    if (![self.player isKindOfClass:[FSPlayer class]]) {
        return;
    }
    FSPlayer *player = (FSPlayer *)self.player;
    NSLog(@"[PiP] supported:%d active:%d possible:%d",
          player.isPictureInPictureSupported,
          player.isPictureInPictureActive,
          [(AVPictureInPictureController *)player.pictureInPictureController isPictureInPicturePossible]);
    if (player.isPictureInPictureActive) {
        [player stopPictureInPicture];
    } else {
        [player startPictureInPicture];
    }
}

- (void)pictureInPictureStateDidChange:(NSNotification *)notification
{
    // 本方法可能把 sPictureInPictureHoldingController 置空，而那可能是本页唯一的强
    // 引用；用一个方法级强引用保证本页在本次回调执行期间不被提前析构。
    __strong typeof(self) keepSelfAlive __attribute__((unused)) = self;

    FSPlayer *player = (FSPlayer *)notification.object;
    NSError *error = notification.userInfo[FSPlayerPictureInPictureErrorUserInfoKey];
    NSLog(@"[PiP] state changed active:%d error:%@", player.isPictureInPictureActive, error);
    self.pipBarButtonItem.title = player.isPictureInPictureActive ? @"PiP On" : @"PiP";

    if (error) {
        // 启动失败：页面未隐藏，无需做界面处理。
        return;
    }

    if (player.isPictureInPictureActive) {
        // 进入画中画：先用静态强引用兜住本页，避免 dismiss 后本页（及其 FSPlayer）
        // 被释放导致画中画画面来源消失；再 dismiss 隐藏播放界面（返回列表页）。
        sPictureInPictureHoldingController = self;
        if (self.presentingViewController) {
            [self dismissViewControllerAnimated:YES completion:nil];
        }
    } else {
        // 退出画中画
        if (self.pipRestoring) {
            // 用户点了“返回 App”：restore 回调已把本页重新 present 回来，继续播放即可。
            self.pipRestoring = NO;
        } else {
            // 用户点了画中画窗口的关闭按钮：播放页仍处于隐藏状态，关闭播放器。
            id<FSMediaPlayback> p = self.player;
            BOOL removeTemp = self.temporaryMovieURL != nil;
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                [p shutdownSync:removeTemp];
            });
        }
        // 画中画结束：释放静态强引用。恢复场景下本页已由 presenter 重新持有，关闭
        // 场景下由上面 shutdown 的 block 持有到清理完成，均不会在此处提前析构。
        // 用 == self 守卫：若此时静态引用已指向新播放页（新 VC 已进入画中画），不要误清。
        if (sPictureInPictureHoldingController == self) {
            sPictureInPictureHoldingController = nil;
        }
    }
}
#endif

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
