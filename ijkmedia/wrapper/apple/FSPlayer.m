/*
 * FSPlayer.m
 *
 * Copyright (c) 2013 Bilibili
 * Copyright (c) 2013 Zhang Rui <bbcallen@gmail.com>
 * Copyright (c) 2019 debugly <qianlongxu@gmail.com>
 *
 * This file is part of FSPlayer.
 *
 * FSPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * FSPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FSPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#import "FSPlayer.h"
#import "FSMetalView.h"
#import "FSSDLHudControl.h"
#import "FSPlayerDef.h"
#import "FSMediaPlayback.h"
#import "FSMediaModule.h"
#import "FSNotificationManager.h"
#import "ijkioapplication.h"
#include "string.h"
#if TARGET_OS_IOS || TARGET_OS_TV
#import "FSAudioKit.h"
#else
#import "FSSDLGLView.h"
#endif

#include "../ijkmedia/ijkplayer/apple/ijkplayer_ios.h"
#include "../ijkmedia/ijkplayer/ijkmeta.h"
#include "../ijkmedia/ijkplayer/ff_ffmsg_queue.h"

static const char *kIJKFFRequiredFFmpegVersion = "n6.1.1-29";

static void (^_logHandler)(FSLogLevel level, NSString *tag, NSString *msg);

// It means you didn't call shutdown if you found this object leaked.
@interface FSWeakHolder : NSObject
@property (nonatomic, weak) id object;
@end

@implementation FSWeakHolder
@end

@interface FSPlayer()

@property (nonatomic, strong) NSURL *contentURL;

@end

@implementation FSPlayer {
    IjkMediaPlayer *_mediaPlayer;
    UIView<FSVideoRenderingProtocol>* _glView;
    FSPlayerMessagePool *_msgPool;

    NSInteger _videoWidth;
    NSInteger _videoHeight;
    NSInteger _sampleAspectRatioNumerator;
    NSInteger _sampleAspectRatioDenominator;
    NSInteger _videoZRotateDegrees;
    BOOL      _seeking;
    NSInteger _bufferingTime;
    NSInteger _bufferingPosition;

    BOOL _keepScreenOnWhilePlaying;
    BOOL _pauseInBackground;
    BOOL _playingBeforeInterruption;

    AVAppAsyncStatistic _asyncStat;
    IjkIOAppCacheStatistic _cacheStat;

    NSTimer *_hudTimer;
    FSSDLHudControl *_hudCtrl;
#if TARGET_OS_IOS
    FSNotificationManager *_notificationManager;
#endif
    int _enableAccurateSeek;
    BOOL _canUpdateAccurateSeek;
}

@synthesize view = _view;
@synthesize duration;
@synthesize playableDuration;
@synthesize bufferingProgress = _bufferingProgress;

@synthesize numberOfBytesTransferred = _numberOfBytesTransferred;

@synthesize isPreparedToPlay = _isPreparedToPlay;
@synthesize playbackState = _playbackState;
@synthesize loadState = _loadState;

@synthesize naturalSize = _naturalSize;
@synthesize scalingMode = _scalingMode;
@synthesize shouldAutoplay = _shouldAutoplay;

@synthesize allowsMediaAirPlay = _allowsMediaAirPlay;
@synthesize airPlayMediaActive = _airPlayMediaActive;

@synthesize isDanmakuMediaAirPlay = _isDanmakuMediaAirPlay;

@synthesize monitor = _monitor;
@synthesize shouldShowHudView           = _shouldShowHudView;
@synthesize isSeekBuffering = _isSeekBuffering;
@synthesize isAudioSync = _isAudioSync;
@synthesize isVideoSync = _isVideoSync;
@synthesize subtitlePreference = _subtitlePreference;

- (void)setScreenOn: (BOOL)on
{
    [FSMediaModule sharedModule].mediaModuleIdleTimerDisabled = on;
    // [UIApplication sharedApplication].idleTimerDisabled = on;
}

- (void)_initWithContent:(NSURL *)aUrl options:(FSOptions *)options glView:(UIView <FSVideoRenderingProtocol> *)glView
{
    // init media resource
    _contentURL = aUrl;
    
    ijkmp_global_init();
    ijkmp_global_set_inject_callback(ijkff_inject_callback);

    [FSPlayer checkIfFFmpegVersionMatch:NO];

    if (options == nil)
        options = [FSOptions optionsByDefault];

    // init fields
    _scalingMode = FSScalingModeAspectFit;
    _shouldAutoplay = YES;
    _canUpdateAccurateSeek = YES;
    
    memset(&_asyncStat, 0, sizeof(_asyncStat));
    memset(&_cacheStat, 0, sizeof(_cacheStat));

    _monitor = [[FSMonitor alloc] init];

    // init player
    _mediaPlayer = ijkmp_ios_create(media_player_msg_loop);
    _msgPool = [[FSPlayerMessagePool alloc] init];
    FSWeakHolder *weakHolder = [FSWeakHolder new];
    weakHolder.object = self;

    ijkmp_set_weak_thiz(_mediaPlayer, (__bridge_retained void *) self);
    ijkmp_set_inject_opaque(_mediaPlayer, (__bridge_retained void *) weakHolder);
    ijkmp_set_ijkio_inject_opaque(_mediaPlayer, (__bridge_retained void *)weakHolder);
    ijkmp_set_option_int(_mediaPlayer, FSMP_OPT_CATEGORY_PLAYER, "start-on-prepared", _shouldAutoplay ? 1 : 0);

    _view = _glView = glView;
    ijkmp_ios_set_glview(_mediaPlayer, glView);
    ijkmp_set_option(_mediaPlayer, FSMP_OPT_CATEGORY_PLAYER, "overlay-format", "fcc-_es2");
    //ijkmp_set_option(_mediaPlayer,FSMP_OPT_CATEGORY_FORMAT,"safe", 0);
    //ijkmp_set_option(_mediaPlayer,FSMP_OPT_CATEGORY_PLAYER,"protocol_whitelist","ffconcat,file,http,https");
    //httpproxy
    const char *default_p_whitelist = "ijkio,ijkhttphook,concat,http,tcp,https,tls,file,bluray,smb2,dvd,rtmp,rtsp,rtp,srtp,udp";
    if (options.protocolWhitelist.length > 0) {
        NSString *whitelist = [[NSString stringWithUTF8String:default_p_whitelist] stringByAppendingFormat:@",%@",options.protocolWhitelist];
        default_p_whitelist = [whitelist UTF8String];
    }
    ijkmp_set_option(_mediaPlayer, FSMP_OPT_CATEGORY_FORMAT, "protocol_whitelist", default_p_whitelist);
    
    _subtitlePreference = ijk_subtitle_default_preference();
    // init hud
    _hudCtrl = [FSSDLHudControl new];

    self.shouldShowHudView = options.showHudView;
    
    [options applyTo:_mediaPlayer];
    
    _pauseInBackground = NO;
    // init extra
    _keepScreenOnWhilePlaying = YES;
    [self setScreenOn:YES];

#if TARGET_OS_IOS
    _notificationManager = [[FSNotificationManager alloc] init];
    // init audio sink
    [[FSAudioKit sharedInstance] setupAudioSession];
    [self registerApplicationObservers];
#endif
}

- (id)initWithContentURL:(NSURL *)aUrl withOptions:(FSOptions *)options
{
    if (aUrl == nil)
        return nil;

    self = [super init];
    if (self) {
        // init video sink
        UIView<FSVideoRenderingProtocol> *glView = nil;
    #if TARGET_OS_IOS || TARGET_OS_TV
        CGRect rect = [[UIScreen mainScreen] bounds];
        rect.origin = CGPointZero;
        glView = [[FSMetalView alloc] initWithFrame:rect];
    #else
        CGRect rect = [[[NSScreen screens] firstObject]frame];
        rect.origin = CGPointZero;
        if (!options.metalRenderer) {
            glView = [[FSSDLGLView alloc] initWithFrame:rect];
        } else {
            if (@available(macOS 10.13, *)) {
                glView = [[FSMetalView alloc] initWithFrame:rect];
            } else {
                glView = [[FSSDLGLView alloc] initWithFrame:rect];
            }
        }
    #endif
        [self _initWithContent:aUrl options:options glView:glView];
    }
    return self;
}

- (id)initWithMoreContent:(NSURL *)aUrl
              withOptions:(FSOptions *)options
               withGLView:(UIView<FSVideoRenderingProtocol> *)glView
{
    if (aUrl == nil)
        return nil;

    self = [super init];
    if (self) {
        // init video sink
        [self _initWithContent:aUrl options:options glView:glView];
    }
    return self;
}

- (void)dealloc
{
//    [self unregisterApplicationObservers];
}

- (void)setShouldAutoplay:(BOOL)shouldAutoplay
{
    _shouldAutoplay = shouldAutoplay;

    if (!_mediaPlayer)
        return;

    ijkmp_set_option_int(_mediaPlayer, FSMP_OPT_CATEGORY_PLAYER, "start-on-prepared", _shouldAutoplay ? 1 : 0);
}

- (BOOL)shouldAutoplay
{
    return _shouldAutoplay;
}

- (void)prepareToPlay
{
    if (!_mediaPlayer)
        return;

    [self setScreenOn:_keepScreenOnWhilePlaying];
    NSString *render = [self.view name];
    [self setHudValue:render forKey:@"v-renderer"];
    NSString *scheme = [[_contentURL scheme] lowercaseString];
    
    if ([_contentURL isFileURL]) {
        [self setHudValue:nil forKey:@"path"];
    } else if ([scheme hasPrefix:@"http"]){
        [self setHudValue:nil forKey:@"scheme"];
        [self setHudValue:nil forKey:@"host"];
        [self setHudValue:nil forKey:@"path"];
        [self setHudValue:nil forKey:@"ip"];
        [self setHudValue:nil forKey:@"tcp-info"];
        [self setHudValue:nil forKey:@"http"];
        [self setHudValue:nil forKey:@"tcp-spd"];
        [self setHudValue:nil forKey:@"t-prepared"];
        [self setHudValue:nil forKey:@"t-render"];
        [self setHudValue:nil forKey:@"t-preroll"];
        [self setHudValue:nil forKey:@"t-http-open"];
        [self setHudValue:nil forKey:@"t-http-seek"];
    } else {
        [self setHudValue:nil forKey:@"scheme"];
        [self setHudValue:nil forKey:@"host"];
        [self setHudValue:nil forKey:@"path"];
        [self setHudValue:nil forKey:@"tcp-spd"];
    }
    
    [self setHudUrl:_contentURL];
    
    //[absoluteString] 遇到中文，不会解码，因此需要 stringByRemovingPercentEncoding
    //[path] 遇到中文，会解码，因此不需要 stringByRemovingPercentEncoding
    //http、smb2 等网络协议，请求时会自定对path百分号编码，所以移除与否不影响
    //bluray: 会自动解码，不存在中文编码/打不开流问题
    
    NSString *filePath = nil;
    
    if ([_contentURL isFileURL]) {
        filePath = [_contentURL path];
    } else {
        filePath = [self.contentURL absoluteString];
    }
    
    //如果是 iso 则使用 bluray:// 协议打开
    if ([@"iso" isEqualToString:[[filePath pathExtension] lowercaseString]]) {
        filePath = [@"bluray://" stringByAppendingString:filePath];
    }

    ijkmp_set_data_source(_mediaPlayer, [filePath UTF8String]);
    ijkmp_set_option_int(_mediaPlayer, FSMP_OPT_CATEGORY_FORMAT, "safe", 0); // for concat demuxer
    ijkmp_set_subtitle_preference(_mediaPlayer, &_subtitlePreference);
    
    _monitor.prepareStartTick = (int64_t)SDL_GetTickHR();
    ijkmp_prepare_async(_mediaPlayer);
}

- (BOOL)loadThenActiveSubtitle:(NSURL *)url
{
    if (!_mediaPlayer || !url)
        return NO;
    NSString *file = [url isFileURL] ? [url path] : [url absoluteString];
    int ret = ijkmp_add_active_external_subtitle(_mediaPlayer, [file UTF8String]);
    return ret == 0;
}

- (BOOL)loadSubtitleOnly:(NSURL *)url
{
    if (!_mediaPlayer || !url)
        return NO;
    NSString *file = [url isFileURL] ? [url path] : [url absoluteString];
    int ret = ijkmp_addOnly_external_subtitle(_mediaPlayer, [file UTF8String]);
    return ret == 0;
}

- (BOOL)loadSubtitlesOnly:(NSArray<NSURL *> *)urlArr
{
    if (!_mediaPlayer || urlArr.count == 0)
        return NO;
    const char *files[512] = {0};
    NSUInteger maxCount = MIN(urlArr.count, 512);
    for (int i = 0; i < maxCount; i++) {
        NSURL *url = [urlArr objectAtIndex:i];
        NSString *filePath = [url isFileURL] ? [url path] : [url absoluteString];
        const char *file = [filePath UTF8String];
        files[i] = file;
    }
    
    int ret = ijkmp_addOnly_external_subtitles(_mediaPlayer, files, (int)maxCount);
    return ret > 0;
}

- (void)play
{
    if (!_mediaPlayer)
        return;

    [self setScreenOn:_keepScreenOnWhilePlaying];

    [self startHudTimer];
    ijkmp_start(_mediaPlayer);
}

- (void)pause
{
    if (!_mediaPlayer)
        return;

//    [self stopHudTimer];
    ijkmp_pause(_mediaPlayer);
}

- (void)stop
{
    if (!_mediaPlayer)
        return;

    [self setScreenOn:NO];
    [self stopHudTimer];
    ijkmp_stop(_mediaPlayer);
}

- (BOOL)isPlaying
{
    if (!_mediaPlayer)
        return NO;

    return ijkmp_is_playing(_mediaPlayer);
}

- (void)setPauseInBackground:(BOOL)pause
{
    _pauseInBackground = pause;
}

inline static int getPlayerOption(FSOptionCategory category)
{
    int mp_category = -1;
    switch (category) {
        case kIJKFFOptionCategoryFormat:
            mp_category = FSMP_OPT_CATEGORY_FORMAT;
            break;
        case kIJKFFOptionCategoryCodec:
            mp_category = FSMP_OPT_CATEGORY_CODEC;
            break;
        case kIJKFFOptionCategorySws:
            mp_category = FSMP_OPT_CATEGORY_SWS;
            break;
        case kIJKFFOptionCategoryPlayer:
            mp_category = FSMP_OPT_CATEGORY_PLAYER;
            break;
        default:
            NSLog(@"unknown option category: %d\n", category);
    }
    return mp_category;
}

- (void)setOptionValue:(NSString *)value
                forKey:(NSString *)key
            ofCategory:(FSOptionCategory)category
{
    assert(_mediaPlayer);
    if (!_mediaPlayer)
        return;

    ijkmp_set_option(_mediaPlayer, getPlayerOption(category), [key UTF8String], [value UTF8String]);
}

- (void)setOptionIntValue:(int64_t)value
                   forKey:(NSString *)key
               ofCategory:(FSOptionCategory)category
{
    assert(_mediaPlayer);
    if (!_mediaPlayer)
        return;

    ijkmp_set_option_int(_mediaPlayer, getPlayerOption(category), [key UTF8String], value);
}

#ifdef __APPLE__
void ffp_apple_log_extra_vprint(int level, const char *tag, const char *fmt, va_list ap)
{
    FSLogLevel curr_lv = [FSPlayer getLogLevel];
    if (level < curr_lv) {
        return;
    }
    
    if (_logHandler) {
        if (fmt) {
            if (0 == strcmp("\n", fmt)) {
                //_logHandler(level, @"", @"\n");
            } else {
                char buffer[1024] = {0};
                vsnprintf(buffer, sizeof(buffer) -1, fmt, ap);
                
                NSString *tagStr = tag ? [[NSString alloc] initWithUTF8String:tag] : @"";
                NSString *msgStr = [[NSString alloc] initWithUTF8String:buffer];
                _logHandler(level, tagStr, msgStr);
            }
        }
    } else {
        if (fmt) {
            if (0 == strcmp("\n", fmt)) {
                vprintf(fmt, ap);
            } else {
                char new_fmt[256];
                snprintf(new_fmt, sizeof(new_fmt), "[%s]%s", tag, fmt);
                vprintf(new_fmt, ap);
            }
        }
    }
}

void ffp_apple_log_extra_print(int level, const char *tag, const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    ffp_apple_log_extra_vprint(level, tag, fmt, args);
    va_end(args);
}
#endif
+ (void)setLogReport:(BOOL)preferLogReport
{
    ijkmp_global_set_log_report(preferLogReport ? 1 : 0);
}

+ (void)setLogLevel:(FSLogLevel)logLevel
{
    ijkmp_global_set_log_level(logLevel);
}

+ (FSLogLevel)getLogLevel
{
    return ijkmp_global_get_log_level();
}

+ (void)setLogHandler:(void (^)(FSLogLevel, NSString *, NSString *))handler
{
    _logHandler = handler;
}

+ (NSDictionary *)supportedDecoders
{
    void *iterate_data = NULL;
    const AVCodec *codec = NULL;
    NSMutableDictionary *codesByType = [NSMutableDictionary dictionary];
    
    while (NULL != (codec = av_codec_iterate(&iterate_data))) {
        NSMutableDictionary *dic = [NSMutableDictionary dictionary];
        if (NULL != codec->name) {
            NSString *name = [[NSString alloc]initWithUTF8String:codec->name];
            [dic setObject:name forKey:@"name"];
        }
        if (NULL != codec->long_name) {
            NSString *longName = [[NSString alloc]initWithUTF8String:codec->long_name];
            [dic setObject:longName forKey:@"longName"];
        }
        [dic setObject:[NSString stringWithFormat:@"%d",codec->id] forKey:@"id"];
        
        if (av_codec_is_encoder(codec)) {
            if (av_codec_is_decoder(codec)) {
                [dic setObject:@"Encoder,Decoder" forKey:@"type"];
            } else {
                [dic setObject:@"Encoder" forKey:@"type"];
            }
        } else if (av_codec_is_decoder(codec)) {
            [dic setObject:@"Decoder" forKey:@"type"];
        }
        
        NSString *typeKey = nil;
        
        if (codec->type == AVMEDIA_TYPE_VIDEO) {
            typeKey = @"Video";
        } else if (codec->type == AVMEDIA_TYPE_AUDIO) {
            typeKey = @"Audio";
        } else {
            typeKey = @"Other";
        }
        
        NSMutableArray *codecArr = [codesByType objectForKey:typeKey];
        
        if (!codecArr) {
            codecArr = [NSMutableArray array];
            [codesByType setObject:codecArr forKey:typeKey];
        }
        [codecArr addObject:dic];
    }
    return [codesByType copy];
}

+ (BOOL)checkIfFFmpegVersionMatch:(BOOL)showAlert;
{
    //n4.0-16-g1c96997 -> n4.0-16
    //not compare last commit sha1,because it will chang after source code apply patches.
    const char *actualVersion = av_version_info();
    char dst[128] = { 0 };
    strcpy(dst, actualVersion);
    if (strrchr(dst, '-') != NULL) {
        *strrchr(dst, '-') = '\0';
    }
    
    const char *expectVersion = kIJKFFRequiredFFmpegVersion;
    if (0 == strcmp(dst, expectVersion)) {
        return YES;
    } else {
        av_log(NULL, AV_LOG_WARNING, "actual ffmpeg: %s,but expect: %s\n", actualVersion, expectVersion);
        return NO;
    }
}

+ (BOOL)checkIfPlayerVersionMatch:(BOOL)showAlert
                          version:(NSString *)version
{
    const char *actualVersion = ijkmp_version();
    const char *expectVersion = version.UTF8String;
    if (0 == strcmp(actualVersion, expectVersion)) {
        return YES;
    } else {
        av_log(NULL, AV_LOG_WARNING, "actual ijkplayer: %s,but expect: %s\n", actualVersion, expectVersion);
        return NO;
    }
}

- (void)shutdown
{
    NSAssert([NSThread isMainThread], @"must on main thread call shutdown");
    if (!_mediaPlayer)
        return;
#if TARGET_OS_IOS
    [self unregisterApplicationObservers];
#endif
    [self setScreenOn:NO];
    [self destroyHud];
    [self performSelectorInBackground:@selector(shutdownWaitStop:) withObject:self];
}

- (void)shutdownWaitStop:(FSPlayer *) mySelf
{
    if (!_mediaPlayer)
        return;

    ijkmp_stop(_mediaPlayer);
    ijkmp_shutdown(_mediaPlayer);

    [self performSelectorOnMainThread:@selector(shutdownClose:) withObject:self waitUntilDone:YES];
}

- (void)shutdownClose:(FSPlayer *) mySelf
{
    if (!_mediaPlayer)
        return;

    _segmentOpenDelegate    = nil;
    _tcpOpenDelegate        = nil;
    _httpOpenDelegate       = nil;
    _liveOpenDelegate       = nil;
    _nativeInvokeDelegate   = nil;

    __unused id weakPlayer = (__bridge_transfer FSPlayer*)ijkmp_set_weak_thiz(_mediaPlayer, NULL);
    __unused id weakHolder = (__bridge_transfer FSWeakHolder*)ijkmp_set_inject_opaque(_mediaPlayer, NULL);
    __unused id weakijkHolder = (__bridge_transfer FSWeakHolder*)ijkmp_set_ijkio_inject_opaque(_mediaPlayer, NULL);

    ijkmp_dec_ref_p(&_mediaPlayer);

    [self didShutdown];
}

- (void)didShutdown
{
}

- (FSPlayerPlaybackState)playbackState
{
    if (!_mediaPlayer)
        return NO;

    FSPlayerPlaybackState mpState = FSPlayerPlaybackStateStopped;
    int state = ijkmp_get_state(_mediaPlayer);
    switch (state) {
        case MP_STATE_STOPPED:
        case MP_STATE_COMPLETED:
        case MP_STATE_ERROR:
        case MP_STATE_END:
            mpState = FSPlayerPlaybackStateStopped;
            break;
        case MP_STATE_IDLE:
        case MP_STATE_INITIALIZED:
        case MP_STATE_ASYNC_PREPARING:
        case MP_STATE_PAUSED:
            mpState = FSPlayerPlaybackStatePaused;
            break;
        case MP_STATE_PREPARED:
        case MP_STATE_STARTED: {
            if (_seeking)
                mpState = FSPlayerPlaybackStateSeekingForward;
            else
                mpState = FSPlayerPlaybackStatePlaying;
            break;
        }
    }
    // FSPlayerPlaybackStatePlaying,
    // FSPlayerPlaybackStatePaused,
    // FSPlayerPlaybackStateStopped,
    // FSPlayerPlaybackStateInterrupted,
    // FSPlayerPlaybackStateSeekingForward,
    // FSPlayerPlaybackStateSeekingBackward
    return mpState;
}

- (void)setCurrentPlaybackTime:(NSTimeInterval)aCurrentPlaybackTime
{
    if (!_mediaPlayer)
        return;

    _seeking = YES;
    _canUpdateAccurateSeek = NO;
    
    [[NSNotificationCenter defaultCenter]
     postNotificationName:FSPlayerPlaybackStateDidChangeNotification
     object:self];

    _bufferingPosition = 0;
    ijkmp_seek_to(_mediaPlayer, aCurrentPlaybackTime * 1000);
}

- (NSTimeInterval)currentPlaybackTime
{
    if (!_mediaPlayer)
        return 0.0f;

    NSTimeInterval ret = ijkmp_get_current_position(_mediaPlayer);
    if (isnan(ret) || isinf(ret))
        return -1;

    return ret / 1000;
}

- (void)setCurrentAudioExtraDelay:(float)delay
{
    ijkmp_set_audio_extra_delay(_mediaPlayer, delay);
}

- (float)currentAudioExtraDelay
{
    return ijkmp_get_audio_extra_delay(_mediaPlayer);
}

- (void)setCurrentSubtitleExtraDelay:(float)delay
{
    ijkmp_set_subtitle_extra_delay(_mediaPlayer, delay);
}

- (float)currentSubtitleExtraDelay
{
    return ijkmp_get_subtitle_extra_delay(_mediaPlayer);
}

- (NSTimeInterval)duration
{
    if (!_mediaPlayer)
        return 0.0f;

    NSTimeInterval ret = ijkmp_get_duration(_mediaPlayer);
    if (isnan(ret) || isinf(ret))
        return -1;

    return ret / 1000;
}

- (NSTimeInterval)playableDuration
{
    if (!_mediaPlayer)
        return 0.0f;

    NSTimeInterval demux_cache = ((NSTimeInterval)ijkmp_get_playable_duration(_mediaPlayer)) / 1000;
    int64_t buf_forwards = _asyncStat.buf_forwards;
    int64_t bit_rate = ijkmp_get_property_int64(_mediaPlayer, FFP_PROP_INT64_BIT_RATE, 0);

    if (buf_forwards > 0 && bit_rate > 0) {
        NSTimeInterval io_cache = ((float)buf_forwards) * 8 / bit_rate;
        demux_cache += io_cache;
    }
    return demux_cache;
}

- (CGSize)naturalSize
{
    return _naturalSize;
}

- (void)changeNaturalSize
{
    CGSize naturalSize = CGSizeZero;
    if (_sampleAspectRatioNumerator > 0 && _sampleAspectRatioDenominator > 0) {
        naturalSize = CGSizeMake(1.0f * _videoWidth * _sampleAspectRatioNumerator / _sampleAspectRatioDenominator, _videoHeight);
    } else {
        naturalSize = CGSizeMake(_videoWidth, _videoHeight);
    }
    
    if (CGSizeEqualToSize(self->_naturalSize, naturalSize)) {
        return;
    }
    
    if (naturalSize.width > 0 && naturalSize.height > 0) {
        [self willChangeValueForKey:@"naturalSize"];
        self->_naturalSize = naturalSize;
        [self didChangeValueForKey:@"naturalSize"];
#if TARGET_OS_IOS || TARGET_OS_TV
        [[NSNotificationCenter defaultCenter]
         postNotificationName:FSPlayerNaturalSizeAvailableNotification
         object:self userInfo:@{@"size":NSStringFromCGSize(self->_naturalSize)}];
#else
        [[NSNotificationCenter defaultCenter]
         postNotificationName:FSPlayerNaturalSizeAvailableNotification
         object:self userInfo:@{@"size":NSStringFromSize(self->_naturalSize)}];
#endif
    }
}

- (NSInteger)videoZRotateDegrees
{
    return _videoZRotateDegrees;
}

- (void)setScalingMode:(FSScalingMode) aScalingMode
{
    FSScalingMode newScalingMode = aScalingMode;
    self.view.scalingMode = aScalingMode;
    _scalingMode = newScalingMode;
}

// deprecated, for MPMoviePlayerController compatiable
- (UIImage *)thumbnailImageAtTime:(NSTimeInterval)playbackTime timeOption:(FSTimeOption)option
{
    return nil;
}

#if TARGET_OS_IOS
- (UIImage *)thumbnailImageAtCurrentTime
{
    if ([_view conformsToProtocol:@protocol(FSVideoRenderingProtocol)]) {
        UIView<FSVideoRenderingProtocol>* glView = (UIView<FSVideoRenderingProtocol>*)_view;
        return [glView snapshot];
    }

    return nil;
}
#endif

- (CGFloat)fpsAtOutput
{
    return _mediaPlayer ? ijkmp_get_property_float(_mediaPlayer, FFP_PROP_FLOAT_VIDEO_OUTPUT_FRAMES_PER_SECOND, .0f) : .0f;
}

#pragma mark FSHudController

- (NSDictionary *)allHudItem
{
    if (!self.shouldShowHudView) {
        [self refreshHudView];
    }
    return [_hudCtrl allHudItem];
}

- (void)setHudValue:(NSString *)value forKey:(NSString *)key
{
    if ([[NSThread currentThread] isMainThread]) {
        [_hudCtrl setHudValue:value forKey:key];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setHudValue:value forKey:key];
        });
    }
}

inline static NSString *formatedDurationMilli(int64_t duration) {
    if (duration == 0) {
        return @"0 sec";
    } else if (labs(duration) >=  1000) {
        return [NSString stringWithFormat:@"%.2f sec", ((float)duration) / 1000];
    } else {
        return [NSString stringWithFormat:@"%ld msec", (long)duration];
    }
}

inline static NSString *formatedDurationBytesAndBitrate(int64_t bytes, int64_t bitRate) {
    if (bitRate <= 0) {
        return @"inf";
    }
    return formatedDurationMilli(((float)bytes) * 8 * 1000 / bitRate);
}

inline static NSString *formatedSize(int64_t bytes) {
    if (bytes < 0) {
        bytes = - bytes;
    }
    if (bytes >= 100 * 1024) {
        return [NSString stringWithFormat:@"%.2f MB", ((float)bytes) / 1000 / 1024];
    } else if (bytes >= 100) {
        return [NSString stringWithFormat:@"%.1f KB", ((float)bytes) / 1000];
    } else {
        return [NSString stringWithFormat:@"%ld B", (long)bytes];
    }
}

inline static NSString *formatedSpeed(int64_t bytes, int64_t elapsed_milli) {
    if (elapsed_milli <= 0) {
        return @"N/A";
    }

    if (bytes <= 0) {
        return @"0";
    }

    float bytes_per_sec = ((float)bytes) * 1000.f /  elapsed_milli;
    if (bytes_per_sec >= 1000 * 1000) {
        return [NSString stringWithFormat:@"%.2f MB/s", ((float)bytes_per_sec) / 1000 / 1000];
    } else if (bytes_per_sec >= 1000) {
        return [NSString stringWithFormat:@"%.1f KB/s", ((float)bytes_per_sec) / 1000];
    } else {
        return [NSString stringWithFormat:@"%ld B/s", (long)bytes_per_sec];
    }
}

- (NSString *)coderNameWithVdecType:(int)vdec
{
    switch (vdec) {
        case FFP_PROPV_DECODER_AVCODEC:
            return [NSString stringWithFormat:@"avcodec %d.%d.%d",
                                 LIBAVCODEC_VERSION_MAJOR,
                                 LIBAVCODEC_VERSION_MINOR,
                                 LIBAVCODEC_VERSION_MICRO];
        case FFP_PROPV_DECODER_AVCODEC_HW:
            return [NSString stringWithFormat:@"avcodec-hw %d.%d.%d",
                                 LIBAVCODEC_VERSION_MAJOR,
                                 LIBAVCODEC_VERSION_MINOR,
                                 LIBAVCODEC_VERSION_MICRO];
        default:
            return @"N/A";
    }
}

- (int64_t)currentDownloadSpeed
{
    return ijkmp_get_property_int64(_mediaPlayer, FFP_PROP_INT64_TCP_SPEED, 0);
}

- (void)refreshHudView
{
    if (_mediaPlayer == nil)
        return;

    [self setHudValue:_monitor.vdecoder forKey:@"vdec"];
    
    [self setHudValue:[NSString stringWithFormat:@"%d / %.2f", [self dropFrameCount], [self dropFrameRate]] forKey:@"drop-frame(c/r)"];
    
    float vdps = ijkmp_get_property_float(_mediaPlayer, FFP_PROP_FLOAT_VIDEO_DECODE_FRAMES_PER_SECOND, .0f);
    float vfps = ijkmp_get_property_float(_mediaPlayer, FFP_PROP_FLOAT_VIDEO_OUTPUT_FRAMES_PER_SECOND, .0f);
    [self setHudValue:[NSString stringWithFormat:@"%.2f / %.2f / %.2f", vdps, vfps, self.fpsInMeta] forKey:@"fps(d/o/f)"];
    
    int sam_remaining = ijkmp_get_frame_cache_remaining(_mediaPlayer, 1);
    int pic_remaining = ijkmp_get_frame_cache_remaining(_mediaPlayer, 2);
    int sub_remaining = ijkmp_get_frame_cache_remaining(_mediaPlayer, 3);
    [self setHudValue:[NSString stringWithFormat:@"%d,%d,%d", sam_remaining, pic_remaining, sub_remaining] forKey:@"frames(a,v,s)"];
    
    int64_t vcacheb = ijkmp_get_property_int64(_mediaPlayer, FFP_PROP_INT64_VIDEO_CACHED_BYTES, 0);
    int64_t acacheb = ijkmp_get_property_int64(_mediaPlayer, FFP_PROP_INT64_AUDIO_CACHED_BYTES, 0);
    int64_t vcached = ijkmp_get_property_int64(_mediaPlayer, FFP_PROP_INT64_VIDEO_CACHED_DURATION, 0);
    int64_t acached = ijkmp_get_property_int64(_mediaPlayer, FFP_PROP_INT64_AUDIO_CACHED_DURATION, 0);
    int64_t vcachep = ijkmp_get_property_int64(_mediaPlayer, FFP_PROP_INT64_VIDEO_CACHED_PACKETS, 0);
    int64_t acachep = ijkmp_get_property_int64(_mediaPlayer, FFP_PROP_INT64_AUDIO_CACHED_PACKETS, 0);
    [self setHudValue:[NSString stringWithFormat:@"%@, %@, %"PRId64" packets",
                          formatedDurationMilli(vcached),
                          formatedSize(vcacheb),
                          vcachep]
                  forKey:@"v-cache"];
    [self setHudValue:[NSString stringWithFormat:@"%@, %@, %"PRId64" packets",
                          formatedDurationMilli(acached),
                          formatedSize(acacheb),
                          acachep]
                  forKey:@"a-cache"];

    float avdelay = ijkmp_get_property_float(_mediaPlayer, FFP_PROP_FLOAT_AVDELAY, .0f);
    float vmdiff  = ijkmp_get_property_float(_mediaPlayer, FFP_PROP_FLOAT_VMDIFF, .0f);
    [self setHudValue:[NSString stringWithFormat:@"%.3f %.3f", avdelay, -vmdiff] forKey:@"delay-avdiff"];

    if ([self.contentURL.absoluteString containsString:@"ijkio:cache"]) {
        int64_t bitRate = ijkmp_get_property_int64(_mediaPlayer, FFP_PROP_INT64_BIT_RATE, 0);
        [self setHudValue:[NSString stringWithFormat:@"-%@, %@",
                             formatedSize(_cacheStat.cache_file_forwards),
                              formatedDurationBytesAndBitrate(_cacheStat.cache_file_forwards, bitRate)] forKey:@"cache-forwards"];
        [self setHudValue:formatedSize(_cacheStat.cache_physical_pos) forKey:@"cache-physical-pos"];
        [self setHudValue:formatedSize(_cacheStat.cache_file_pos) forKey:@"cache-file-pos"];
        [self setHudValue:formatedSize(_cacheStat.cache_count_bytes) forKey:@"cache-bytes"];
        [self setHudValue:[NSString stringWithFormat:@"-%@, %@",
                              formatedSize(_asyncStat.buf_backwards),
                              formatedDurationBytesAndBitrate(_asyncStat.buf_backwards, bitRate)]
                      forKey:@"async-backward"];
        [self setHudValue:[NSString stringWithFormat:@"+%@, %@",
                              formatedSize(_asyncStat.buf_forwards),
                              formatedDurationBytesAndBitrate(_asyncStat.buf_forwards, bitRate)]
                      forKey:@"async-forward"];
    }
    
    if (self.monitor.httpUrl) {
        [self setHudValue:formatedDurationMilli(_monitor.prepareLatency) forKey:@"t-prepared"];
        [self setHudValue:formatedDurationMilli(_monitor.firstVideoFrameLatency) forKey:@"t-render"];
        [self setHudValue:formatedDurationMilli(_monitor.lastPrerollDuration) forKey:@"t-preroll"];
        [self setHudValue:[NSString stringWithFormat:@"%@ / %d",
                           formatedDurationMilli(_monitor.lastHttpOpenDuration),
                           _monitor.httpOpenCount]
                   forKey:@"t-http-open"];
        [self setHudValue:[NSString stringWithFormat:@"%@ / %d",
                           formatedDurationMilli(_monitor.lastHttpSeekDuration),
                           _monitor.httpSeekCount]
                   forKey:@"t-http-seek"];
    }
    
    int64_t tcpSpeed = [self currentDownloadSpeed];
    [self setHudValue:[NSString stringWithFormat:@"%@", formatedSpeed(tcpSpeed, 1000)]
               forKey:@"tcp-spd"];
}

- (void)startHudTimer
{
    if (!_shouldShowHudView)
        return;

    if (_hudTimer != nil)
        return;

    if ([[NSThread currentThread] isMainThread]) {
        UIView *hudView = [_hudCtrl contentView];
        [hudView setHidden:NO];
        CGRect rect = self.view.bounds;
#if TARGET_OS_IOS || TARGET_OS_TV
        hudView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleLeftMargin;
        CGFloat screenWidth = [[UIScreen mainScreen]bounds].size.width;
#if TARGET_OS_TV
        rect.size.width = MIN(screenWidth / 3.0, 600);
#else
        rect.size.width = MIN(screenWidth / 3.0, 350);
#endif
        
#else
        hudView.autoresizingMask = NSViewHeightSizable | NSViewMinXMargin | NSViewMinYMargin | NSViewMaxYMargin;
        NSScreen *screen = self.view.window.screen;
        if (!screen) {
            screen = [[NSScreen screens] firstObject];
        }
        CGFloat screenWidth = [screen frame].size.width;
        rect.size.width = MIN(screenWidth / 3.0, 350);
#endif
        rect.origin.x = CGRectGetWidth(self.view.bounds) - rect.size.width;
        hudView.frame = rect;
        [self.view addSubview:hudView];
        
        _hudTimer = [NSTimer scheduledTimerWithTimeInterval:.5f
                                                     target:self
                                                   selector:@selector(refreshHudView)
                                                   userInfo:nil
                                                    repeats:YES];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startHudTimer];
        });
    }
}

- (void)stopHudTimer
{
    if (_hudTimer == nil)
        return;

    if ([[NSThread currentThread] isMainThread]) {
        UIView *hudView = [_hudCtrl contentView];
        [hudView setHidden:YES];
        [_hudTimer invalidate];
        _hudTimer = nil;
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stopHudTimer];
        });
    }
}

- (void)destroyHud
{
    if ([[NSThread currentThread] isMainThread]) {
        [_hudCtrl destroyContentView];
        [_hudTimer invalidate];
        _hudTimer = nil;
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self destroyHud];
        });
    }
}

- (void)setShouldShowHudView:(BOOL)shouldShowHudView
{
    if (shouldShowHudView == _shouldShowHudView) {
        return;
    }
    _shouldShowHudView = shouldShowHudView;
    if (shouldShowHudView)
        [self startHudTimer];
    else
        [self stopHudTimer];
}

- (void)setAudioSamplesCallback:(void (^)(int16_t *, int, int, int))audioSamplesCallback
{
    _audioSamplesCallback = audioSamplesCallback;

    if (audioSamplesCallback) {
        ijkmp_set_audio_sample_observer(_mediaPlayer, ijkff_audio_samples_callback);
    } else {
        ijkmp_set_audio_sample_observer(_mediaPlayer, NULL);
    }
}

- (void)enableAccurateSeek:(BOOL)open
{
    if (_canUpdateAccurateSeek) {
        _enableAccurateSeek = 0;
        ijkmp_set_enable_accurate_seek(_mediaPlayer, open);
    } else {
        //record it
        _enableAccurateSeek = open ? 1 : 2;
    }
}

- (void)stepToNextFrame
{
    ijkmp_step_to_next_frame(_mediaPlayer);
}

- (BOOL)shouldShowHudView
{
    return _shouldShowHudView;
}

- (void)setPlaybackRate:(float)playbackRate
{
    if (!_mediaPlayer)
        return;

    return ijkmp_set_playback_rate(_mediaPlayer, playbackRate);
}

- (float)playbackRate
{
    if (!_mediaPlayer)
        return 0.0f;

    return ijkmp_get_property_float(_mediaPlayer, FFP_PROP_FLOAT_PLAYBACK_RATE, 0.0f);
}

- (void)setPlaybackVolume:(float)volume
{
    if (!_mediaPlayer)
        return;
    return ijkmp_set_playback_volume(_mediaPlayer, volume);
}

- (float)playbackVolume
{
    if (!_mediaPlayer)
        return 0.0f;
    return ijkmp_get_property_float(_mediaPlayer, FFP_PROP_FLOAT_PLAYBACK_VOLUME, 1.0f);
}

- (int64_t)getFileSize
{
    if (!_mediaPlayer)
        return 0;
    return ijkmp_get_property_int64(_mediaPlayer, FFP_PROP_INT64_LOGICAL_FILE_SIZE, 0);
}

- (int64_t)trafficStatistic
{
    if (!_mediaPlayer)
        return 0;
    return ijkmp_get_property_int64(_mediaPlayer, FFP_PROP_INT64_TRAFFIC_STATISTIC_BYTE_COUNT, 0);
}

- (float)dropFrameRate
{
    if (!_mediaPlayer)
        return 0;
    return ijkmp_get_property_float(_mediaPlayer, FFP_PROP_FLOAT_DROP_FRAME_RATE, 0.0f);
}

- (int)dropFrameCount
{
    if (!_mediaPlayer)
        return 0;
    return (int)ijkmp_get_property_int64(_mediaPlayer, FFP_PROP_FLOAT_DROP_FRAME_COUNT, 0);
}

inline static void fillMetaInternal(NSMutableDictionary *meta, IjkMediaMeta *rawMeta, const char *name, NSString *defaultValue)
{
    if (!meta || !rawMeta || !name)
        return;

    NSString *key = [NSString stringWithUTF8String:name];
    const char *value = ijkmeta_get_string_l(rawMeta, name);

    NSString *str = nil;
    if (value && strlen(value) > 0) {
        str = [NSString stringWithUTF8String:value];
        if (!str) {
            //"\xce޼\xab\xb5\xe7Ӱ-bbs.wujidy.com" is nil !!
            //try gbk encoding.
            NSStringEncoding gbkEncoding = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
            NSData *data = [[NSData alloc]initWithBytes:value length:strlen(value)];
            //无极电影-bbs.wujidy.com
            str = [[NSString alloc]initWithData:data encoding:gbkEncoding];
        }
        if (str) {
            [meta setObject:str forKey:key];
        } else {
            NSLog(@"unkonwn encoding for meta %s",name);
        }
    } else if (defaultValue) {
        [meta setObject:defaultValue forKey:key];
    } else {
        [meta removeObjectForKey:key];
    }
}

- (void)updateICYMeta:(IjkMediaMeta*)rawMeta
{
    if (!rawMeta) {
        return;
    }
    ijkmeta_lock(rawMeta);
    NSMutableDictionary *newMediaMeta = [[NSMutableDictionary alloc] init];
    fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ICY_BR, nil);
    fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ICY_DESC, nil);
    fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ICY_GENRE, nil);
    fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ICY_NAME, nil);
    fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ICY_PUB, nil);
    fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ICY_URL, nil);
    fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ICY_ST, nil);
    fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ICY_SU, nil);
    
    NSMutableDictionary *dic = [NSMutableDictionary dictionaryWithDictionary:_monitor.mediaMeta];
    [dic addEntriesFromDictionary:newMediaMeta];
    _monitor.mediaMeta = [dic copy];
    ijkmeta_unlock(rawMeta);
}

- (void) traverseIJKMetaData:(IjkMediaMeta*)rawMeta
{
    if (rawMeta) {
        ijkmeta_lock(rawMeta);

        NSMutableDictionary *newMediaMeta = [[NSMutableDictionary alloc] init];

        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_FORMAT, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_DURATION_US, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_START_US, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_BITRATE, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ARTIST, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ALBUM, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_TYER, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ENCODER, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_MINOR_VER, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_COMPATIBLE_BRANDS, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_MAJOR_BRAND, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_LYRICS, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ICY_BR, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ICY_DESC, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ICY_GENRE, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ICY_NAME, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ICY_PUB, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ICY_URL, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ICY_ST, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_ICY_SU, nil);        
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_VIDEO_STREAM, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_AUDIO_STREAM, nil);
        fillMetaInternal(newMediaMeta, rawMeta, FSM_KEY_TIMEDTEXT_STREAM, nil);
        
        int64_t video_stream = ijkmeta_get_int64_l(rawMeta, FSM_KEY_VIDEO_STREAM, -1);
        int64_t audio_stream = ijkmeta_get_int64_l(rawMeta, FSM_KEY_AUDIO_STREAM, -1);
        int64_t subtitle_stream = ijkmeta_get_int64_l(rawMeta, FSM_KEY_TIMEDTEXT_STREAM, -1);
        if (-1 == video_stream) {
            _monitor.videoMeta = nil;
        }
        if (-1 == audio_stream) {
            _monitor.audioMeta = nil;
        }
        if (-1 == subtitle_stream) {
            _monitor.subtitleMeta = nil;
        }
        
        NSMutableArray *streams = [[NSMutableArray alloc] init];

        size_t count = ijkmeta_get_children_count_l(rawMeta);
        for(size_t i = 0; i < count; ++i) {
            IjkMediaMeta *streamRawMeta = ijkmeta_get_child_l(rawMeta, i);
            NSMutableDictionary *streamMeta = [[NSMutableDictionary alloc] init];

            if (streamRawMeta) {
                fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_TYPE, FS_VAL_TYPE__UNKNOWN);
                const char *type = ijkmeta_get_string_l(streamRawMeta, FSM_KEY_TYPE);
                if (type) {
                    fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_CODEC_NAME, nil);
                    fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_CODEC_PROFILE, nil);
                    fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_CODEC_LONG_NAME, nil);
                    fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_BITRATE, nil);
                    fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_STREAM_IDX, nil);
                    if (0 == strcmp(type, FSM_VAL_TYPE__VIDEO)) {
                        fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_WIDTH, nil);
                        fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_HEIGHT, nil);
                        fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_FPS_NUM, nil);
                        fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_FPS_DEN, nil);
                        fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_TBR_NUM, nil);
                        fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_TBR_DEN, nil);
                        fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_SAR_NUM, nil);
                        fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_SAR_DEN, nil);

                        if (video_stream == i) {
                            _monitor.videoMeta = streamMeta;

                            int64_t fps_num = ijkmeta_get_int64_l(streamRawMeta, FSM_KEY_FPS_NUM, 0);
                            int64_t fps_den = ijkmeta_get_int64_l(streamRawMeta, FSM_KEY_FPS_DEN, 0);
                            if (fps_num > 0 && fps_den > 0) {
                                _fpsInMeta = ((CGFloat)(fps_num)) / fps_den;
                            }
                        }

                    } else if (0 == strcmp(type, FSM_VAL_TYPE__AUDIO)) {
                        fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_SAMPLE_RATE, nil);
                        fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_LANGUAGE, nil);
                        fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_DESCRIBE, nil);
                        fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_TITLE, nil);
                        if (audio_stream == i) {
                            _monitor.audioMeta = streamMeta;
                        }
                    } else if (0 == strcmp(type, FSM_VAL_TYPE__TIMEDTEXT)) {
                        fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_LANGUAGE, nil);
                        fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_TITLE, nil);
                        fillMetaInternal(streamMeta, streamRawMeta, FSM_KEY_EX_SUBTITLE_URL, nil);
                        if (subtitle_stream == i) {
                            _monitor.subtitleMeta = streamMeta;
                        }
                    } else if (0 == strcmp(type, FSM_VAL_TYPE__CHAPTER)) {
                        NSMutableArray *chapterMetaArr = [NSMutableArray array];
                        size_t count = ijkmeta_get_children_count_l(streamRawMeta);
                        for (size_t i = 0; i < count; ++i) {
                            IjkMediaMeta *chapterRawMeta = ijkmeta_get_child_l(streamRawMeta, i);
                            NSMutableDictionary *chapterMeta = [[NSMutableDictionary alloc] init];
                            fillMetaInternal(chapterMeta, chapterRawMeta, FSM_META_KEY_ID, nil);
                            fillMetaInternal(chapterMeta, chapterRawMeta, FSM_META_KEY_START, nil);
                            fillMetaInternal(chapterMeta, chapterRawMeta, FSM_META_KEY_END, nil);
                            //fill title meta only,expand other later
                            fillMetaInternal(chapterMeta, chapterRawMeta, FSM_META_KEY_TITLE, nil);
                            [chapterMetaArr addObject:chapterMeta];
                        }
                        _monitor.chapterMetaArr = chapterMetaArr.count > 0 ? chapterMetaArr : nil;
                    }
                }
            }

            [streams addObject:streamMeta];
        }

        [newMediaMeta setObject:streams forKey:FS_KEY_STREAMS];

        ijkmeta_unlock(rawMeta);
        _monitor.mediaMeta = newMediaMeta;
    }
}

- (void)updateMonitor4VideoDecoder:(int64_t)vdec
{
    _monitor.vdecoder = [self coderNameWithVdecType:(int)vdec];
}

- (NSString *)averrToString:(int)errnum
{
    char errbuf[128] = { '\0' };
    const char *errbuf_ptr = errbuf;

    if (av_strerror(errnum, errbuf, sizeof(errbuf)) < 0) {
        errbuf_ptr = strerror(AVUNERROR(errnum));
    }
    return [[NSString alloc] initWithUTF8String:errbuf];
}

- (void)postEvent: (FSPlayerMessage *)msg
{
    if (!msg)
        return;

    AVMessage *avmsg = msg.msg;
    switch (avmsg->what) {
        case FFP_MSG_FLUSH:
            break;
        case FFP_MSG_WARNING: {
            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerRecvWarningNotification
             object:self userInfo:@{FSPlayerWarningReasonUserInfoKey: @(avmsg->arg1)}];
        }
            break;
        case FFP_MSG_ERROR: {
            [self setScreenOn:NO];

            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerPlaybackStateDidChangeNotification
             object:self];
            
            [[NSNotificationCenter defaultCenter]
                postNotificationName:FSPlayerDidFinishNotification
                object:self
                userInfo:@{
                    FSPlayerDidFinishReasonUserInfoKey: @(FSFinishReasonPlaybackError),
                    @"msg":[self averrToString:avmsg->arg1],@"code": @(avmsg->arg1)}];
            break;
        }
        case FFP_MSG_SELECTED_STREAM_CHANGED:  {//stream changed msg
            IjkMediaMeta *rawMeta = ijkmp_get_meta_l(_mediaPlayer);
            [self traverseIJKMetaData:rawMeta];
            [[NSNotificationCenter defaultCenter] postNotificationName:FSPlayerSelectedStreamDidChangeNotification object:self];
            break;
        }
        case FFP_MSG_SELECTING_STREAM_FAILED:  {//select stream failed
            int *code = avmsg->obj;
            [[NSNotificationCenter defaultCenter] postNotificationName:FSPlayerSelectingStreamDidFailed object:self userInfo:@{FSPlayerSelectingStreamIDUserInfoKey : @(avmsg->arg1),FSPlayerPreSelectingStreamIDUserInfoKey : @(avmsg->arg2), FSPlayerSelectingStreamErrUserInfoKey : @(*code)}];
            break;
        }
        case FFP_MSG_PREPARED: {
            _monitor.prepareLatency = (int64_t)SDL_GetTickHR() - _monitor.prepareStartTick;
            //prepared not send,beacuse FFP_MSG_VIDEO_DECODER_OPEN event already send
            //int64_t vdec = ijkmp_get_property_int64(_mediaPlayer, FFP_PROP_INT64_VIDEO_DECODER, FFP_PROPV_DECODER_UNKNOWN);
            //[self updateMonitor4VideoDecoder:vdec];

            IjkMediaMeta *rawMeta = ijkmp_get_meta_l(_mediaPlayer);
            [self traverseIJKMetaData:rawMeta];
            
            ijkmp_set_playback_rate(_mediaPlayer, [self playbackRate]);
            ijkmp_set_playback_volume(_mediaPlayer, [self playbackVolume]);

            [self startHudTimer];
            _isPreparedToPlay = YES;

            [[NSNotificationCenter defaultCenter] postNotificationName:FSPlayerIsPreparedToPlayNotification object:self];
            _loadState = FSPlayerLoadStatePlayable | FSPlayerLoadStatePlaythroughOK;

            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerLoadStateDidChangeNotification
             object:self];

            break;
        }
        case FFP_MSG_COMPLETED: {

            [self setScreenOn:NO];

            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerPlaybackStateDidChangeNotification
             object:self];

            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerDidFinishNotification
             object:self
             userInfo:@{FSPlayerDidFinishReasonUserInfoKey: @(FSFinishReasonPlaybackEnded)}];
            break;
        }
        case FFP_MSG_VIDEO_SIZE_CHANGED:
            if (avmsg->arg1 > 0)
                _videoWidth = avmsg->arg1;
            if (avmsg->arg2 > 0)
                _videoHeight = avmsg->arg2;
            [self changeNaturalSize];
            break;
        case FFP_MSG_SAR_CHANGED:
            if (avmsg->arg1 > 0)
                _sampleAspectRatioNumerator = avmsg->arg1;
            if (avmsg->arg2 > 0)
                _sampleAspectRatioDenominator = avmsg->arg2;
            [self changeNaturalSize];
            break;
        case FFP_MSG_BUFFERING_START: {
            _monitor.lastPrerollStartTick = (int64_t)SDL_GetTickHR();

            _loadState = FSPlayerLoadStateStalled;
            _isSeekBuffering = avmsg->arg1;

            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerLoadStateDidChangeNotification
             object:self];
            _isSeekBuffering = 0;
            break;
        }
        case FFP_MSG_BUFFERING_END: {
            _monitor.lastPrerollDuration = (int64_t)SDL_GetTickHR() - _monitor.lastPrerollStartTick;

            _loadState = FSPlayerLoadStatePlayable | FSPlayerLoadStatePlaythroughOK;
            _isSeekBuffering = avmsg->arg1;

            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerLoadStateDidChangeNotification
             object:self];
            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerPlaybackStateDidChangeNotification
             object:self];
            _isSeekBuffering = 0;
            break;
        }
        case FFP_MSG_BUFFERING_UPDATE:
            _bufferingPosition = avmsg->arg1;
            _bufferingProgress = avmsg->arg2;
            // NSLog(@"FFP_MSG_BUFFERING_UPDATE: %d, %%%d\n", _bufferingPosition, _bufferingProgress);
            break;
        case FFP_MSG_BUFFERING_BYTES_UPDATE:
            // NSLog(@"FFP_MSG_BUFFERING_BYTES_UPDATE: %d\n", avmsg->arg1);
            break;
        case FFP_MSG_BUFFERING_TIME_UPDATE:
            _bufferingTime       = avmsg->arg1;
            // NSLog(@"FFP_MSG_BUFFERING_TIME_UPDATE: %d\n", avmsg->arg1);
            break;
        case FFP_MSG_PLAYBACK_STATE_CHANGED:
            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerPlaybackStateDidChangeNotification
             object:self];
            break;
        case FFP_MSG_SEEK_COMPLETE: {
            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerDidSeekCompleteNotification
             object:self
             userInfo:@{FSPlayerDidSeekCompleteTargetKey: @(avmsg->arg1),
                        FSPlayerDidSeekCompleteErrorKey: @(avmsg->arg2)}];
            _seeking = NO;
            break;
        }
        case FFP_MSG_VIDEO_DECODER_OPEN: {
            [self updateMonitor4VideoDecoder:avmsg->arg1];
            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerVideoDecoderOpenNotification
             object:self];
            break;
        }
        case FFP_MSG_VIDEO_RENDERING_START: {
            _monitor.firstVideoFrameLatency = (int64_t)SDL_GetTickHR() - _monitor.prepareStartTick;
            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerFirstVideoFrameRenderedNotification
             object:self];
            break;
        }
        case FFP_MSG_AUDIO_RENDERING_START: {
            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerFirstAudioFrameRenderedNotification
             object:self];
            break;
        }
        case FFP_MSG_AUDIO_DECODED_START: {
            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerFirstAudioFrameDecodedNotification
             object:self];
            break;
        }
        case FFP_MSG_VIDEO_DECODED_START: {
            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerFirstVideoFrameDecodedNotification
             object:self];
            break;
        }
        case FFP_MSG_OPEN_INPUT: {
            _monitor.openInputLatency = (int64_t)SDL_GetTickHR() - _monitor.prepareStartTick;
            const char *name = avmsg->obj;
            NSString *str = nil;
            if (name) {
                str = [[NSString alloc] initWithUTF8String:name];
            }
            if (!str) {
                str = @"";
            }
            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerOpenInputNotification
             object:self
             userInfo:@{@"name": str}];
            break;
        }
        case FFP_MSG_FIND_STREAM_INFO: {
            _monitor.findStreamInfoLatency = (int64_t)SDL_GetTickHR() - _monitor.prepareStartTick;
            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerFindStreamInfoNotification
             object:self];
            break;
        }
        case FFP_MSG_COMPONENT_OPEN: {
            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerComponentOpenNotification
             object:self];
            break;
        }
        case FFP_MSG_ACCURATE_SEEK_COMPLETE: {
            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerAccurateSeekCompleteNotification
             object:self
             userInfo:@{FSPlayerDidAccurateSeekCompleteCurPos: @(avmsg->arg1)}];
            break;
        }
        case FFP_MSG_VIDEO_SEEK_RENDERING_START: {
            _isVideoSync = avmsg->arg1;
            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerSeekVideoStartNotification
             object:self];
            _isVideoSync = 0;
            break;
        }
        case FFP_MSG_AUDIO_SEEK_RENDERING_START: {
            _isAudioSync = avmsg->arg1;
            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerSeekAudioStartNotification
             object:self];
            _isAudioSync = 0;
            break;
        }
        case FFP_MSG_VIDEO_Z_ROTATE_DEGREE:
            if (_videoZRotateDegrees != avmsg->arg1) {
                _videoZRotateDegrees = avmsg->arg1;
                
                [[NSNotificationCenter defaultCenter]
                         postNotificationName:FSPlayerZRotateAvailableNotification
                         object:self userInfo:@{@"degrees":@(_videoZRotateDegrees)}];
            }
            break;
        case FFP_MSG_NO_CODEC_FOUND: {
            NSString *name = [NSString stringWithCString:avcodec_get_name(avmsg->arg1) encoding:NSUTF8StringEncoding];
            [[NSNotificationCenter defaultCenter]
                     postNotificationName:FSPlayerNoCodecFoundNotification
             object:self userInfo:@{@"codecName":name}];
            break;
        }
        case FFP_MSG_AFTER_SEEK_FIRST_FRAME: {
            int du = avmsg->arg1;
            if (_enableAccurateSeek > 0) {
                ijkmp_set_enable_accurate_seek(_mediaPlayer, _enableAccurateSeek == 1);
                _enableAccurateSeek = 0;
            }
            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerAfterSeekFirstVideoFrameDisplayNotification
             object:self userInfo:@{@"du" : @(du)}];
            _canUpdateAccurateSeek = YES;
            break;
        }
        case FFP_MSG_VIDEO_DECODER_FATAL: {
            int code = avmsg->arg1;
            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerVideoDecoderFatalNotification
             object:self userInfo:@{@"code" : @(code),@"msg" : [self averrToString:code]}];
            break;
        }
        case FFP_MSG_ICY_META_CHANGED: {
            IjkMediaMeta *rawMeta = ijkmp_get_meta_l(_mediaPlayer);
            [self updateICYMeta:rawMeta];
            [[NSNotificationCenter defaultCenter]
             postNotificationName:FSPlayerICYMetaChangedNotification
             object:self userInfo:nil];
            break;
        }
        default:
            // NSLog(@"unknown FFP_MSG_xxx(%d)\n", avmsg->what);
            break;
    }

    [_msgPool recycle:msg];
}

- (FSPlayerMessage *) obtainMessage {
    return [_msgPool obtain];
}

inline static FSPlayer *ffplayerRetain(void *arg) {
    return (__bridge_transfer FSPlayer *) arg;
}

static int media_player_msg_loop(void* arg)
{
    @autoreleasepool {
        IjkMediaPlayer *mp = (IjkMediaPlayer*)arg;
        __weak FSPlayer *ffpController = ffplayerRetain(ijkmp_set_weak_thiz(mp, NULL));
        while (ffpController) {
            @autoreleasepool {
                FSPlayerMessage *msg = [ffpController obtainMessage];
                if (!msg)
                    break;

                int retval = ijkmp_get_msg(mp, msg.msg, 1);
                if (retval < 0)
                    break;

                // block-get should never return 0
                assert(retval > 0);
                [ffpController performSelectorOnMainThread:@selector(postEvent:) withObject:msg waitUntilDone:NO];
            }
        }

        // retained in prepare_async, before SDL_CreateThreadEx
        ijkmp_dec_ref_p(&mp);
        return 0;
    }
}

- (void)setHudUrl:(NSURL *)url
{
    if ([[NSThread currentThread] isMainThread]) {
        if (![url.scheme isEqualToString:@"file"]) {
            [self setHudValue:url.scheme forKey:@"scheme"];
            [self setHudValue:url.host   forKey:@"host"];
        }
        [self setHudValue:url.path   forKey:@"path"];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setHudUrl:url];
        });
    }
}

#pragma mark av_format_control_message

static int onInjectIOControl(FSPlayer *mpc, id<FSMediaUrlOpenDelegate> delegate, int type, void *data, size_t data_size)
{
    AVAppIOControl *realData = data;
    assert(realData);
    assert(sizeof(AVAppIOControl) == data_size);
    realData->is_handled     = NO;
    realData->is_url_changed = NO;

    if (delegate == nil)
        return 0;

    NSString *urlString = [NSString stringWithUTF8String:realData->url];

    FSMediaUrlOpenData *openData =
    [[FSMediaUrlOpenData alloc] initWithUrl:urlString
                                       event:(FSMediaEvent)type
                                segmentIndex:realData->segment_index
                                retryCounter:realData->retry_counter];

    [delegate willOpenUrl:openData];
    if (openData.error < 0)
        return -1;

    if (openData.isHandled) {
        realData->is_handled = YES;
        if (openData.isUrlChanged && openData.url != nil) {
            realData->is_url_changed = YES;
            const char *newUrlUTF8 = [openData.url UTF8String];
            strlcpy(realData->url, newUrlUTF8, sizeof(realData->url));
            realData->url[sizeof(realData->url) - 1] = 0;
        }
    }
    
    return 0;
}

static int onInjectTcpIOControl(FSPlayer *mpc, id<FSMediaUrlOpenDelegate> delegate, int type, void *data, size_t data_size)
{
    AVAppTcpIOControl *realData = data;
    assert(realData);
    assert(sizeof(AVAppTcpIOControl) == data_size);

    switch (type) {
        case FSMediaCtrl_WillTcpOpen:

            break;
        case FSMediaCtrl_DidTcpOpen:
            mpc->_monitor.tcpError = realData->error;
            mpc->_monitor.remoteIp = [NSString stringWithUTF8String:realData->ip];
            [mpc setHudValue: mpc->_monitor.remoteIp forKey:@"ip"];
            break;
        default:
            assert(!"unexcepted type for tcp io control");
            break;
    }

    if (delegate == nil) {
        [mpc setHudValue: [NSString stringWithFormat:@"fd:%d", realData->fd] forKey:@"tcp-info"];
        return 0;
    }

    NSString *urlString = [NSString stringWithUTF8String:realData->ip];

    FSMediaUrlOpenData *openData =
    [[FSMediaUrlOpenData alloc] initWithUrl:urlString
                                       event:(FSMediaEvent)type
                                segmentIndex:0
                                retryCounter:0];
    openData.fd = realData->fd;

    [delegate willOpenUrl:openData];
    if (openData.error < 0)
        return -1;
    [mpc setHudValue: [NSString stringWithFormat:@"fd:%d %@", openData.fd, openData.msg?:@"unknown"] forKey:@"tcp-info"];
    return 0;
}

static int onInjectAsyncStatistic(FSPlayer *mpc, int type, void *data, size_t data_size)
{
    AVAppAsyncStatistic *realData = data;
    assert(realData);
    assert(sizeof(AVAppAsyncStatistic) == data_size);

    mpc->_asyncStat = *realData;
    return 0;
}

static int onInectIJKIOStatistic(FSPlayer *mpc, int type, void *data, size_t data_size)
{
    IjkIOAppCacheStatistic *realData = data;
    assert(realData);
    assert(sizeof(IjkIOAppCacheStatistic) == data_size);

    mpc->_cacheStat = *realData;
    return 0;
}

static int64_t calculateElapsed(int64_t begin, int64_t end)
{
    if (begin <= 0)
        return -1;

    if (end < begin)
        return -1;

    return end - begin;
}

static int onInjectOnHttpEvent(FSPlayer *mpc, int type, void *data, size_t data_size)
{
    AVAppHttpEvent *realData = data;
    assert(realData);
    assert(sizeof(AVAppHttpEvent) == data_size);

    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    NSURL        *nsurl   = nil;
    FSMonitor *monitor = mpc->_monitor;
    NSString     *url  = monitor.httpUrl;
    NSString     *host = monitor.httpHost;
    int64_t       elapsed = 0;

    id<FSMediaNativeInvokeDelegate> delegate = mpc.nativeInvokeDelegate;

    switch (type) {
        case AVAPP_EVENT_WILL_HTTP_OPEN:
            url   = [NSString stringWithUTF8String:realData->url];
            nsurl = [NSURL URLWithString:url];
            host  = nsurl.host;

            monitor.httpUrl      = url;
            monitor.httpHost     = host;
            monitor.httpOpenTick = SDL_GetTickHR();
            [mpc setHudUrl:nsurl];

            if (delegate != nil) {
                dict[FSMediaEventAttrKey_host]         = host ?: @"";
                dict[FSMediaEventAttrKey_url]          = monitor.httpUrl ?: @"";
                [delegate invoke:type attributes:dict];
            }
            break;
        case AVAPP_EVENT_DID_HTTP_OPEN:
            elapsed = calculateElapsed(monitor.httpOpenTick, SDL_GetTickHR());
            monitor.httpError = realData->error;
            monitor.httpCode  = realData->http_code;
            monitor.filesize  = realData->filesize;
            monitor.httpOpenCount++;
            monitor.httpOpenTick = 0;
            monitor.lastHttpOpenDuration = elapsed;
            [mpc setHudValue:@(realData->http_code).stringValue forKey:@"http"];

            if (delegate != nil) {
                dict[FSMediaEventAttrKey_time_of_event]    = @(elapsed).stringValue;
                dict[FSMediaEventAttrKey_url]              = monitor.httpUrl ?: @"";
                dict[FSMediaEventAttrKey_host]             = host ?: @"";
                dict[FSMediaEventAttrKey_error]            = @(realData->error).stringValue;
                dict[FSMediaEventAttrKey_http_code]        = @(realData->http_code).stringValue;
                dict[FSMediaEventAttrKey_file_size]        = @(realData->filesize).stringValue;
                [delegate invoke:type attributes:dict];
            }
            break;
        case AVAPP_EVENT_WILL_HTTP_SEEK:
            monitor.httpSeekTick = SDL_GetTickHR();

            if (delegate != nil) {
                dict[FSMediaEventAttrKey_host]         = host ?: @"";
                dict[FSMediaEventAttrKey_offset]       = @(realData->offset).stringValue;
                [delegate invoke:type attributes:dict];
            }
            break;
        case AVAPP_EVENT_DID_HTTP_SEEK:
            elapsed = calculateElapsed(monitor.httpSeekTick, SDL_GetTickHR());
            monitor.httpError = realData->error;
            monitor.httpCode  = realData->http_code;
            monitor.httpSeekCount++;
            monitor.httpSeekTick = 0;
            monitor.lastHttpSeekDuration = elapsed;
            [mpc setHudValue:@(realData->http_code).stringValue forKey:@"http"];

            if (delegate != nil) {
                dict[FSMediaEventAttrKey_time_of_event]    = @(elapsed).stringValue;
                dict[FSMediaEventAttrKey_url]              = monitor.httpUrl ?: @"";
                dict[FSMediaEventAttrKey_host]             = host ?: @"";
                dict[FSMediaEventAttrKey_offset]           = @(realData->offset).stringValue;
                dict[FSMediaEventAttrKey_error]            = @(realData->error).stringValue;
                dict[FSMediaEventAttrKey_http_code]        = @(realData->http_code).stringValue;
                [delegate invoke:type attributes:dict];
            }
            break;
    }

    return 0;
}

// NOTE: could be called from multiple thread
static int ijkff_inject_callback(void *opaque, int message, void *data, size_t data_size)
{
    FSWeakHolder *weakHolder = (__bridge FSWeakHolder*)opaque;
    FSPlayer *mpc = weakHolder.object;
    if (!mpc)
        return 0;

    switch (message) {
        case AVAPP_CTRL_WILL_CONCAT_SEGMENT_OPEN:
            return onInjectIOControl(mpc, mpc.segmentOpenDelegate, message, data, data_size);
        case AVAPP_CTRL_WILL_TCP_OPEN:
            return onInjectTcpIOControl(mpc, mpc.tcpOpenDelegate, message, data, data_size);
        case AVAPP_CTRL_WILL_HTTP_OPEN:
            return onInjectIOControl(mpc, mpc.httpOpenDelegate, message, data, data_size);
        case AVAPP_CTRL_WILL_LIVE_OPEN:
            return onInjectIOControl(mpc, mpc.liveOpenDelegate, message, data, data_size);
        case AVAPP_EVENT_ASYNC_STATISTIC:
            return onInjectAsyncStatistic(mpc, message, data, data_size);
        case FSIOAPP_EVENT_CACHE_STATISTIC:
            return onInectIJKIOStatistic(mpc, message, data, data_size);
        case AVAPP_CTRL_DID_TCP_OPEN:
            return onInjectTcpIOControl(mpc, mpc.tcpOpenDelegate, message, data, data_size);
        case AVAPP_EVENT_WILL_HTTP_OPEN:
        case AVAPP_EVENT_DID_HTTP_OPEN:
        case AVAPP_EVENT_WILL_HTTP_SEEK:
        case AVAPP_EVENT_DID_HTTP_SEEK:
            return onInjectOnHttpEvent(mpc, message, data, data_size);
        default: {
            return 0;
        }
    }
}

static int ijkff_audio_samples_callback(void *opaque, int16_t *samples, int sampleSize, int sampleRate, int channels)
{
    FSWeakHolder *weakHolder = (__bridge FSWeakHolder*)opaque;
    FSPlayer *mpc = weakHolder.object;
    if (!mpc)
        return 0;

    if (mpc.audioSamplesCallback) {
        mpc.audioSamplesCallback(samples, sampleSize, sampleRate, channels);
        return 0;
    } else {
        return -1;
    }
}

#pragma mark Airplay

-(BOOL)allowsMediaAirPlay
{
    if (!self)
        return NO;
    return _allowsMediaAirPlay;
}

-(void)setAllowsMediaAirPlay:(BOOL)b
{
    if (!self)
        return;
    _allowsMediaAirPlay = b;
}

-(BOOL)airPlayMediaActive
{
    if (!self)
        return NO;
    if (_isDanmakuMediaAirPlay) {
        return YES;
    }
    return NO;
}

-(BOOL)isDanmakuMediaAirPlay
{
    return _isDanmakuMediaAirPlay;
}

-(void)setIsDanmakuMediaAirPlay:(BOOL)isDanmakuMediaAirPlay
{
    _isDanmakuMediaAirPlay = isDanmakuMediaAirPlay;

#if TARGET_OS_IOS
    if (_isDanmakuMediaAirPlay) {
        _glView.scaleFactor = 1.0f;
    } else {
        CGFloat scale = [[UIScreen mainScreen] scale];
        if (scale < 0.1f)
            scale = 1.0f;
        _glView.scaleFactor = scale;
    }
#endif
     [[NSNotificationCenter defaultCenter] postNotificationName:FSPlayerIsAirPlayVideoActiveDidChangeNotification object:nil userInfo:nil];
}


#pragma mark Option Conventionce

- (void)setFormatOptionValue:(NSString *)value forKey:(NSString *)key
{
    [self setOptionValue:value forKey:key ofCategory:kIJKFFOptionCategoryFormat];
}

- (void)setCodecOptionValue:(NSString *)value forKey:(NSString *)key
{
    [self setOptionValue:value forKey:key ofCategory:kIJKFFOptionCategoryCodec];
}

- (void)setSwsOptionValue:(NSString *)value forKey:(NSString *)key
{
    [self setOptionValue:value forKey:key ofCategory:kIJKFFOptionCategorySws];
}

- (void)setPlayerOptionValue:(NSString *)value forKey:(NSString *)key
{
    [self setOptionValue:value forKey:key ofCategory:kIJKFFOptionCategoryPlayer];
}

- (void)setFormatOptionIntValue:(int64_t)value forKey:(NSString *)key
{
    [self setOptionIntValue:value forKey:key ofCategory:kIJKFFOptionCategoryFormat];
}

- (void)setCodecOptionIntValue:(int64_t)value forKey:(NSString *)key
{
    [self setOptionIntValue:value forKey:key ofCategory:kIJKFFOptionCategoryCodec];
}

- (void)setSwsOptionIntValue:(int64_t)value forKey:(NSString *)key
{
    [self setOptionIntValue:value forKey:key ofCategory:kIJKFFOptionCategorySws];
}

- (void)setPlayerOptionIntValue:(int64_t)value forKey:(NSString *)key
{
    [self setOptionIntValue:value forKey:key ofCategory:kIJKFFOptionCategoryPlayer];
}

- (void)setMaxBufferSize:(int)maxBufferSize
{
    [self setPlayerOptionIntValue:maxBufferSize forKey:@"max-buffer-size"];
}

#if TARGET_OS_IOS
#pragma mark app state changed

- (void)registerApplicationObservers
{
    [_notificationManager addObserver:self
                             selector:@selector(audioSessionInterrupt:)
                                 name:AVAudioSessionInterruptionNotification
                               object:nil];

    [_notificationManager addObserver:self
                             selector:@selector(applicationWillResignActive)
                                 name:UIApplicationWillResignActiveNotification
                               object:nil];

    [_notificationManager addObserver:self
                             selector:@selector(applicationDidEnterBackground)
                                 name:UIApplicationDidEnterBackgroundNotification
                               object:nil];

    [_notificationManager addObserver:self
                             selector:@selector(applicationWillTerminate)
                                 name:UIApplicationWillTerminateNotification
                               object:nil];
}

- (void)unregisterApplicationObservers
{
    [_notificationManager removeAllObservers:self];
}

- (void)audioSessionInterrupt:(NSNotification *)notification
{
    int reason = [[[notification userInfo] valueForKey:AVAudioSessionInterruptionTypeKey] intValue];
    switch (reason) {
        case AVAudioSessionInterruptionTypeBegan: {
            NSLog(@"FSPlayer:audioSessionInterrupt: begin\n");
            switch (self.playbackState) {
                case FSPlayerPlaybackStatePaused:
                case FSPlayerPlaybackStateStopped:
                    _playingBeforeInterruption = NO;
                    break;
                default:
                    _playingBeforeInterruption = YES;
                    break;
            }
            [self pause];
            [[FSAudioKit sharedInstance] setActive:NO];
            break;
        }
        case AVAudioSessionInterruptionTypeEnded: {
            NSLog(@"FSPlayer:audioSessionInterrupt: end\n");
            [[FSAudioKit sharedInstance] setActive:YES];
            if (_playingBeforeInterruption) {
                [self play];
            }
            break;
        }
    }
}

- (void)applicationWillResignActive
{
    NSLog(@"FSPlayer:applicationWillResignActive: %d", (int)[UIApplication sharedApplication].applicationState);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_pauseInBackground) {
            [self pause];
        }
    });
}

- (void)applicationDidEnterBackground
{
    NSLog(@"FSPlayer:applicationDidEnterBackground: %d", (int)[UIApplication sharedApplication].applicationState);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_pauseInBackground) {
            [self pause];
        }
    });
}

- (void)applicationWillTerminate
{
    NSLog(@"FSPlayer:applicationWillTerminate: %d", (int)[UIApplication sharedApplication].applicationState);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_pauseInBackground) {
            [self pause];
        }
    });
}
#endif

- (void)exchangeSelectedStream:(int)streamIdx
{
    if (_mediaPlayer) {
        //通过seek解决切换内嵌字幕，内嵌音轨后不能立马生效问题
        long pst = ijkmp_get_current_position(_mediaPlayer);
        int r = ijkmp_set_stream_selected(_mediaPlayer, streamIdx, 1);
        if (r > 0) {
            ijkmp_seek_to(_mediaPlayer, pst);
        }
    }
}

- (void)closeCurrentStream:(NSString *)streamType
{
    NSDictionary *dic = self.monitor.mediaMeta;
    if (dic[streamType] != nil) {
        int streamIdx = [dic[streamType] intValue];
        if (streamIdx > -1) {
             ijkmp_set_stream_selected(_mediaPlayer,streamIdx,0);
        }
    }
}

- (void)setSubtitlePreference:(FSSubtitlePreference)subtitlePreference
{
    if (!isIJKSDLSubtitlePreferenceEqual(&_subtitlePreference, &subtitlePreference)) {
        _subtitlePreference = subtitlePreference;
        ijkmp_set_subtitle_preference(_mediaPlayer, &subtitlePreference);
    }
}

@end
