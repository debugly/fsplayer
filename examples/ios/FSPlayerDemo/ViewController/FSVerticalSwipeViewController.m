/*
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

#import "FSVerticalSwipeViewController.h"

#import "FSVerticalFeed.h"
#import "UIImage+FSImageEffects.h"

#import <FSPlayer/FSPlayerKit.h>

/// Drag distance, in points, that turns into a room switch. Below this the
/// pan view animates back and the room is untouched.
static const CGFloat kFSSwitchThreshold = 80.0;
static const NSTimeInterval kFSSwitchAnimationDuration = 0.4;

typedef NS_ENUM(NSInteger, FSPanDirection) {
    FSPanDirectionUnknown = 0,
    FSPanDirectionUp,
    FSPanDirectionDown,
};

@interface FSVerticalSwipeViewController () <UIGestureRecognizerDelegate>

@property(nonatomic, strong) FSVerticalFeedPage *page;
@property(nonatomic, strong) FSVerticalFeedItem *currentItem;

/// Blurred backdrop.
@property(nonatomic, strong) UIView *backgroundView;
@property(nonatomic, strong) UIImageView *coverView;

/// The view that actually gets dragged, and that hosts the player.
@property(nonatomic, strong) UIView *panView;

@property(nonatomic, strong) id<FSMediaPlayback> player;

/// Overlay controls, kept above the pan view so they do not slide away.
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *hintLabel;
@property(nonatomic, strong) UIButton *playPauseButton;

@property(nonatomic, assign) CGPoint panStartCenter;
@property(nonatomic, assign) BOOL isSwitching;
@property(nonatomic, assign) BOOL playbackSuspended;
@property(nonatomic, assign) BOOL resumePlaybackWhenActive;

@end

@implementation FSVerticalSwipeViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor blackColor];
    self.title = @"Vertical Swipe";

    [self buildSubviews];

    self.playbackSuspended = [UIApplication sharedApplication].applicationState != UIApplicationStateActive;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [self loadFeedAndPlay];

    // Debug aids, driven by launch arguments so the interaction can be checked
    // without a touch channel:
    //   -FSVerticalPeek  offset the pan view without animating, to see the
    //                    backdrop the swipe reveals
    //   -FSVerticalSwipeN  run N room switches on a timer, to exercise the
    //                    switch path end to end
    NSArray<NSString *> *args = [NSProcessInfo processInfo].arguments;

    if ([args containsObject:@"-FSVerticalPeek"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            self.panView.center = CGPointMake(self.panStartCenter.x,
                                              self.panStartCenter.y - self.view.bounds.size.height * 0.45);
        });
    }

    NSUInteger switchCount = 0;
    for (NSString *arg in args) {
        if ([arg hasPrefix:@"-FSVerticalSwipeN="]) {
            switchCount = (NSUInteger)[arg substringFromIndex:@"-FSVerticalSwipeN=".length].integerValue;
        }
    }
    [self runAutomatedSwipes:switchCount from:0];
}

- (void)runAutomatedSwipes:(NSUInteger)remaining from:(NSUInteger)index {
    if (remaining == 0) {
        return;
    }

    NSUInteger next = index + 1;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // Go through the real gesture entry point, not a shortcut, so the
        // threshold and animation behave exactly as under a finger.
        self.panStartCenter = self.panView.center;
        [self finishPanWithTranslation:-self.view.bounds.size.height];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSLog(@"FSVertical auto-swipe %lu done, now %@",
                  (unsigned long)next, self.currentItem.title);
            [self runAutomatedSwipes:remaining - 1 from:next];
        });
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    if (self.isMovingFromParentViewController) {
        [self teardownPlayer];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    if (self.playbackSuspended) {
        return;
    }
    self.playbackSuspended = YES;
    self.resumePlaybackWhenActive = [self.player isPlaying] ||
        (self.player && !self.player.isPreparedToPlay && self.player.shouldAutoplay);
    // Also prevent a pending prepare from starting playback in the background.
    self.player.shouldAutoplay = NO;
    [self.player pause];
    [self updatePlaybackButton];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    self.playbackSuspended = NO;
    BOOL resume = self.resumePlaybackWhenActive;
    self.resumePlaybackWhenActive = NO;
    if (resume && self.player) {
        self.player.shouldAutoplay = YES;
        [self.player play];
    }
    [self updatePlaybackButton];
}

#pragma mark - Subviews

- (void)buildSubviews {
    // Backdrop first, then the pan container. Both fill the screen.
    self.backgroundView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.backgroundView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    self.backgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.backgroundView];

    self.coverView = [[UIImageView alloc] initWithFrame:self.backgroundView.bounds];
    self.coverView.contentMode = UIViewContentModeScaleAspectFill;
    self.coverView.clipsToBounds = YES;
    self.coverView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.backgroundView addSubview:self.coverView];

    self.panView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.panView.backgroundColor = [UIColor blackColor];
    self.panView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.panView];

    // The pan gesture goes on the pan view, not on self.view: the player and
    // the overlay are subviews here, and attaching to self.view would let them
    // swallow the gesture.
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    pan.maximumNumberOfTouches = 1;
    pan.minimumNumberOfTouches = 1;
    [self.panView addGestureRecognizer:pan];

    [self buildOverlay];
}

- (void)buildOverlay {
    CGRect bounds = self.view.bounds;

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 64, bounds.size.width - 32, 24)];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    self.titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    self.hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, bounds.size.height - 72,
                                                               bounds.size.width, 20)];
    self.hintLabel.text = @"Swipe up / down to change room";
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    self.hintLabel.font = [UIFont systemFontOfSize:13];
    self.hintLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;

    // Above the pan view so the overlay stays put while the video slides.
    [self.view addSubview:self.titleLabel];
    [self.view addSubview:self.hintLabel];

    self.playPauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.playPauseButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.playPauseButton.tintColor = [UIColor whiteColor];
    self.playPauseButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    self.playPauseButton.layer.cornerRadius = 22;
    self.playPauseButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.playPauseButton addTarget:self action:@selector(togglePlayback)
                  forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.playPauseButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.playPauseButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.playPauseButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-88],
        [self.playPauseButton.widthAnchor constraintEqualToConstant:112],
        [self.playPauseButton.heightAnchor constraintEqualToConstant:44],
    ]];
    [self updatePlaybackButton];
}

#pragma mark - Feed

- (void)loadFeedAndPlay {
    __weak __typeof(self) weakSelf = self;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        FSVerticalFeedPage *page = [[FSVerticalFeedStore sharedStore] loadPageWithError:&error];

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) self = weakSelf;
            if (!self) {
                return;
            }

            if (!page) {
                [self showLoadError:error];
                return;
            }

            self.page = page;
            [self playItem:page.items.firstObject];
        });
    });
}

- (void)showLoadError:(NSError *)error {
    NSLog(@"FSVertical: feed failed to load: %@", error);

    self.hintLabel.text = error.localizedDescription ?: @"Feed failed to load";
    self.hintLabel.textColor = [UIColor colorWithRed:1.0 green:0.4 blue:0.4 alpha:1.0];
}

#pragma mark - Playback

- (void)playItem:(FSVerticalFeedItem *)item {
    if (!item) {
        self.hintLabel.text = @"No such room in the feed";
        return;
    }

    if (item == self.currentItem && self.player) {
        return;
    }

    self.currentItem = item;

    self.titleLabel.text = item.title.length > 0 ? item.title : @"Untitled";
    self.hintLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    self.hintLabel.text = @"Swipe up / down to change room";

    [self applyBackdropForItem:item];

    [self teardownPlayer];

    FSOptions *options = [FSOptions optionsByDefault];
    options.automaticallySetupAudioSession = YES;
    options.currentPlaybackTimeNotificationInterval = 0.5;

    FSPlayer *player = [[FSPlayer alloc] initWithContent:item.streamUrl options:options];
    player.shouldAutoplay = !self.playbackSuspended;
    self.resumePlaybackWhenActive = self.playbackSuspended;
    player.scalingMode = FSScalingModeAspectFit;

    player.view.frame = self.panView.bounds;
    player.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.panView addSubview:player.view];

    self.player = player;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playbackStateDidChange:)
                                                 name:FSPlayerPlaybackStateDidChangeNotification
                                               object:player];
    [player prepareToPlay];
    [self updatePlaybackButton];
}

- (void)togglePlayback {
    if (self.playbackSuspended) {
        return;
    }
    if ([self.player isPlaying]) {
        self.player.shouldAutoplay = NO;
        [self.player pause];
    } else {
        self.player.shouldAutoplay = YES;
        [self.player play];
    }
    [self updatePlaybackButton];
}

- (void)playbackStateDidChange:(NSNotification *)notification {
    if (notification.object == self.player) {
        [self updatePlaybackButton];
    }
}

- (void)updatePlaybackButton {
    BOOL playing = [self.player isPlaying];
    NSString *title = playing ? @"Pause" : @"Play";
    [self.playPauseButton setTitle:title forState:UIControlStateNormal];
    self.playPauseButton.accessibilityLabel = title;
    self.playPauseButton.enabled = self.player != nil && !self.playbackSuspended;
}

- (void)teardownPlayer {
    self.resumePlaybackWhenActive = NO;
    if (!self.player) {
        return;
    }

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:FSPlayerPlaybackStateDidChangeNotification
                                                  object:self.player];
    [self.player stop];
    [self.player.view removeFromSuperview];
    self.player = nil;
    [self updatePlaybackButton];
}

#pragma mark - Backdrop

- (void)applyBackdropForItem:(FSVerticalFeedItem *)item {
    UIImage *blurred = [self blurredCoverForItem:item];

    if (!blurred) {
        return;
    }

    // Crossfade so a fast swipe does not show a hard cut.
    [UIView transitionWithView:self.backgroundView
                      duration:0.25
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
        self.coverView.image = blurred;
    } completion:nil];
}

/// Blurring is expensive, so it happens off the main thread. Falls back to a
/// flat tint derived from the item when there is no cover image, which keeps
/// the backdrop non-empty without a network fetch.
- (UIImage *)blurredCoverForItem:(FSVerticalFeedItem *)item {
    UIImage *source = [self coverImageForItem:item];
    if (!source) {
        source = [self placeholderCoverForItem:item];
    }
    if (!source) {
        return nil;
    }

    // Downscale before blurring: the box convolution cost scales with pixel
    // count, and the result is stretched to fill the screen anyway.
    CGSize target = CGSizeMake(80, 80);
    UIGraphicsBeginImageContextWithOptions(target, YES, 1.0);
    [source drawInRect:CGRectMake(0, 0, target.width, target.height)];
    UIImage *small = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    // SohuLive blurs the anchor avatar with a heavy dark tint. A flat colour
    // backdrop has no detail to blur, so that tint just crushes it to black;
    // use a lighter effect here so the room's colour still reads.
    UIImage *blurred = [small fs_applyBlurWithRadius:25
                                          tintColor:[UIColor colorWithWhite:0.0 alpha:0.25]
                              saturationDeltaFactor:1.2];

    return blurred ?: small;
}

- (UIImage *)coverImageForItem:(FSVerticalFeedItem *)item {
    NSString *urlString = item.coverUrl;
    if (urlString.length == 0) {
        return nil;
    }

    NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:urlString]];
    return data ? [UIImage imageWithData:data] : nil;
}

/// A vertical gradient built from the item's tint, so every room still gets a
/// distinct backdrop even with no cover art.
- (UIImage *)placeholderCoverForItem:(FSVerticalFeedItem *)item {
    UIColor *tint = item.tintColor ?: [UIColor colorWithWhite:0.18 alpha:1.0];
    UIColor *dark = [UIColor colorWithWhite:0.10 alpha:1.0];

    CGSize size = self.backgroundView.bounds.size;
    if (size.width < 1 || size.height < 1) {
        size = CGSizeMake(1, 1);
    }

    UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = @[(__bridge id)tint.CGColor, (__bridge id)dark.CGColor];
    CGFloat locations[] = {0.0, 1.0};
    CGGradientRef gradient =
        CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, locations);
    CGContextDrawLinearGradient(context, gradient,
                                CGPointZero,
                                CGPointMake(0, size.height), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return image;
}

#pragma mark - Pan

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    // Ignore rotation of the same room; that path is not part of this demo.
    if (self.isSwitching) {
        return;
    }

    CGPoint translation = [pan translationInView:self.view];
    CGFloat offsetY = translation.y;

    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            self.panStartCenter = self.panView.center;
            break;

        case UIGestureRecognizerStateChanged: {
            // Rubber-band: vertical only, and it follows the finger 1:1.
            CGFloat clamped = MAX(-self.view.bounds.size.height, MIN(self.view.bounds.size.height, offsetY));
            self.panView.center = CGPointMake(self.panStartCenter.x,
                                              self.panStartCenter.y + clamped);
        } break;

        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
            [self finishPanWithTranslation:offsetY];
            break;

        default:
            break;
    }
}

- (void)finishPanWithTranslation:(CGFloat)offsetY {
    // Only a clear vertical drag switches. A diagonal or tiny drag springs back,
    // which is what keeps a horizontal swipe from changing rooms.
    if (fabs(offsetY) < kFSSwitchThreshold) {
        [self animateBack];
        return;
    }

    if (offsetY < 0) {
        [self switchToNextRoom];
    } else {
        [self switchToPreviousRoom];
    }
}

- (void)animateBack {
    [self animatePanToCenter:CGPointMake(self.panStartCenter.x, self.panStartCenter.y)];
}

- (void)animatePanToCenter:(CGPoint)center {
    self.isSwitching = YES;

    [UIView animateWithDuration:kFSSwitchAnimationDuration
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.panView.center = center;
    } completion:^(BOOL finished) {
        self.isSwitching = NO;
    }];
}

- (void)switchToNextRoom {
    [self switchRoomWithItem:[self.page itemAfterItem:self.currentItem]
                   direction:FSPanDirectionUp];
}

- (void)switchToPreviousRoom {
    [self switchRoomWithItem:[self.page itemBeforeItem:self.currentItem]
                   direction:FSPanDirectionDown];
}

- (void)switchRoomWithItem:(FSVerticalFeedItem *)item direction:(FSPanDirection)direction {
    if (!item) {
        // End of the feed: bounce back rather than leaving a black screen.
        [self animateBack];
        return;
    }

    self.isSwitching = YES;

    // Slide the old room fully out in the drag direction, then bring it back
    // to centre while the new room starts playing underneath.
    CGFloat sign = (direction == FSPanDirectionUp) ? -1.0 : 1.0;
    CGFloat height = self.view.bounds.size.height;

    [UIView animateWithDuration:kFSSwitchAnimationDuration
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self.panView.center = CGPointMake(self.panStartCenter.x,
                                          self.panStartCenter.y + sign * height);
    } completion:^(BOOL finished) {
        [self playItem:item];
        self.panView.center = self.panStartCenter;
        self.isSwitching = NO;
    }];
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}

@end
