/*
 * ijksdl_aout_ios_audiounit.m
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

#include "ijksdl_aout_ios_audiounit.h"

#include <stdbool.h>
#include <assert.h>
#include "ijksdl/ijksdl_inc_internal.h"
#include "ijksdl/ijksdl_thread.h"
#include "ijksdl/ijksdl_aout_internal.h"
#import "FSAudioRendering.h"

#define SDL_IOS_AUDIO_MAX_CALLBACKS_PER_SEC 15

struct SDL_Aout_Opaque {
    __strong id<FSAudioRenderingProtocol> aoutController;
    bool automaticallySetupAudioSession;
};

static int aout_open_audio(SDL_Aout *aout, const SDL_AudioSpec *desired, SDL_AudioSpec *obtained)
{
    assert(desired);
    SDLTRACE("aout_open_audio()\n");
    SDL_Aout_Opaque *opaque = aout->opaque;
    NSError * error = nil;
    
    FSAudioSpec *spec = [[FSAudioSpec alloc] init];
    spec.freq = desired->freq;
    spec.format = desired->format;
    spec.channels = desired->channels;
    spec.silence = desired->silence;
    spec.samples = desired->samples;
    spec.padding = desired->padding;
    spec.size = desired->size;
    spec.callback = desired->callback;
    spec.userdata = desired->userdata;
    
    if (!opaque->aoutController) {
        opaque->aoutController = [FSAudioRendering createAudioQueueRendering];
    }
    opaque->aoutController.automaticallySetupAudioSession = opaque->automaticallySetupAudioSession;
    
    if (![opaque->aoutController isSupportAudioSpec:spec err:&error]) {
        ALOGE("aout_open_audio:%d,%s",error.code,[error.userInfo[NSLocalizedDescriptionKey] UTF8String]);
        return -1;
    }

    if (obtained) {
        SDL_AudioSpec out_Spec;
        out_Spec.freq = spec.freq;
        out_Spec.format = spec.format;
        out_Spec.channels = spec.channels;
        out_Spec.silence = spec.silence;
        out_Spec.samples = spec.samples;
        out_Spec.padding = spec.padding;
        out_Spec.size = spec.size;
        out_Spec.callback = spec.callback;
        out_Spec.userdata = spec.userdata;
        *obtained = out_Spec;
    }
    return 0;
}

static void aout_set_controller(SDL_Aout *aout, void *aoutController)
{
    SDL_Aout_Opaque *opaque = aout->opaque;
    if (opaque->aoutController != aoutController) {
        opaque->aoutController = (__bridge id<FSAudioRenderingProtocol>)(aoutController);
    }
}

static void aout_set_automatically_setup_audio_session(SDL_Aout *aout, bool automaticallySetupAudioSession)
{
    SDL_Aout_Opaque *opaque = aout->opaque;
    if (opaque->automaticallySetupAudioSession != automaticallySetupAudioSession) {
        opaque->automaticallySetupAudioSession = automaticallySetupAudioSession;
    }
}

static void aout_pause_audio(SDL_Aout *aout, int pause_on)
{
    SDLTRACE("aout_pause_audio(%d)\n", pause_on);
    SDL_Aout_Opaque *opaque = aout->opaque;

    if (pause_on) {
        [opaque->aoutController pause];
    } else {
        [opaque->aoutController play];
    }
}

static void aout_flush_audio(SDL_Aout *aout)
{
    SDLTRACE("aout_flush_audio()\n");
    SDL_Aout_Opaque *opaque = aout->opaque;

    [opaque->aoutController flush];
}

static void aout_close_audio(SDL_Aout *aout)
{
    SDLTRACE("aout_close_audio()\n");
    SDL_Aout_Opaque *opaque = aout->opaque;

    [opaque->aoutController close];
}

static void aout_set_playback_rate(SDL_Aout *aout, float playbackRate)
{
    SDLTRACE("aout_close_audio()\n");
    SDL_Aout_Opaque *opaque = aout->opaque;

    [opaque->aoutController setPlaybackRate:playbackRate];
}

static void aout_set_playback_volume(SDL_Aout *aout, float volume)
{
    SDLTRACE("aout_set_volume()\n");
    SDL_Aout_Opaque *opaque = aout->opaque;

    [opaque->aoutController setPlaybackVolume:volume];
}

static double auout_get_latency_seconds(SDL_Aout *aout)
{
    SDL_Aout_Opaque *opaque = aout->opaque;
    return [opaque->aoutController get_latency_seconds];
}

static int aout_get_persecond_callbacks(SDL_Aout *aout)
{
    return SDL_IOS_AUDIO_MAX_CALLBACKS_PER_SEC;
}

static void aout_free_l(SDL_Aout *aout)
{
    if (!aout)
        return;

    aout_close_audio(aout);

    SDL_Aout_Opaque *opaque = aout->opaque;
    if (opaque) {
        opaque->aoutController = nil;
    }

    SDL_Aout_FreeInternal(aout);
}

SDL_Aout *SDL_AoutIos_CreateForAudioUnit(void)
{
    SDL_Aout *aout = SDL_Aout_CreateInternal(sizeof(SDL_Aout_Opaque));
    if (!aout)
        return NULL;

    // SDL_Aout_Opaque *opaque = aout->opaque;

    aout->free_l = aout_free_l;
    aout->open_audio  = aout_open_audio;
    aout->pause_audio = aout_pause_audio;
    aout->flush_audio = aout_flush_audio;
    aout->close_audio = aout_close_audio;

    aout->func_set_playback_rate = aout_set_playback_rate;
    aout->func_set_playback_volume = aout_set_playback_volume;
    aout->func_get_latency_seconds = auout_get_latency_seconds;
    aout->func_get_audio_persecond_callbacks = aout_get_persecond_callbacks;
    aout->func_set_controller = aout_set_controller;
    aout->func_set_automatically_setup_audio_session = aout_set_automatically_setup_audio_session;
    return aout;
}
