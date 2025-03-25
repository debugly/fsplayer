/*
 * Copyright (c) 2016 Bilibili
 * Copyright (c) 2016 Zhang Rui <bbcallen@gmail.com>
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

#import "FSMonitor.h"
#include "ijksdl/ijksdl_timer.h"
#include "ijkplayer/ijkmeta.h"

#define FS_FFM_SAMPLE_RANGE 2000

@implementation FSMonitor
{
    SDL_SpeedSampler2 _tcpSpeedSampler;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        SDL_SpeedSampler2Reset(&_tcpSpeedSampler, FS_FFM_SAMPLE_RANGE);
    }
    return self;
}

- (float)fps
{
    int fpsNum = [_videoMeta[@FSM_KEY_FPS_NUM] intValue];
    int fpsDen = [_videoMeta[@FSM_KEY_FPS_DEN] intValue];

    if (fpsNum <= 0 || fpsDen <= 0)
        return 0;

    return ((float)fpsNum) / fpsDen;
}

- (int64_t)     duration    {return [_mediaMeta[@FSM_KEY_DURATION_US] longLongValue] / 1000;}
- (int64_t)     bitrate     {return [_mediaMeta[@FSM_KEY_BITRATE] longLongValue];}
- (int)         width       {return [_videoMeta[@FSM_KEY_WIDTH] intValue];}
- (int)         height      {return [_videoMeta[@FSM_KEY_HEIGHT] intValue];}
- (NSString *)  vcodec      {return _videoMeta[@FSM_KEY_CODEC_NAME] ?: @"";}
- (NSString *)  acodec      {return _audioMeta[@FSM_KEY_CODEC_NAME] ?: @"";}
- (int)         sampleRate  {return [_audioMeta[@FSM_KEY_SAMPLE_RATE] intValue];}


@end
