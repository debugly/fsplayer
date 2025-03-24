/*
 * FSMediaPlayback.h
 *
 * Copyright (c) 2013 Bilibili
 * Copyright (c) 2013 Zhang Rui <bbcallen@gmail.com>
 *
 * This file is part of ijkPlayer.
 *
 * ijkPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * ijkPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#import <Foundation/Foundation.h>
#if TARGET_OS_IOS || TARGET_OS_TV
#import <UIKit/UIKit.h>
#else
typedef NSView UIView;
#import <AppKit/AppKit.h>
#endif
#import "FSVideoRenderingProtocol.h"

typedef NS_ENUM(NSInteger, FSMPMoviePlaybackState) {
    FSMPMoviePlaybackStateStopped,
    FSMPMoviePlaybackStatePlaying,
    FSMPMoviePlaybackStatePaused,
    FSMPMoviePlaybackStateInterrupted,
    FSMPMoviePlaybackStateSeekingForward,
    FSMPMoviePlaybackStateSeekingBackward
};

typedef NS_OPTIONS(NSUInteger, FSMPMovieLoadState) {
    FSMPMovieLoadStateUnknown        = 0,
    FSMPMovieLoadStatePlayable       = 1 << 0,
    FSMPMovieLoadStatePlaythroughOK  = 1 << 1, // Playback will be automatically started in this state when shouldAutoplay is YES
    FSMPMovieLoadStateStalled        = 1 << 2, // Playback will be automatically paused in this state, if started
};

typedef NS_ENUM(NSInteger, FSMPMovieFinishReason) {
    FSMPMovieFinishReasonPlaybackEnded,
    FSMPMovieFinishReasonPlaybackError,
    FSMPMovieFinishReasonUserExited
};

// -----------------------------------------------------------------------------
// Thumbnails

typedef NS_ENUM(NSInteger, FSMPMovieTimeOption) {
    FSMPMovieTimeOptionNearestKeyFrame,
    FSMPMovieTimeOptionExact
};

@protocol FSMediaPlayback;

#pragma mark FSMediaPlayback

@protocol FSMediaPlayback <NSObject>

- (NSURL *)contentURL;
- (void)prepareToPlay;

- (void)play;
- (void)pause;
- (void)stop;
- (BOOL)isPlaying;
- (void)shutdown;
- (void)setPauseInBackground:(BOOL)pause;
//PS:外挂字幕，最多可挂载512个。
//挂载并激活字幕；本地网络均可
- (BOOL)loadThenActiveSubtitle:(NSURL*)url;
//仅挂载不激活字幕；本地网络均可
- (BOOL)loadSubtitleOnly:(NSURL*)url;
//批量挂载不激活字幕；本地网络均可
- (BOOL)loadSubtitlesOnly:(NSArray<NSURL*>*)urlArr;

@property(nonatomic, readonly)  UIView <FSVideoRenderingProtocol>*view;
@property(nonatomic)            NSTimeInterval currentPlaybackTime;
//音频额外延迟，供用户调整
@property(nonatomic)            float currentAudioExtraDelay;
//字幕额外延迟，供用户调整
@property(nonatomic)            float currentSubtitleExtraDelay;
//单位：ms
@property(nonatomic, readonly)  NSTimeInterval duration;
//单位：s
@property(nonatomic, readonly)  NSTimeInterval playableDuration;
@property(nonatomic, readonly)  NSInteger bufferingProgress;

@property(nonatomic, readonly)  BOOL isPreparedToPlay;
@property(nonatomic, readonly)  FSMPMoviePlaybackState playbackState;
@property(nonatomic, readonly)  FSMPMovieLoadState loadState;
@property(nonatomic, readonly) int isSeekBuffering;
@property(nonatomic, readonly) int isAudioSync;
@property(nonatomic, readonly) int isVideoSync;

@property(nonatomic, readonly) int64_t numberOfBytesTransferred;

@property(nonatomic, readonly) CGSize naturalSize;
@property(nonatomic, readonly) NSInteger videoZRotateDegrees;

@property(nonatomic) FSMPMovieScalingMode scalingMode;
@property(nonatomic) BOOL shouldAutoplay;

@property (nonatomic) BOOL allowsMediaAirPlay;
@property (nonatomic) BOOL isDanmakuMediaAirPlay;
@property (nonatomic, readonly) BOOL airPlayMediaActive;

@property (nonatomic) float playbackRate;
//from 0.0 to 1.0
@property (nonatomic) float playbackVolume;
#if TARGET_OS_IOS
- (UIImage *)thumbnailImageAtCurrentTime;
#endif

//subtitle preference
@property(nonatomic) FSSDLSubtitlePreference subtitlePreference;
//load spped (byte)
- (int64_t)currentDownloadSpeed;

#pragma mark Notifications

#ifdef __cplusplus
#define FS_EXTERN extern "C" __attribute__((visibility ("default")))
#else
#define FS_EXTERN extern __attribute__((visibility ("default")))
#endif

// -----------------------------------------------------------------------------
//  MPMediaPlayback.h

// Posted when the prepared state changes of an object conforming to the MPMediaPlayback protocol changes.
// This supersedes MPMoviePlayerContentPreloadDidFinishNotification.
FS_EXTERN NSString *const FSMPMediaPlaybackIsPreparedToPlayDidChangeNotification;

// -----------------------------------------------------------------------------
//  MPMoviePlayerController.h
//  Movie Player Notifications

// Posted when the scaling mode changes.
FS_EXTERN NSString* const FSMPMoviePlayerScalingModeDidChangeNotification;

// Posted when movie playback ends or a user exits playback.
FS_EXTERN NSString* const FSMPMoviePlayerPlaybackDidFinishNotification;
FS_EXTERN NSString* const FSMPMoviePlayerPlaybackDidFinishReasonUserInfoKey; // NSNumber (FSMPMovieFinishReason)

// Posted when the playback state changes, either programatically or by the user.
FS_EXTERN NSString* const FSMPMoviePlayerPlaybackStateDidChangeNotification;

// Posted when the network load state changes.
FS_EXTERN NSString* const FSMPMoviePlayerLoadStateDidChangeNotification;

// Posted when the movie player begins or ends playing video via AirPlay.
FS_EXTERN NSString* const FSMPMoviePlayerIsAirPlayVideoActiveDidChangeNotification;

// -----------------------------------------------------------------------------
// Movie Property Notifications

// Calling -prepareToPlay on the movie player will begin determining movie properties asynchronously.
// These notifications are posted when the associated movie property becomes available.
FS_EXTERN NSString* const FSMPMovieNaturalSizeAvailableNotification;

//video's z rotate degrees
FS_EXTERN NSString* const FSMPMovieZRotateAvailableNotification;
FS_EXTERN NSString* const FSMPMovieNoCodecFoundNotification;
// -----------------------------------------------------------------------------
//  Extend Notifications

FS_EXTERN NSString *const FSMPMoviePlayerVideoDecoderOpenNotification;
FS_EXTERN NSString *const FSMPMoviePlayerFirstVideoFrameRenderedNotification;
FS_EXTERN NSString *const FSMPMoviePlayerFirstAudioFrameRenderedNotification;
FS_EXTERN NSString *const FSMPMoviePlayerFirstAudioFrameDecodedNotification;
FS_EXTERN NSString *const FSMPMoviePlayerFirstVideoFrameDecodedNotification;
FS_EXTERN NSString *const FSMPMoviePlayerOpenInputNotification;
FS_EXTERN NSString *const FSMPMoviePlayerFindStreamInfoNotification;
FS_EXTERN NSString *const FSMPMoviePlayerComponentOpenNotification;

FS_EXTERN NSString *const FSMPMoviePlayerDidSeekCompleteNotification;
FS_EXTERN NSString *const FSMPMoviePlayerDidSeekCompleteTargetKey;
FS_EXTERN NSString *const FSMPMoviePlayerDidSeekCompleteErrorKey;
FS_EXTERN NSString *const FSMPMoviePlayerDidAccurateSeekCompleteCurPos;
FS_EXTERN NSString *const FSMPMoviePlayerAccurateSeekCompleteNotification;
FS_EXTERN NSString *const FSMPMoviePlayerSeekAudioStartNotification;
FS_EXTERN NSString *const FSMPMoviePlayerSeekVideoStartNotification;

FS_EXTERN NSString *const FSMPMoviePlayerSelectedStreamDidChangeNotification;
FS_EXTERN NSString *const FSMPMoviePlayerAfterSeekFirstVideoFrameDisplayNotification;
//when received this fatal notifi,need stop player,otherwize read frame and play to end.
FS_EXTERN NSString *const FSMPMoviePlayerVideoDecoderFatalNotification; /*useinfo's code is decoder's err code.*/
FS_EXTERN NSString *const FSMPMoviePlayerPlaybackRecvWarningNotification; /*warning notifi.*/
FS_EXTERN NSString *const FSMPMoviePlayerPlaybackWarningReasonUserInfoKey; /*useinfo's key,value is int.*/
//user info's state key:1 means begin,2 means end.
FS_EXTERN NSString *const FSMoviePlayerHDRAnimationStateChanged;
//select stream failed user info key
FS_EXTERN NSString *const FSMoviePlayerSelectingStreamIDUserInfoKey;
//pre selected stream user info key
FS_EXTERN NSString *const FSMoviePlayerPreSelectingStreamIDUserInfoKey;
//select stream failed err code key
FS_EXTERN NSString *const FSMoviePlayerSelectingStreamErrUserInfoKey;
//select stream failed.
FS_EXTERN NSString *const FSMoviePlayerSelectingStreamDidFailed;
//icy meta changed.
FS_EXTERN NSString *const FSMPMoviePlayerICYMetaChangedNotification;

@end

#pragma mark FSMediaUrlOpenDelegate

// Must equal to the defination in ijkavformat/ijkavformat.h
typedef NS_ENUM(NSInteger, FSMediaEvent) {

    // Notify Events
    FSMediaEvent_WillHttpOpen         = 1,       // attr: url
    FSMediaEvent_DidHttpOpen          = 2,       // attr: url, error, http_code
    FSMediaEvent_WillHttpSeek         = 3,       // attr: url, offset
    FSMediaEvent_DidHttpSeek          = 4,       // attr: url, offset, error, http_code
    // Control Message
    FSMediaCtrl_WillTcpOpen           = 0x20001, // FSMediaUrlOpenData: no args
    FSMediaCtrl_DidTcpOpen            = 0x20002, // FSMediaUrlOpenData: error, family, ip, port, fd
    FSMediaCtrl_WillHttpOpen          = 0x20003, // FSMediaUrlOpenData: url, segmentIndex, retryCounter
    FSMediaCtrl_WillLiveOpen          = 0x20005, // FSMediaUrlOpenData: url, retryCounter
    FSMediaCtrl_WillConcatSegmentOpen = 0x20007, // FSMediaUrlOpenData: url, segmentIndex, retryCounter
};

#define FSMediaEventAttrKey_url            @"url"
#define FSMediaEventAttrKey_host           @"host"
#define FSMediaEventAttrKey_error          @"error"
#define FSMediaEventAttrKey_time_of_event  @"time_of_event"
#define FSMediaEventAttrKey_http_code      @"http_code"
#define FSMediaEventAttrKey_offset         @"offset"
#define FSMediaEventAttrKey_file_size      @"file_size"

// event of FSMediaUrlOpenEvent_xxx
@interface FSMediaUrlOpenData: NSObject

- (id)initWithUrl:(NSString *)url
            event:(FSMediaEvent)event
     segmentIndex:(int)segmentIndex
     retryCounter:(int)retryCounter;

@property(nonatomic, readonly) FSMediaEvent event;
@property(nonatomic, readonly) int segmentIndex;
@property(nonatomic, readonly) int retryCounter;

@property(nonatomic, retain) NSString *url;
@property(nonatomic, assign) int fd;
@property(nonatomic, strong) NSString *msg;
@property(nonatomic) int error; // set a negative value to indicate an error has occured.
@property(nonatomic, getter=isHandled)    BOOL handled;     // auto set to YES if url changed
@property(nonatomic, getter=isUrlChanged) BOOL urlChanged;  // auto set to YES by url changed

@end

@protocol FSMediaUrlOpenDelegate <NSObject>

- (void)willOpenUrl:(FSMediaUrlOpenData*) urlOpenData;

@end

@protocol FSMediaNativeInvokeDelegate <NSObject>

- (int)invoke:(FSMediaEvent)event attributes:(NSDictionary *)attributes;

@end
