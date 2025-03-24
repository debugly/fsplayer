/*
 * FSMediaPlayback.m
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

#import "FSMediaPlayback.h"

NSString *const FSMPMediaPlaybackIsPreparedToPlayDidChangeNotification = @"FSMPMediaPlaybackIsPreparedToPlayDidChangeNotification";

NSString *const FSMPMoviePlayerPlaybackDidFinishNotification = @"FSMPMoviePlayerPlaybackDidFinishNotification";
NSString *const FSMPMoviePlayerPlaybackDidFinishReasonUserInfoKey =
    @"FSMPMoviePlayerPlaybackDidFinishReasonUserInfoKey";
NSString *const FSMPMoviePlayerPlaybackStateDidChangeNotification = @"FSMPMoviePlayerPlaybackStateDidChangeNotification";
NSString *const FSMPMoviePlayerLoadStateDidChangeNotification = @"FSMPMoviePlayerLoadStateDidChangeNotification";

NSString *const FSMPMoviePlayerIsAirPlayVideoActiveDidChangeNotification = @"FSMPMoviePlayerIsAirPlayVideoActiveDidChangeNotification";

NSString *const FSMPMovieNaturalSizeAvailableNotification = @"FSMPMovieNaturalSizeAvailableNotification";
NSString *const FSMPMovieZRotateAvailableNotification = @"FSMPMovieZRotateAvailableNotification";
NSString *const FSMPMovieNoCodecFoundNotification = @"FSMPMovieNoCodecFoundNotification";

NSString *const FSMPMoviePlayerVideoDecoderOpenNotification = @"FSMPMoviePlayerVideoDecoderOpenNotification";

NSString *const FSMPMoviePlayerFirstVideoFrameRenderedNotification = @"FSMPMoviePlayerFirstVideoFrameRenderedNotification";
NSString *const FSMPMoviePlayerFirstAudioFrameRenderedNotification = @"FSMPMoviePlayerFirstAudioFrameRenderedNotification";
NSString *const FSMPMoviePlayerFirstAudioFrameDecodedNotification  = @"FSMPMoviePlayerFirstAudioFrameDecodedNotification";
NSString *const FSMPMoviePlayerFirstVideoFrameDecodedNotification  = @"FSMPMoviePlayerFirstVideoFrameDecodedNotification";
NSString *const FSMPMoviePlayerOpenInputNotification               = @"FSMPMoviePlayerOpenInputNotification";
NSString *const FSMPMoviePlayerFindStreamInfoNotification          = @"FSMPMoviePlayerFindStreamInfoNotification";
NSString *const FSMPMoviePlayerComponentOpenNotification           = @"FSMPMoviePlayerComponentOpenNotification";

NSString *const FSMPMoviePlayerAccurateSeekCompleteNotification = @"FSMPMoviePlayerAccurateSeekCompleteNotification";

NSString *const FSMPMoviePlayerDidSeekCompleteNotification = @"FSMPMoviePlayerDidSeekCompleteNotification";
NSString *const FSMPMoviePlayerDidSeekCompleteTargetKey = @"FSMPMoviePlayerDidSeekCompleteTargetKey";
NSString *const FSMPMoviePlayerDidSeekCompleteErrorKey = @"FSMPMoviePlayerDidSeekCompleteErrorKey";
NSString *const FSMPMoviePlayerDidAccurateSeekCompleteCurPos = @"FSMPMoviePlayerDidAccurateSeekCompleteCurPos";

NSString *const FSMPMoviePlayerSeekAudioStartNotification  = @"FSMPMoviePlayerSeekAudioStartNotification";
NSString *const FSMPMoviePlayerSeekVideoStartNotification  = @"FSMPMoviePlayerSeekVideoStartNotification";

NSString *const FSMPMoviePlayerSelectedStreamDidChangeNotification =
    @"FSMPMoviePlayerSelectedStreamDidChangeNotification";
NSString *const FSMPMoviePlayerAfterSeekFirstVideoFrameDisplayNotification = @"FSMPMoviePlayerAfterSeekFirstVideoFrameDisplayNotification";

NSString *const FSMPMoviePlayerVideoDecoderFatalNotification = @"FSMPMoviePlayerVideoDecoderFatalNotification";

NSString *const FSMPMoviePlayerPlaybackRecvWarningNotification = @"FSMPMoviePlayerPlaybackRecvWarningNotification";

NSString *const FSMPMoviePlayerPlaybackWarningReasonUserInfoKey = @"FSMPMoviePlayerPlaybackWarningReasonUserInfoKey";

NSString *const FSMoviePlayerHDRAnimationStateChanged = @"FSMoviePlayerHDRAnimationStateChanged";

NSString *const FSMoviePlayerSelectingStreamIDUserInfoKey = @"stream-id";
NSString *const FSMoviePlayerPreSelectingStreamIDUserInfoKey = @"pre-stream-id";
NSString *const FSMoviePlayerSelectingStreamErrUserInfoKey = @"err-code";
NSString *const FSMoviePlayerSelectingStreamDidFailed = @"FSMoviePlayerSelectingStreamDidFailed";

NSString *const FSMPMoviePlayerICYMetaChangedNotification = @"FSMPMoviePlayerICYMetaChangedNotification";

@implementation FSMediaUrlOpenData {
    NSString *_url;
    BOOL _handled;
    BOOL _urlChanged;
}

- (id)initWithUrl:(NSString *)url
            event:(FSMediaEvent)event
     segmentIndex:(int)segmentIndex
     retryCounter:(int)retryCounter
{
    self = [super init];
    if (self) {
        self->_url          = url;
        self->_event        = event;
        self->_segmentIndex = segmentIndex;
        self->_retryCounter = retryCounter;

        self->_error        = 0;
        self->_handled      = NO;
        self->_urlChanged   = NO;
    }
    return self;
}

- (void)setHandled:(BOOL)handled
{
    _handled = handled;
}

- (BOOL)isHandled
{
    return _handled;
}

- (BOOL)isUrlChanged
{
    return _urlChanged;
}

- (NSString *)url
{
    return _url;
}

- (void)setUrl:(NSString *)url
{
    assert(url);

    _handled = YES;

    if (![self.url isEqualToString:url]) {
        _urlChanged = YES;
        _url = url;
    }
}

@end
