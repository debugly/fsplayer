/*
 * ijkplayer_android.c
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

#include "ijkplayer_android.h"

#include <assert.h>
#include "ijksdl/android/ijksdl_android.h"
#include "../ff_fferror.h"
#include "../ff_ffplay.h"
#include "../ijkplayer_internal.h"
#include "../pipeline/ffpipeline_ffplay.h"
#include "pipeline/ffpipeline_android.h"

IjkMediaPlayer *ijkmp_android_create(int(*msg_loop)(void*))
{
    IjkMediaPlayer *mp = ijkmp_create(msg_loop);
    if (!mp)
        goto fail;

    mp->ffplayer->vout = SDL_VoutAndroid_CreateForVulkan();
    if (!mp->ffplayer->vout)
        goto fail;

    /*
     * 字幕纹理层（SDL_GPU）：和 vout 的 Vulkan 渲染器共用 device/queue，
     * 对应 iOS 在 ijkmp_ios_set_glview_l 里调 SDL_CreateGPU_WithContext。
     * 所有权归 ffplayer，由 ffp_destroy 里的 SDL_GPUFreeP 释放。
     */
    mp->ffplayer->gpu = SDL_VoutAndroid_GetGPU(mp->ffplayer->vout);
    if (mp->ffplayer->gpu) {
        ALOGI("subtitle gpu ready\n");
    } else {
        mp->ffplayer->subtitle_mix = 0;
        ALOGE("video rendering not provide gpu context,subtile feature will be disabled");
    }

    /* 缩放模式（等比完整显示/铺满/拉伸），之后可通过 setPropertyInt64 改 */
    SDL_VoutAndroid_SetScalingMode(mp->ffplayer->vout, mp->ffplayer->video_scaling_mode);

    mp->ffplayer->pipeline = ffpipeline_create_from_android(mp->ffplayer);
    if (!mp->ffplayer->pipeline)
        goto fail;

    ffpipeline_set_vout(mp->ffplayer->pipeline, mp->ffplayer->vout);

    return mp;

fail:
    ijkmp_dec_ref_p(&mp);
    return NULL;
}

void ijkmp_android_set_surface_l(JNIEnv *env, IjkMediaPlayer *mp, jobject android_surface)
{
    if (!mp || !mp->ffplayer || !mp->ffplayer->vout)
        return;

    SDL_VoutAndroid_SetAndroidSurface(env, mp->ffplayer->vout, android_surface);
    ffpipeline_set_surface(env, mp->ffplayer->pipeline, android_surface);
}

int ijkmp_android_take_snapshot(IjkMediaPlayer *mp, int type,
                                int *out_w, int *out_h, void **out_pixels)
{
    if (!mp || !mp->ffplayer || !mp->ffplayer->vout)
        return -1;

    /*
     * 静止时视频线程没有新帧可画，先请求一次强制刷新让它把当前帧重新显示一遍
     * （和 refreshPicture 用的是同一个开关）。
     *
     * 限制：MediaCodec 零拷贝通路下，上一帧的 AImage 在显示后已经还给 ImageReader，
     * 暂停时重画会 acquire 失败（日志 "acquire latest image failed"），此时快照返回 -1。
     * 要做到 iOS 那样暂停也能截，需要在渲染器里留住最后一帧（拷贝成自己的 image，
     * 或者把 AImage 的持有权延到下一帧），见 TODO。
     */
    ffp_refresh_picture(mp->ffplayer);

    return SDL_VoutAndroid_TakeSnapshot(mp->ffplayer->vout, type,
                                        out_w, out_h, out_pixels);
}

void ijkmp_android_set_surface(JNIEnv *env, IjkMediaPlayer *mp, jobject android_surface)
{
    if (!mp)
        return;

    MPTRACE("ijkmp_set_android_surface(surface=%p)", (void*)android_surface);
    pthread_mutex_lock(&mp->mutex);
    ijkmp_android_set_surface_l(env, mp, android_surface);
    pthread_mutex_unlock(&mp->mutex);
    MPTRACE("ijkmp_set_android_surface(surface=%p)=void", (void*)android_surface);
}

void ijkmp_android_set_volume(JNIEnv *env, IjkMediaPlayer *mp, float left, float right)
{
    if (!mp)
        return;

    MPTRACE("ijkmp_android_set_volume(%f, %f)", left, right);
    pthread_mutex_lock(&mp->mutex);

    if (mp && mp->ffplayer && mp->ffplayer->pipeline) {
        ffpipeline_set_volume(mp->ffplayer->pipeline, left, right);
    }

    pthread_mutex_unlock(&mp->mutex);
    MPTRACE("ijkmp_android_set_volume(%f, %f)=void", left, right);
}

int ijkmp_android_get_audio_session_id(JNIEnv *env, IjkMediaPlayer *mp)
{
    int audio_session_id = 0;
    if (!mp)
        return audio_session_id;

    MPTRACE("%s()", __func__);
    pthread_mutex_lock(&mp->mutex);

    if (mp && mp->ffplayer && mp->ffplayer->aout) {
        audio_session_id = SDL_AoutGetAudioSessionId(mp->ffplayer->aout);
    }

    pthread_mutex_unlock(&mp->mutex);
    MPTRACE("%s()=%d", __func__, audio_session_id);

    return audio_session_id;
}

void ijkmp_android_set_mediacodec_select_callback(IjkMediaPlayer *mp, bool (*callback)(void *opaque, ijkmp_mediacodecinfo_context *mcc), void *opaque)
{
    if (!mp)
        return;

    MPTRACE("ijkmp_android_set_mediacodec_select_callback()");
    pthread_mutex_lock(&mp->mutex);

    if (mp && mp->ffplayer && mp->ffplayer->pipeline) {
        ffpipeline_set_mediacodec_select_callback(mp->ffplayer->pipeline, callback, opaque);
    }

    pthread_mutex_unlock(&mp->mutex);
    MPTRACE("ijkmp_android_set_mediacodec_select_callback()=void");
}
