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

NSString *const FSPlayerIsPreparedToPlayDidChangeNotification = @"FSPlayerIsPreparedToPlayDidChangeNotification";

NSString *const FSPlayerDidFinishNotification = @"FSPlayerDidFinishNotification";
NSString *const FSPlayerDidFinishReasonUserInfoKey =
    @"FSPlayerDidFinishReasonUserInfoKey";
NSString *const FSPlayerPlaybackStateDidChangeNotification = @"FSPlayerPlaybackStateDidChangeNotification";
NSString *const FSPlayerLoadStateDidChangeNotification = @"FSPlayerLoadStateDidChangeNotification";

NSString *const FSPlayerIsAirPlayVideoActiveDidChangeNotification = @"FSPlayerIsAirPlayVideoActiveDidChangeNotification";

NSString *const FSPlayerNaturalSizeAvailableNotification = @"FSPlayerNaturalSizeAvailableNotification";
NSString *const FSPlayerZRotateAvailableNotification = @"FSPlayerZRotateAvailableNotification";
NSString *const FSPlayerNoCodecFoundNotification = @"FSPlayerNoCodecFoundNotification";

NSString *const FSPlayerVideoDecoderOpenNotification = @"FSPlayerVideoDecoderOpenNotification";

NSString *const FSPlayerFirstVideoFrameRenderedNotification = @"FSPlayerFirstVideoFrameRenderedNotification";
NSString *const FSPlayerFirstAudioFrameRenderedNotification = @"FSPlayerFirstAudioFrameRenderedNotification";
NSString *const FSPlayerFirstAudioFrameDecodedNotification  = @"FSPlayerFirstAudioFrameDecodedNotification";
NSString *const FSPlayerFirstVideoFrameDecodedNotification  = @"FSPlayerFirstVideoFrameDecodedNotification";
NSString *const FSPlayerOpenInputNotification               = @"FSPlayerOpenInputNotification";
NSString *const FSPlayerFindStreamInfoNotification          = @"FSPlayerFindStreamInfoNotification";
NSString *const FSPlayerComponentOpenNotification           = @"FSPlayerComponentOpenNotification";

NSString *const FSPlayerAccurateSeekCompleteNotification = @"FSPlayerAccurateSeekCompleteNotification";

NSString *const FSPlayerDidSeekCompleteNotification = @"FSPlayerDidSeekCompleteNotification";
NSString *const FSPlayerDidSeekCompleteTargetKey = @"FSPlayerDidSeekCompleteTargetKey";
NSString *const FSPlayerDidSeekCompleteErrorKey = @"FSPlayerDidSeekCompleteErrorKey";
NSString *const FSPlayerDidAccurateSeekCompleteCurPos = @"FSPlayerDidAccurateSeekCompleteCurPos";

NSString *const FSPlayerSeekAudioStartNotification  = @"FSPlayerSeekAudioStartNotification";
NSString *const FSPlayerSeekVideoStartNotification  = @"FSPlayerSeekVideoStartNotification";

NSString *const FSPlayerSelectedStreamDidChangeNotification =
    @"FSPlayerSelectedStreamDidChangeNotification";
NSString *const FSPlayerAfterSeekFirstVideoFrameDisplayNotification = @"FSPlayerAfterSeekFirstVideoFrameDisplayNotification";

NSString *const FSPlayerVideoDecoderFatalNotification = @"FSPlayerVideoDecoderFatalNotification";

NSString *const FSPlayerRecvWarningNotification = @"FSPlayerRecvWarningNotification";

NSString *const FSPlayerWarningReasonUserInfoKey = @"FSPlayerWarningReasonUserInfoKey";

NSString *const FSPlayerHDRAnimationStateChanged = @"FSPlayerHDRAnimationStateChanged";

NSString *const FSPlayerSelectingStreamIDUserInfoKey = @"stream-id";
NSString *const FSPlayerPreSelectingStreamIDUserInfoKey = @"pre-stream-id";
NSString *const FSPlayerSelectingStreamErrUserInfoKey = @"err-code";
NSString *const FSPlayerSelectingStreamDidFailed = @"FSPlayerSelectingStreamDidFailed";

NSString *const FSPlayerICYMetaChangedNotification = @"FSPlayerICYMetaChangedNotification";

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
