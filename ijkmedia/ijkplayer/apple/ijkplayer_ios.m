/*
 * ijkplayer_ios.c
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

#import "ijkplayer_ios.h"
#import "ijksdl/apple/ijksdl_ios.h"
#include <stdio.h>
#include <assert.h>
#include "ijkplayer/ff_fferror.h"
#include "ijkplayer/ff_ffplay.h"
#include "ijkplayer/ijkplayer_internal.h"
#include "ijkplayer/pipeline/ffpipeline_ffplay.h"
#include "pipeline/ffpipeline_ios.h"

IjkMediaPlayer *ijkmp_ios_create(int (*msg_loop)(void*))
{
    IjkMediaPlayer *mp = ijkmp_create(msg_loop);
    if (!mp)
    goto fail;
    
    mp->ffplayer->vout = SDL_VoutIos_CreateForGLES2();
    if (!mp->ffplayer->vout)
    goto fail;
    
    mp->ffplayer->pipeline = ffpipeline_create_from_ios(mp->ffplayer);
    if (!mp->ffplayer->pipeline)
    goto fail;
    
    mp->ffplayer->aout = ffpipeline_open_audio_output(mp->ffplayer->pipeline, mp->ffplayer);
    if (!mp->ffplayer->aout)
    goto fail;
    
    return mp;
    
fail:
    ijkmp_dec_ref_p(&mp);
    return NULL;
}

static void ijkmp_ios_set_glview_l(IjkMediaPlayer *mp, UIView<FSVideoRenderingProtocol>* glView)
{
    assert(mp);
    assert(mp->ffplayer);
    assert(mp->ffplayer->vout);
    
    SDL_VoutIos_SetGLView(mp->ffplayer->vout, glView);
    SDL_GPU *gpu = SDL_CreateGPU_WithContext(glView.context);
    if (gpu) {
        mp->ffplayer->gpu = gpu;
    } else {
        mp->ffplayer->subtitle_mix = 0;
        ALOGE("video rendering not provide gpu context,subtile feature will be disabled");
    }
}

static void ijkmp_ios_set_audio_controller_l(IjkMediaPlayer *mp, id<FSAudioRenderingProtocol> audioRendering)
{
    assert(mp);
    assert(mp->ffplayer);
    assert(mp->ffplayer->aout);
    
    SDL_AoutSetController(mp->ffplayer->aout, (__bridge void*)audioRendering);
}

static void ijkmp_ios_automatically_setup_audio_session_l(IjkMediaPlayer *mp, bool automaticallySetupAudioSession)
{
    assert(mp);
    assert(mp->ffplayer);
    assert(mp->ffplayer->aout);
    
    SDL_AoutSetAutomaticallySetupAudioSession(mp->ffplayer->aout, automaticallySetupAudioSession);
}

void ijkmp_ios_set_glview(IjkMediaPlayer *mp, UIView<FSVideoRenderingProtocol>* glView)
{
    assert(mp);
    MPTRACE("ijkmp_ios_set_view(glView=%p)\n", (__bridge void*)glView);
    pthread_mutex_lock(&mp->mutex);
    ijkmp_ios_set_glview_l(mp, glView);
    pthread_mutex_unlock(&mp->mutex);
    MPTRACE("ijkmp_ios_set_view(glView=%p)=void\n", (__bridge void*)glView);
}

void ijkmp_ios_set_audio_controller(IjkMediaPlayer *mp, id<FSAudioRenderingProtocol> audioRendering)
{
    assert(mp);
    MPTRACE("ijkmp_ios_set_audio_controller(audioRendering=%p)\n", (__bridge void*)audioRendering);
    pthread_mutex_lock(&mp->mutex);
    ijkmp_ios_set_audio_controller_l(mp, audioRendering);
    pthread_mutex_unlock(&mp->mutex);
    MPTRACE("ijkmp_ios_set_audio_controller(audioRendering=%p)=void\n", (__bridge void*)audioRendering);
}

void ijkmp_ios_set_automatically_setup_audio_session(IjkMediaPlayer *mp, bool automaticallySetupAudioSession)
{
    assert(mp);
    MPTRACE("ijkmp_ios_set_automatically_setup_audio_session(automaticallySetupAudioSession=%d)\n", automaticallySetupAudioSession);
    pthread_mutex_lock(&mp->mutex);
    ijkmp_ios_automatically_setup_audio_session_l(mp, automaticallySetupAudioSession);
    pthread_mutex_unlock(&mp->mutex);
    MPTRACE("ijkmp_ios_set_automatically_setup_audio_session(automaticallySetupAudioSession=%d)=void\n", automaticallySetupAudioSession);
}
