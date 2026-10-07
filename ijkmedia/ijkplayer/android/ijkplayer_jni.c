/*
 * ijkplayer_jni.c
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

#include <assert.h>
#include <string.h>
#include <pthread.h>
#include <jni.h>
#include <unistd.h>
#include "j4a/class/java/util/ArrayList.h"
#include "j4a/class/android/os/Bundle.h"
#include "j4a/class/tv/danmaku/ijk/media/player/IjkMediaPlayer.h"
#include "j4a/class/tv/danmaku/ijk/media/player/misc/IMediaDataSource.h"
#include "j4a/class/tv/danmaku/ijk/media/player/misc/IAndroidIO.h"
#include "ijksdl/ijksdl_log.h"
#include "../ff_ffplay.h"
#include "ffmpeg_api_jni.h"
#include "ijkplayer_android_def.h"
#include "ijkplayer_android.h"
#include "ijksdl/android/ijksdl_android_jni.h"
#include "ijkavformat/ijkavformat.h"

#define JNI_MODULE_PACKAGE      "tv/danmaku/ijk/media/player"
#define JNI_CLASS_IJKPLAYER     "tv/danmaku/ijk/media/player/IjkMediaPlayer"
#define JNI_IJK_MEDIA_EXCEPTION "tv/danmaku/ijk/media/player/exceptions/IjkMediaException"

#define IJK_CHECK_MPRET_GOTO(retval, env, label) \
    JNI_CHECK_GOTO((retval != EIJK_INVALID_STATE), env, "java/lang/IllegalStateException", NULL, label); \
    JNI_CHECK_GOTO((retval != EIJK_OUT_OF_MEMORY), env, "java/lang/OutOfMemoryError", NULL, label); \
    JNI_CHECK_GOTO((retval == 0), env, JNI_IJK_MEDIA_EXCEPTION, NULL, label);

typedef struct player_fields_t {
    pthread_mutex_t mutex;
    jclass clazz;
} player_fields_t;
static player_fields_t g_clazz;

static int inject_callback(void *opaque, int type, void *data, size_t data_size);
static bool mediacodec_select_callback(void *opaque, ijkmp_mediacodecinfo_context *mcc);

static IjkMediaPlayer *jni_get_media_player(JNIEnv* env, jobject thiz)
{
    pthread_mutex_lock(&g_clazz.mutex);

    IjkMediaPlayer *mp = (IjkMediaPlayer *) (intptr_t) J4AC_IjkMediaPlayer__mNativeMediaPlayer__get__catchAll(env, thiz);
    if (mp) {
        ijkmp_inc_ref(mp);
    }

    pthread_mutex_unlock(&g_clazz.mutex);
    return mp;
}

static IjkMediaPlayer *jni_set_media_player(JNIEnv* env, jobject thiz, IjkMediaPlayer *mp)
{
    pthread_mutex_lock(&g_clazz.mutex);

    IjkMediaPlayer *old = (IjkMediaPlayer*) (intptr_t) J4AC_IjkMediaPlayer__mNativeMediaPlayer__get__catchAll(env, thiz);
    if (mp) {
        ijkmp_inc_ref(mp);
    }
    J4AC_IjkMediaPlayer__mNativeMediaPlayer__set__catchAll(env, thiz, (intptr_t) mp);

    pthread_mutex_unlock(&g_clazz.mutex);

    // NOTE: ijkmp_dec_ref may block thread
    if (old != NULL ) {
        ijkmp_dec_ref_p(&old);
    }

    return old;
}

static int64_t jni_set_media_data_source(JNIEnv* env, jobject thiz, jobject media_data_source)
{
    int64_t nativeMediaDataSource = 0;

    pthread_mutex_lock(&g_clazz.mutex);

    jobject old = (jobject) (intptr_t) J4AC_IjkMediaPlayer__mNativeMediaDataSource__get__catchAll(env, thiz);
    if (old) {
        J4AC_IMediaDataSource__close__catchAll(env, old);
        J4A_DeleteGlobalRef__p(env, &old);
        J4AC_IjkMediaPlayer__mNativeMediaDataSource__set__catchAll(env, thiz, 0);
    }

    if (media_data_source) {
        jobject global_media_data_source = (*env)->NewGlobalRef(env, media_data_source);
        if (J4A_ExceptionCheck__catchAll(env) || !global_media_data_source)
            goto fail;

        nativeMediaDataSource = (int64_t) (intptr_t) global_media_data_source;
        J4AC_IjkMediaPlayer__mNativeMediaDataSource__set__catchAll(env, thiz, (jlong) nativeMediaDataSource);
    }

fail:
    pthread_mutex_unlock(&g_clazz.mutex);
    return nativeMediaDataSource;
}

static int64_t jni_set_ijkio_androidio(JNIEnv* env, jobject thiz, jobject ijk_io)
{
    int64_t nativeAndroidIO = 0;

    pthread_mutex_lock(&g_clazz.mutex);

    jobject old = (jobject) (intptr_t) J4AC_IjkMediaPlayer__mNativeAndroidIO__get__catchAll(env, thiz);
    if (old) {
        J4AC_IAndroidIO__close__catchAll(env, old);
        J4A_DeleteGlobalRef__p(env, &old);
        J4AC_IjkMediaPlayer__mNativeAndroidIO__set__catchAll(env, thiz, 0);
    }

    if (ijk_io) {
        jobject global_ijkio_androidio = (*env)->NewGlobalRef(env, ijk_io);
        if (J4A_ExceptionCheck__catchAll(env) || !global_ijkio_androidio)
            goto fail;

        nativeAndroidIO = (int64_t) (intptr_t) global_ijkio_androidio;
        J4AC_IjkMediaPlayer__mNativeAndroidIO__set__catchAll(env, thiz, (jlong) nativeAndroidIO);
    }

fail:
    pthread_mutex_unlock(&g_clazz.mutex);
    return nativeAndroidIO;
}

static int message_loop(void *arg);

static void
IjkMediaPlayer_setDataSourceAndHeaders(
    JNIEnv *env, jobject thiz, jstring path,
    jobjectArray keys, jobjectArray values)
{
    MPTRACE("%s\n", __func__);
    int retval = 0;
    const char *c_path = NULL;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(path, env, "java/lang/IllegalArgumentException", "mpjni: setDataSource: null path", LABEL_RETURN);
    JNI_CHECK_GOTO(mp, env, "java/lang/IllegalStateException", "mpjni: setDataSource: null mp", LABEL_RETURN);

    c_path = (*env)->GetStringUTFChars(env, path, NULL );
    JNI_CHECK_GOTO(c_path, env, "java/lang/OutOfMemoryError", "mpjni: setDataSource: path.string oom", LABEL_RETURN);

    ALOGV("setDataSource: path %s", c_path);
    retval = ijkmp_set_data_source(mp, c_path);
    (*env)->ReleaseStringUTFChars(env, path, c_path);

    IJK_CHECK_MPRET_GOTO(retval, env, LABEL_RETURN);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static void
IjkMediaPlayer_setDataSourceFd(JNIEnv *env, jobject thiz, jint fd)
{
    MPTRACE("%s\n", __func__);
    int retval = 0;
    int dupFd = 0;
    char uri[128];
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(fd > 0, env, "java/lang/IllegalArgumentException", "mpjni: setDataSourceFd: null fd", LABEL_RETURN);
    JNI_CHECK_GOTO(mp, env, "java/lang/IllegalStateException", "mpjni: setDataSourceFd: null mp", LABEL_RETURN);

    dupFd = dup(fd);

    ALOGV("setDataSourceFd: dup(%d)=%d\n", fd, dupFd);
    snprintf(uri, sizeof(uri), "pipe:%d", dupFd);
    retval = ijkmp_set_data_source(mp, uri);

    IJK_CHECK_MPRET_GOTO(retval, env, LABEL_RETURN);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static void
IjkMediaPlayer_setDataSourceCallback(JNIEnv *env, jobject thiz, jobject callback)
{
    MPTRACE("%s\n", __func__);
    int retval = 0;
    char uri[128];
    int64_t nativeMediaDataSource = 0;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(callback, env, "java/lang/IllegalArgumentException", "mpjni: setDataSourceCallback: null fd", LABEL_RETURN);
    JNI_CHECK_GOTO(mp, env, "java/lang/IllegalStateException", "mpjni: setDataSourceCallback: null mp", LABEL_RETURN);

    nativeMediaDataSource = jni_set_media_data_source(env, thiz, callback);
    JNI_CHECK_GOTO(nativeMediaDataSource, env, "java/lang/IllegalStateException", "mpjni: jni_set_media_data_source: NewGlobalRef", LABEL_RETURN);

    ALOGV("setDataSourceCallback: %"PRId64"\n", nativeMediaDataSource);
    snprintf(uri, sizeof(uri), "ijkmediadatasource:%"PRId64, nativeMediaDataSource);

    retval = ijkmp_set_data_source(mp, uri);

    IJK_CHECK_MPRET_GOTO(retval, env, LABEL_RETURN);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static void
IjkMediaPlayer_setAndroidIOCallback(JNIEnv *env, jobject thiz, jobject callback) {
    MPTRACE("%s\n", __func__);
    int64_t nativeAndroidIO = 0;

    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(callback, env, "java/lang/IllegalArgumentException", "mpjni: setAndroidIOCallback: null fd", LABEL_RETURN);
    JNI_CHECK_GOTO(mp, env, "java/lang/IllegalStateException", "mpjni: setAndroidIOCallback: null mp", LABEL_RETURN);

    nativeAndroidIO = jni_set_ijkio_androidio(env, thiz, callback);
    JNI_CHECK_GOTO(nativeAndroidIO, env, "java/lang/IllegalStateException", "mpjni: jni_set_ijkio_androidio: NewGlobalRef", LABEL_RETURN);

    ijkmp_set_option_int(mp, FFP_OPT_CATEGORY_FORMAT, "androidio-inject-callback", nativeAndroidIO);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static void
IjkMediaPlayer_setVideoSurface(JNIEnv *env, jobject thiz, jobject jsurface)
{
    MPTRACE("%s\n", __func__);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: setVideoSurface: null mp", LABEL_RETURN);

    ijkmp_android_set_surface(env, mp, jsurface);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return;
}

static void
IjkMediaPlayer_prepareAsync(JNIEnv *env, jobject thiz)
{
    MPTRACE("%s\n", __func__);
    int retval = 0;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, "java/lang/IllegalStateException", "mpjni: prepareAsync: null mp", LABEL_RETURN);

    retval = ijkmp_prepare_async(mp);
    IJK_CHECK_MPRET_GOTO(retval, env, LABEL_RETURN);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static void
IjkMediaPlayer_start(JNIEnv *env, jobject thiz)
{
    MPTRACE("%s\n", __func__);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, "java/lang/IllegalStateException", "mpjni: start: null mp", LABEL_RETURN);

    ijkmp_start(mp);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static void
IjkMediaPlayer_stop(JNIEnv *env, jobject thiz)
{
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, "java/lang/IllegalStateException", "mpjni: stop: null mp", LABEL_RETURN);

    ijkmp_stop(mp);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static void
IjkMediaPlayer_pause(JNIEnv *env, jobject thiz)
{
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, "java/lang/IllegalStateException", "mpjni: pause: null mp", LABEL_RETURN);

    ijkmp_pause(mp);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static void
IjkMediaPlayer_seekTo(JNIEnv *env, jobject thiz, jlong msec)
{
    MPTRACE("%s\n", __func__);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, "java/lang/IllegalStateException", "mpjni: seekTo: null mp", LABEL_RETURN);

    ijkmp_seek_to(mp, msec);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static jboolean
IjkMediaPlayer_isPlaying(JNIEnv *env, jobject thiz)
{
    jboolean retval = JNI_FALSE;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: isPlaying: null mp", LABEL_RETURN);

    retval = ijkmp_is_playing(mp) ? JNI_TRUE : JNI_FALSE;

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

static jlong
IjkMediaPlayer_getCurrentPosition(JNIEnv *env, jobject thiz)
{
    jlong retval = 0;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: getCurrentPosition: null mp", LABEL_RETURN);

    retval = ijkmp_get_current_position(mp);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

static jlong
IjkMediaPlayer_getDuration(JNIEnv *env, jobject thiz)
{
    jlong retval = 0;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: getDuration: null mp", LABEL_RETURN);

    retval = ijkmp_get_duration(mp);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

static void
IjkMediaPlayer_release(JNIEnv *env, jobject thiz)
{
    MPTRACE("%s\n", __func__);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    if (!mp)
        return;

    ijkmp_android_set_surface(env, mp, NULL);
    // explicit shutdown mp, in case it is not the last mp-ref here
    ijkmp_shutdown(mp);
    //only delete weak_thiz at release
    jobject weak_thiz = (jobject) ijkmp_set_weak_thiz(mp, NULL );
    (*env)->DeleteGlobalRef(env, weak_thiz);
    jni_set_media_player(env, thiz, NULL);
    jni_set_media_data_source(env, thiz, NULL);

    ijkmp_dec_ref_p(&mp);
}

static void IjkMediaPlayer_native_setup(JNIEnv *env, jobject thiz, jobject weak_this);
static void
IjkMediaPlayer_reset(JNIEnv *env, jobject thiz)
{
    MPTRACE("%s\n", __func__);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    if (!mp)
        return;

    jobject weak_thiz = (jobject) ijkmp_set_weak_thiz(mp, NULL );

    IjkMediaPlayer_release(env, thiz);
    IjkMediaPlayer_native_setup(env, thiz, weak_thiz);

    ijkmp_dec_ref_p(&mp);
}

static void
IjkMediaPlayer_setLoopCount(JNIEnv *env, jobject thiz, jint loop_count)
{
    MPTRACE("%s\n", __func__);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: setLoopCount: null mp", LABEL_RETURN);

    ijkmp_set_loop(mp, loop_count);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static jint
IjkMediaPlayer_getLoopCount(JNIEnv *env, jobject thiz)
{
    jint loop_count = 1;
    MPTRACE("%s\n", __func__);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: getLoopCount: null mp", LABEL_RETURN);

    loop_count = ijkmp_get_loop(mp);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return loop_count;
}

static jfloat
ijkMediaPlayer_getPropertyFloat(JNIEnv *env, jobject thiz, jint id, jfloat default_value)
{
    jfloat value = default_value;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: getPropertyFloat: null mp", LABEL_RETURN);

    value = ijkmp_get_property_float(mp, id, default_value);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return value;
}

static void
ijkMediaPlayer_setPropertyFloat(JNIEnv *env, jobject thiz, jint id, jfloat value)
{
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: setPropertyFloat: null mp", LABEL_RETURN);

    ijkmp_set_property_float(mp, id, value);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return;
}

static jlong
ijkMediaPlayer_getPropertyLong(JNIEnv *env, jobject thiz, jint id, jlong default_value)
{
    jlong value = default_value;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: getPropertyLong: null mp", LABEL_RETURN);

    value = ijkmp_get_property_int64(mp, id, default_value);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return value;
}

static void
ijkMediaPlayer_setPropertyLong(JNIEnv *env, jobject thiz, jint id, jlong value)
{
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: setPropertyLong: null mp", LABEL_RETURN);

    ijkmp_set_property_int64(mp, id, value);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return;
}

static void
ijkMediaPlayer_setStreamSelected(JNIEnv *env, jobject thiz, jint stream, jboolean selected)
{
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    int ret = 0;
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: setStreamSelected: null mp", LABEL_RETURN);

    ret = ijkmp_set_stream_selected(mp, stream, selected);
    if (ret < 0) {
        ALOGE("failed to %s %d", selected ? "select" : "deselect", stream);
        goto LABEL_RETURN;
    }

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return;
}

static void
IjkMediaPlayer_setVolume(JNIEnv *env, jobject thiz, jfloat leftVolume, jfloat rightVolume)
{
    MPTRACE("%s\n", __func__);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: setVolume: null mp", LABEL_RETURN);

    ijkmp_android_set_volume(env, mp, leftVolume, rightVolume);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static jint
IjkMediaPlayer_getAudioSessionId(JNIEnv *env, jobject thiz)
{
    jint audio_session_id = 0;
    MPTRACE("%s\n", __func__);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: getAudioSessionId: null mp", LABEL_RETURN);

    audio_session_id = ijkmp_android_get_audio_session_id(env, mp);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return audio_session_id;
}

static void
IjkMediaPlayer_setOption(JNIEnv *env, jobject thiz, jint category, jobject name, jobject value)
{
    MPTRACE("%s\n", __func__);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    const char *c_name = NULL;
    const char *c_value = NULL;
    JNI_CHECK_GOTO(mp, env, "java/lang/IllegalStateException", "mpjni: setOption: null mp", LABEL_RETURN);

    if (!name) {
        goto LABEL_RETURN;
    }

    c_name = (*env)->GetStringUTFChars(env, name, NULL );
    JNI_CHECK_GOTO(c_name, env, "java/lang/OutOfMemoryError", "mpjni: setOption: name.string oom", LABEL_RETURN);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: IjkMediaPlayer_setOption: null name", LABEL_RETURN);

    if (value) {
        c_value = (*env)->GetStringUTFChars(env, value, NULL );
        JNI_CHECK_GOTO(c_name, env, "java/lang/OutOfMemoryError", "mpjni: setOption: name.string oom", LABEL_RETURN);
    }

    ijkmp_set_option(mp, category, c_name, c_value);

LABEL_RETURN:
    if (c_name)
        (*env)->ReleaseStringUTFChars(env, name, c_name);
    if (c_value)
        (*env)->ReleaseStringUTFChars(env, value, c_value);
    ijkmp_dec_ref_p(&mp);
}

static void
IjkMediaPlayer_setOptionLong(JNIEnv *env, jobject thiz, jint category, jobject name, jlong value)
{
    MPTRACE("%s\n", __func__);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    const char *c_name = NULL;
    JNI_CHECK_GOTO(mp, env, "java/lang/IllegalStateException", "mpjni: setOptionLong: null mp", LABEL_RETURN);

    c_name = (*env)->GetStringUTFChars(env, name, NULL );
    JNI_CHECK_GOTO(c_name, env, "java/lang/OutOfMemoryError", "mpjni: setOptionLong: name.string oom", LABEL_RETURN);

    ijkmp_set_option_int(mp, category, c_name, value);

LABEL_RETURN:
    if (c_name)
        (*env)->ReleaseStringUTFChars(env, name, c_name);
    ijkmp_dec_ref_p(&mp);
}

static jstring
IjkMediaPlayer_getColorFormatName(JNIEnv *env, jclass clazz, jint mediaCodecColorFormat)
{
    (void)env; (void)clazz; (void)mediaCodecColorFormat;
    /* 最小可播放（软解，无 MediaCodec）：返回 NULL */
    return NULL;
}

static jstring
IjkMediaPlayer_getVideoCodecInfo(JNIEnv *env, jobject thiz)
{
    (void)env; (void)thiz;
    /* 最小可播放（软解，无 MediaCodec）：返回 NULL */
    return NULL;
}

static jstring
IjkMediaPlayer_getAudioCodecInfo(JNIEnv *env, jobject thiz)
{
    (void)env; (void)thiz;
    /* 最小可播放（软解，无 MediaCodec）：返回 NULL */
    return NULL;
}

inline static void fillMetaInternal(JNIEnv *env, jobject jbundle, IjkMediaMeta *meta, const char *key, const char *default_value)
{
    const char *value = ijkmeta_get_string_l(meta, key);
    if (value == NULL )
        value = default_value;

    J4AC_Bundle__putString__withCString__catchAll(env, jbundle, key, value);
}

static jobject
IjkMediaPlayer_getMediaMeta(JNIEnv *env, jobject thiz)
{
    MPTRACE("%s\n", __func__);
    bool is_locked = false;
    jobject jret_bundle = NULL;
    jobject jlocal_bundle = NULL;
    jobject jstream_bundle = NULL;
    jobject jarray_list = NULL;
    IjkMediaMeta *meta = NULL;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, "java/lang/IllegalStateException", "mpjni: getMediaMeta: null mp", LABEL_RETURN);

    meta = ijkmp_get_meta_l(mp);
    if (!meta)
        goto LABEL_RETURN;

    ijkmeta_lock(meta);
    is_locked = true;

    jlocal_bundle = J4AC_Bundle__Bundle(env);
    if (J4A_ExceptionCheck__throwAny(env)) {
        goto LABEL_RETURN;
    }

    fillMetaInternal(env, jlocal_bundle, meta, FSM_KEY_FORMAT, NULL );
    fillMetaInternal(env, jlocal_bundle, meta, FSM_KEY_DURATION_US, NULL );
    fillMetaInternal(env, jlocal_bundle, meta, FSM_KEY_START_US, NULL );
    fillMetaInternal(env, jlocal_bundle, meta, FSM_KEY_BITRATE, NULL );

    fillMetaInternal(env, jlocal_bundle, meta, FSM_KEY_VIDEO_STREAM, "-1");
    fillMetaInternal(env, jlocal_bundle, meta, FSM_KEY_AUDIO_STREAM, "-1");
    fillMetaInternal(env, jlocal_bundle, meta, FSM_KEY_TIMEDTEXT_STREAM, "-1");

    jarray_list = J4AC_ArrayList__ArrayList(env);
    if (J4A_ExceptionCheck__throwAny(env)) {
        goto LABEL_RETURN;
    }

    size_t count = ijkmeta_get_children_count_l(meta);
    for (size_t i = 0; i < count; ++i) {
        IjkMediaMeta *streamRawMeta = ijkmeta_get_child_l(meta, i);
        if (streamRawMeta) {
            jstream_bundle = J4AC_Bundle__Bundle(env);
            if (J4A_ExceptionCheck__throwAny(env)) {
                goto LABEL_RETURN;
            }

            fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_TYPE,     FSM_VAL_TYPE__UNKNOWN);
            fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_LANGUAGE, NULL);
            const char *type = ijkmeta_get_string_l(streamRawMeta, FSM_KEY_TYPE);
            if (type) {
                fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_CODEC_NAME, NULL );
                fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_CODEC_PROFILE, NULL );
                fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_CODEC_LEVEL, NULL );
                fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_CODEC_LONG_NAME, NULL );
                fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_CODEC_PIXEL_FORMAT, NULL );
                fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_BITRATE, NULL );
                fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_CODEC_PROFILE_ID, NULL );

                if (0 == strcmp(type, FSM_VAL_TYPE__VIDEO)) {
                    fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_WIDTH, NULL );
                    fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_HEIGHT, NULL );
                    fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_FPS_NUM, NULL );
                    fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_FPS_DEN, NULL );
                    fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_TBR_NUM, NULL );
                    fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_TBR_DEN, NULL );
                    fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_SAR_NUM, NULL );
                    fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_SAR_DEN, NULL );
                    fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_COLOR_SPACE, NULL );
                    fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_COLOR_RANGE, NULL );
                    fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_COLOR_PRIMARIES, NULL );
                    fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_COLOR_TRANSFER, NULL );
                    fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_CHROMA_LOCATION, NULL );
                    fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_DESCRIBE, NULL );
                } else if (0 == strcmp(type, FSM_VAL_TYPE__AUDIO)) {
                    fillMetaInternal(env, jstream_bundle, streamRawMeta, FSM_KEY_SAMPLE_RATE, NULL );
                }
                J4AC_ArrayList__add(env, jarray_list, jstream_bundle);
                if (J4A_ExceptionCheck__throwAny(env)) {
                    goto LABEL_RETURN;
                }
            }

            SDL_JNI_DeleteLocalRefP(env, &jstream_bundle);
        }
    }

    J4AC_Bundle__putParcelableArrayList__withCString__catchAll(env, jlocal_bundle, FSM_KEY_STREAMS, jarray_list);
    jret_bundle = jlocal_bundle;
    jlocal_bundle = NULL;
LABEL_RETURN:
    if (is_locked && meta)
        ijkmeta_unlock(meta);

    SDL_JNI_DeleteLocalRefP(env, &jstream_bundle);
    SDL_JNI_DeleteLocalRefP(env, &jlocal_bundle);
    SDL_JNI_DeleteLocalRefP(env, &jarray_list);

    ijkmp_dec_ref_p(&mp);
    return jret_bundle;
}

static void
IjkMediaPlayer_native_init(JNIEnv *env)
{
    MPTRACE("%s\n", __func__);
}

static void
IjkMediaPlayer_native_setup(JNIEnv *env, jobject thiz, jobject weak_this)
{
    MPTRACE("%s\n", __func__);
    IjkMediaPlayer *mp = ijkmp_android_create(message_loop);
    JNI_CHECK_GOTO(mp, env, "java/lang/OutOfMemoryError", "mpjni: native_setup: ijkmp_create() failed", LABEL_RETURN);

    jni_set_media_player(env, thiz, mp);
    ijkmp_set_weak_thiz(mp, (*env)->NewGlobalRef(env, weak_this));
    ijkmp_set_inject_opaque(mp, ijkmp_get_weak_thiz(mp));
    ijkmp_set_ijkio_inject_opaque(mp, ijkmp_get_weak_thiz(mp));
    ijkmp_android_set_mediacodec_select_callback(mp, mediacodec_select_callback, ijkmp_get_weak_thiz(mp));

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static void
IjkMediaPlayer_native_finalize(JNIEnv *env, jobject thiz, jobject name, jobject value)
{
    MPTRACE("%s\n", __func__);
    IjkMediaPlayer_release(env, thiz);
}

// NOTE: support to be called from read_thread
static int
inject_callback(void *opaque, int what, void *data, size_t data_size)
{
    JNIEnv     *env     = NULL;
    jobject     jbundle = NULL;
    int         ret     = -1;
    SDL_JNI_SetupThreadEnv(&env);

    jobject weak_thiz = (jobject) opaque;
    if (weak_thiz == NULL )
        goto fail;
    switch (what) {
        case AVAPP_CTRL_WILL_HTTP_OPEN:
        case AVAPP_CTRL_WILL_LIVE_OPEN:
        case AVAPP_CTRL_WILL_CONCAT_SEGMENT_OPEN: {
            AVAppIOControl *real_data = (AVAppIOControl *)data;
            real_data->is_handled = 0;

            jbundle = J4AC_Bundle__Bundle__catchAll(env);
            if (!jbundle) {
                ALOGE("%s: J4AC_Bundle__Bundle__catchAll failed for case %d\n", __func__, what);
                goto fail;
            }
            J4AC_Bundle__putString__withCString__catchAll(env, jbundle, "url", real_data->url);
            J4AC_Bundle__putInt__withCString__catchAll(env, jbundle, "segment_index", real_data->segment_index);
            J4AC_Bundle__putInt__withCString__catchAll(env, jbundle, "retry_counter", real_data->retry_counter);
            real_data->is_handled = J4AC_IjkMediaPlayer__onNativeInvoke(env, weak_thiz, what, jbundle);
            if (J4A_ExceptionCheck__catchAll(env)) {
                goto fail;
            }

            J4AC_Bundle__getString__withCString__asCBuffer(env, jbundle, "url", real_data->url, sizeof(real_data->url));
            if (J4A_ExceptionCheck__catchAll(env)) {
                goto fail;
            }
            ret = 0;
            break;
        }
        case AVAPP_EVENT_WILL_HTTP_OPEN:
        case AVAPP_EVENT_DID_HTTP_OPEN:
        case AVAPP_EVENT_WILL_HTTP_SEEK:
        case AVAPP_EVENT_DID_HTTP_SEEK: {
            AVAppHttpEvent *real_data = (AVAppHttpEvent *) data;
            jbundle = J4AC_Bundle__Bundle__catchAll(env);
            if (!jbundle) {
                ALOGE("%s: J4AC_Bundle__Bundle__catchAll failed for case %d\n", __func__, what);
                goto fail;
            }
            J4AC_Bundle__putString__withCString__catchAll(env, jbundle, "url", real_data->url);
            J4AC_Bundle__putLong__withCString__catchAll(env, jbundle, "offset", real_data->offset);
            J4AC_Bundle__putInt__withCString__catchAll(env, jbundle, "error", real_data->error);
            J4AC_Bundle__putInt__withCString__catchAll(env, jbundle, "http_code", real_data->http_code);
            J4AC_Bundle__putLong__withCString__catchAll(env, jbundle, "file_size", real_data->filesize);
            J4AC_IjkMediaPlayer__onNativeInvoke(env, weak_thiz, what, jbundle);
            if (J4A_ExceptionCheck__catchAll(env))
                goto fail;
            ret = 0;
            break;
        }
        case AVAPP_CTRL_DID_TCP_OPEN:
        case AVAPP_CTRL_WILL_TCP_OPEN: {
            AVAppTcpIOControl *real_data = (AVAppTcpIOControl *)data;
            jbundle = J4AC_Bundle__Bundle__catchAll(env);
            if (!jbundle) {
                ALOGE("%s: J4AC_Bundle__Bundle__catchAll failed for case %d\n", __func__, what);
                goto fail;
            }
            J4AC_Bundle__putInt__withCString__catchAll(env, jbundle, "error", real_data->error);
            J4AC_Bundle__putInt__withCString__catchAll(env, jbundle, "family", real_data->family);
            J4AC_Bundle__putString__withCString__catchAll(env, jbundle, "ip", real_data->ip);
            J4AC_Bundle__putInt__withCString__catchAll(env, jbundle, "port", real_data->port);
            J4AC_Bundle__putInt__withCString__catchAll(env, jbundle, "fd", real_data->fd);
            J4AC_IjkMediaPlayer__onNativeInvoke(env, weak_thiz, what, jbundle);
            if (J4A_ExceptionCheck__catchAll(env))
                goto fail;
            ret = 0;
            break;
        }
        default: {
            ret = 0;
        }
    }
fail:
    SDL_JNI_DeleteLocalRefP(env, &jbundle);
    return ret;
}

static bool mediacodec_select_callback(void *opaque, ijkmp_mediacodecinfo_context *mcc)
{
    JNIEnv *env = NULL;
    jobject weak_this = (jobject) opaque;
    const char *found_codec_name = NULL;

    if (JNI_OK != SDL_JNI_SetupThreadEnv(&env)) {
        ALOGE("%s: SetupThreadEnv failed\n", __func__);
        return -1;
    }

    found_codec_name = J4AC_IjkMediaPlayer__onSelectCodec__withCString__asCBuffer(env, weak_this, mcc->mime_type, mcc->profile, mcc->level, mcc->codec_name, sizeof(mcc->codec_name));
    if (J4A_ExceptionCheck__catchAll(env) || !found_codec_name) {
        ALOGE("%s: onSelectCodec failed\n", __func__);
        goto fail;
    }

fail:
    return found_codec_name;
}

inline static void post_event(JNIEnv *env, jobject weak_this, int what, int arg1, int arg2)
{
    // MPTRACE("post_event(%p, %p, %d, %d, %d)", (void*)env, (void*) weak_this, what, arg1, arg2);
    J4AC_IjkMediaPlayer__postEventFromNative(env, weak_this, what, arg1, arg2, NULL);
    // MPTRACE("post_event()=void");
}

inline static void post_event2(JNIEnv *env, jobject weak_this, int what, int arg1, int arg2, jobject obj)
{
    // MPTRACE("post_event2(%p, %p, %d, %d, %d, %p)", (void*)env, (void*) weak_this, what, arg1, arg2, (void*)obj);
    J4AC_IjkMediaPlayer__postEventFromNative(env, weak_this, what, arg1, arg2, obj);
    // MPTRACE("post_event2()=void");
}

static void message_loop_n(JNIEnv *env, IjkMediaPlayer *mp)
{
    jobject weak_thiz = (jobject) ijkmp_get_weak_thiz(mp);
    JNI_CHECK_GOTO(weak_thiz, env, NULL, "mpjni: message_loop_n: null weak_thiz", LABEL_RETURN);

    while (1) {
        AVMessage msg;

        int retval = ijkmp_get_msg(mp, &msg, 1);
        if (retval < 0)
            break;

        // block-get should never return 0
        assert(retval > 0);

        switch (msg.what) {
        case FFP_MSG_FLUSH:
            MPTRACE("FFP_MSG_FLUSH:\n");
            post_event(env, weak_thiz, MEDIA_NOP, 0, 0);
            break;
        case FFP_MSG_ERROR:
            MPTRACE("FFP_MSG_ERROR: %d\n", msg.arg1);
            post_event(env, weak_thiz, MEDIA_ERROR, MEDIA_ERROR_IJK_PLAYER, msg.arg1);
            break;
        case FFP_MSG_PREPARED:
            MPTRACE("FFP_MSG_PREPARED:\n");
            post_event(env, weak_thiz, MEDIA_PREPARED, 0, 0);
            break;
        case FFP_MSG_COMPLETED:
            MPTRACE("FFP_MSG_COMPLETED:\n");
            post_event(env, weak_thiz, MEDIA_PLAYBACK_COMPLETE, 0, 0);
            break;
        case FFP_MSG_VIDEO_SIZE_CHANGED:
            MPTRACE("FFP_MSG_VIDEO_SIZE_CHANGED: %d, %d\n", msg.arg1, msg.arg2);
            post_event(env, weak_thiz, MEDIA_SET_VIDEO_SIZE, msg.arg1, msg.arg2);
            break;
        case FFP_MSG_SAR_CHANGED:
            MPTRACE("FFP_MSG_SAR_CHANGED: %d, %d\n", msg.arg1, msg.arg2);
            post_event(env, weak_thiz, MEDIA_SET_VIDEO_SAR, msg.arg1, msg.arg2);
            break;
        case FFP_MSG_VIDEO_RENDERING_START:
            MPTRACE("FFP_MSG_VIDEO_RENDERING_START:\n");
            post_event(env, weak_thiz, MEDIA_INFO, MEDIA_INFO_VIDEO_RENDERING_START, 0);
            break;
        case FFP_MSG_AUDIO_RENDERING_START:
            MPTRACE("FFP_MSG_AUDIO_RENDERING_START:\n");
            post_event(env, weak_thiz, MEDIA_INFO, MEDIA_INFO_AUDIO_RENDERING_START, 0);
            break;
        case FFP_MSG_VIDEO_ROTATION_CHANGED:
            MPTRACE("FFP_MSG_VIDEO_ROTATION_CHANGED: %d\n", msg.arg1);
            post_event(env, weak_thiz, MEDIA_INFO, MEDIA_INFO_VIDEO_ROTATION_CHANGED, msg.arg1);
            break;
        case FFP_MSG_AUDIO_DECODED_START:
            MPTRACE("FFP_MSG_AUDIO_DECODED_START:\n");
            post_event(env, weak_thiz, MEDIA_INFO, MEDIA_INFO_AUDIO_DECODED_START, 0);
            break;
        case FFP_MSG_VIDEO_DECODED_START:
            MPTRACE("FFP_MSG_VIDEO_DECODED_START:\n");
            post_event(env, weak_thiz, MEDIA_INFO, MEDIA_INFO_VIDEO_DECODED_START, 0);
            break;
        case FFP_MSG_OPEN_INPUT:
            MPTRACE("FFP_MSG_OPEN_INPUT:\n");
            post_event(env, weak_thiz, MEDIA_INFO, MEDIA_INFO_OPEN_INPUT, 0);
            break;
        case FFP_MSG_FIND_STREAM_INFO:
            MPTRACE("FFP_MSG_FIND_STREAM_INFO:\n");
            post_event(env, weak_thiz, MEDIA_INFO, MEDIA_INFO_FIND_STREAM_INFO, 0);
            break;
        case FFP_MSG_COMPONENT_OPEN:
            MPTRACE("FFP_MSG_COMPONENT_OPEN:\n");
            post_event(env, weak_thiz, MEDIA_INFO, MEDIA_INFO_COMPONENT_OPEN, 0);
            break;
        case FFP_MSG_BUFFERING_START:
            MPTRACE("FFP_MSG_BUFFERING_START:\n");
            post_event(env, weak_thiz, MEDIA_INFO, MEDIA_INFO_BUFFERING_START, msg.arg1);
            break;
        case FFP_MSG_BUFFERING_END:
            MPTRACE("FFP_MSG_BUFFERING_END:\n");
            post_event(env, weak_thiz, MEDIA_INFO, MEDIA_INFO_BUFFERING_END, msg.arg1);
            break;
        case FFP_MSG_BUFFERING_UPDATE:
            // MPTRACE("FFP_MSG_BUFFERING_UPDATE: %d, %d", msg.arg1, msg.arg2);
            post_event(env, weak_thiz, MEDIA_BUFFERING_UPDATE, msg.arg1, msg.arg2);
            break;
        case FFP_MSG_BUFFERING_BYTES_UPDATE:
            break;
        case FFP_MSG_BUFFERING_TIME_UPDATE:
            break;
        case FFP_MSG_SEEK_COMPLETE:
            MPTRACE("FFP_MSG_SEEK_COMPLETE:\n");
            post_event(env, weak_thiz, MEDIA_SEEK_COMPLETE, 0, 0);
            break;
        case FFP_MSG_ACCURATE_SEEK_COMPLETE:
            MPTRACE("FFP_MSG_ACCURATE_SEEK_COMPLETE:\n");
            post_event(env, weak_thiz, MEDIA_INFO, MEDIA_INFO_MEDIA_ACCURATE_SEEK_COMPLETE, msg.arg1);
            break;
        case FFP_MSG_PLAYBACK_STATE_CHANGED:
            MPTRACE("FFP_MSG_PLAYBACK_STATE_CHANGED: %d\n", msg.arg1);
            post_event(env, weak_thiz, MEDIA_INFO, MEDIA_INFO_PLAYBACK_STATE_CHANGED, msg.arg1);
            break;
        case FFP_MSG_VIDEO_SEEK_RENDERING_START:
            MPTRACE("FFP_MSG_VIDEO_SEEK_RENDERING_START:\n");
            post_event(env, weak_thiz, MEDIA_INFO, MEDIA_INFO_VIDEO_SEEK_RENDERING_START, msg.arg1);
            break;
        case FFP_MSG_AFTER_SEEK_FIRST_FRAME:
            MPTRACE("FFP_MSG_AFTER_SEEK_FIRST_FRAME: %d\n", msg.arg1);
            post_event(env, weak_thiz, MEDIA_INFO, MEDIA_INFO_AFTER_SEEK_FIRST_FRAME, msg.arg1);
            break;
        case FFP_MSG_VIDEO_DECODER_OPEN:
            MPTRACE("FFP_MSG_VIDEO_DECODER_OPEN: %d\n", msg.arg1);
            post_event(env, weak_thiz, MEDIA_INFO, MEDIA_INFO_VIDEO_DECODER_OPEN, msg.arg1);
            break;
        case FFP_MSG_AUDIO_SEEK_RENDERING_START:
            MPTRACE("FFP_MSG_AUDIO_SEEK_RENDERING_START:\n");
            post_event(env, weak_thiz, MEDIA_INFO, MEDIA_INFO_AUDIO_SEEK_RENDERING_START, msg.arg1);
            break;
        default:
            ALOGE("unknown FFP_MSG_xxx(%d)\n", msg.what);
            break;
        }
        msg_free_res(&msg);
    }

LABEL_RETURN:
    ;
}

static int message_loop(void *arg)
{
    MPTRACE("%s\n", __func__);

    JNIEnv *env = NULL;
    if (JNI_OK != SDL_JNI_SetupThreadEnv(&env)) {
        ALOGE("%s: SetupThreadEnv failed\n", __func__);
        return -1;
    }

    IjkMediaPlayer *mp = (IjkMediaPlayer*) arg;
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: native_message_loop: null mp", LABEL_RETURN);

    message_loop_n(env, mp);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);

    MPTRACE("message_loop exit");
    return 0;
}

// ----------------------------------------------------------------------------
void monstartup(const char *libname);
void moncleanup(void);

static void
IjkMediaPlayer_native_profileBegin(JNIEnv *env, jclass clazz, jstring libName)
{
    MPTRACE("%s\n", __func__);

    const char *c_lib_name = NULL;
    static int s_monstartup = 0;

    if (!libName)
        return;

    if (s_monstartup) {
        ALOGW("monstartup already called\b");
        return;
    }

    c_lib_name = (*env)->GetStringUTFChars(env, libName, NULL );
    JNI_CHECK_GOTO(c_lib_name, env, "java/lang/OutOfMemoryError", "mpjni: monstartup: libName.string oom", LABEL_RETURN);

    s_monstartup = 1;
    monstartup(c_lib_name);
    ALOGD("monstartup: %s\n", c_lib_name);

LABEL_RETURN:
    if (c_lib_name)
        (*env)->ReleaseStringUTFChars(env, libName, c_lib_name);
}

static void
IjkMediaPlayer_native_profileEnd(JNIEnv *env, jclass clazz)
{
    MPTRACE("%s\n", __func__);
    static int s_moncleanup = 0;

    if (s_moncleanup) {
        ALOGW("moncleanu already called\b");
        return;
    }

    s_moncleanup = 1;
    moncleanup();
    ALOGD("moncleanup\n");
}

static void
IjkMediaPlayer_native_setLogLevel(JNIEnv *env, jclass clazz, jint level)
{
    MPTRACE("%s(%d)\n", __func__, level);
    ijkmp_global_set_log_level(level);
    ALOGD("moncleanup\n");
}

static void
IjkMediaPlayer_setFrameAtTime(JNIEnv *env, jobject thiz, jstring path, jlong start_time, jlong end_time, jint num, jint definition) {
    (void)thiz; (void)path; (void)start_time; (void)end_time; (void)num; (void)definition;
    /* 最小可播放：截图功能（ijkmp_set_frame_at_time）在 fsplayer 中已移除，这里 no-op */
    ALOGV("setFrameAtTime: no-op (removed in fsplayer)\n");
    (void)env;
}





// ----------------------------------------------------------------------------
// APIs ported from the iOS wrapper (FSMediaPlayback): they were already
// implemented in ijkplayer.h but had no JNI/Java front end on Android.
// ----------------------------------------------------------------------------

static void
IjkMediaPlayer_setAudioExtraDelay(JNIEnv *env, jobject thiz, jfloat delay)
{
    MPTRACE("%s(%f)\n", __func__, (double) delay);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: setAudioExtraDelay: null mp", LABEL_RETURN);

    ijkmp_set_audio_extra_delay(mp, delay);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static jfloat
IjkMediaPlayer_getAudioExtraDelay(JNIEnv *env, jobject thiz)
{
    jfloat retval = 0;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: getAudioExtraDelay: null mp", LABEL_RETURN);

    retval = ijkmp_get_audio_extra_delay(mp);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

static void
IjkMediaPlayer_setSubtitleExtraDelay(JNIEnv *env, jobject thiz, jfloat delay)
{
    MPTRACE("%s(%f)\n", __func__, (double) delay);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: setSubtitleExtraDelay: null mp", LABEL_RETURN);

    ijkmp_set_subtitle_extra_delay(mp, delay);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static jfloat
IjkMediaPlayer_getSubtitleExtraDelay(JNIEnv *env, jobject thiz)
{
    jfloat retval = 0;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: getSubtitleExtraDelay: null mp", LABEL_RETURN);

    retval = ijkmp_get_subtitle_extra_delay(mp);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

/* add an external subtitle file and activate it right away */
static jboolean
IjkMediaPlayer_loadThenActiveSubtitle(JNIEnv *env, jobject thiz, jstring path)
{
    jboolean retval = JNI_FALSE;
    const char *c_path = NULL;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: loadThenActiveSubtitle: null mp", LABEL_RETURN);
    JNI_CHECK_GOTO(path, env, "java/lang/IllegalArgumentException", "mpjni: loadThenActiveSubtitle: null path", LABEL_RETURN);

    c_path = (*env)->GetStringUTFChars(env, path, NULL);
    JNI_CHECK_GOTO(c_path, env, "java/lang/OutOfMemoryError", "mpjni: loadThenActiveSubtitle: path.string oom", LABEL_RETURN);

    retval = (ijkmp_add_active_external_subtitle(mp, c_path) == 0) ? JNI_TRUE : JNI_FALSE;
    (*env)->ReleaseStringUTFChars(env, path, c_path);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

/* add an external subtitle file but do not activate it; 0 means succ, 1 means already added */
static jint
IjkMediaPlayer_addOnlyExternalSubtitle(JNIEnv *env, jobject thiz, jstring path)
{
    jint retval = -1;
    const char *c_path = NULL;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: addOnlyExternalSubtitle: null mp", LABEL_RETURN);
    JNI_CHECK_GOTO(path, env, "java/lang/IllegalArgumentException", "mpjni: addOnlyExternalSubtitle: null path", LABEL_RETURN);

    c_path = (*env)->GetStringUTFChars(env, path, NULL);
    JNI_CHECK_GOTO(c_path, env, "java/lang/OutOfMemoryError", "mpjni: addOnlyExternalSubtitle: path.string oom", LABEL_RETURN);

    retval = ijkmp_addOnly_external_subtitle(mp, c_path);
    (*env)->ReleaseStringUTFChars(env, path, c_path);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

/* add several external subtitle files at once; returns how many were added */
static jint
IjkMediaPlayer_addOnlyExternalSubtitles(JNIEnv *env, jobject thiz, jobjectArray paths)
{
    jint retval = -1;
    jsize count = 0;
    jsize i = 0;
    const char **file_names = NULL;
    jstring *j_paths = NULL;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: addOnlyExternalSubtitles: null mp", LABEL_RETURN);
    JNI_CHECK_GOTO(paths, env, "java/lang/IllegalArgumentException", "mpjni: addOnlyExternalSubtitles: null paths", LABEL_RETURN);

    count = (*env)->GetArrayLength(env, paths);
    if (count <= 0)
        goto LABEL_RETURN;

    file_names = (const char **) calloc((size_t) count, sizeof(char *));
    j_paths = (jstring *) calloc((size_t) count, sizeof(jstring));
    JNI_CHECK_GOTO(file_names && j_paths, env, "java/lang/OutOfMemoryError", "mpjni: addOnlyExternalSubtitles: oom", LABEL_RETURN);

    for (i = 0; i < count; ++i) {
        j_paths[i] = (jstring) (*env)->GetObjectArrayElement(env, paths, i);
        if (j_paths[i]) {
            file_names[i] = (*env)->GetStringUTFChars(env, j_paths[i], NULL);
        }
    }

    retval = ijkmp_addOnly_external_subtitles(mp, file_names, (int) count);

    for (i = 0; i < count; ++i) {
        if (j_paths[i]) {
            if (file_names[i])
                (*env)->ReleaseStringUTFChars(env, j_paths[i], file_names[i]);
            (*env)->DeleteLocalRef(env, j_paths[i]);
        }
    }

LABEL_RETURN:
    free(file_names);
    free(j_paths);
    ijkmp_dec_ref_p(&mp);
    return retval;
}

/* copy a java FSSubtitlePreference into the native struct; fields are read by
 * name, so the java class has to keep exactly these field names. */
static void
IjkMediaPlayer_setSubtitlePreference(JNIEnv *env, jobject thiz, jobject sp)
{
    FSSubtitlePreference pref = fs_subtitle_default_preference();
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: setSubtitlePreference: null mp", LABEL_RETURN);

    if (sp) {
        jclass cls = (*env)->GetObjectClass(env, sp);
        jfieldID f_scale            = cls ? (*env)->GetFieldID(env, cls, "Scale", "F") : NULL;
        jfieldID f_bottom_margin    = cls ? (*env)->GetFieldID(env, cls, "BottomMargin", "F") : NULL;
        jfieldID f_force_override   = cls ? (*env)->GetFieldID(env, cls, "ForceOverride", "I") : NULL;
        jfieldID f_font_name        = cls ? (*env)->GetFieldID(env, cls, "FontName", "Ljava/lang/String;") : NULL;
        jfieldID f_primary_colour   = cls ? (*env)->GetFieldID(env, cls, "PrimaryColour", "I") : NULL;
        jfieldID f_secondary_colour = cls ? (*env)->GetFieldID(env, cls, "SecondaryColour", "I") : NULL;
        jfieldID f_back_colour      = cls ? (*env)->GetFieldID(env, cls, "BackColour", "I") : NULL;
        jfieldID f_outline_colour   = cls ? (*env)->GetFieldID(env, cls, "OutlineColour", "I") : NULL;
        jfieldID f_outline          = cls ? (*env)->GetFieldID(env, cls, "Outline", "F") : NULL;
        jfieldID f_fonts_dir        = cls ? (*env)->GetFieldID(env, cls, "FontsDir", "Ljava/lang/String;") : NULL;

        if (!f_scale || !f_bottom_margin || !f_force_override || !f_font_name ||
            !f_primary_colour || !f_secondary_colour || !f_back_colour ||
            !f_outline_colour || !f_outline || !f_fonts_dir) {
            ALOGE("setSubtitlePreference: FSSubtitlePreference fields not found\n");
            if (cls)
                (*env)->DeleteLocalRef(env, cls);
            goto LABEL_RETURN;
        }

        pref.Scale           = (*env)->GetFloatField(env, sp, f_scale);
        pref.BottomMargin    = (*env)->GetFloatField(env, sp, f_bottom_margin);
        pref.ForceOverride   = (*env)->GetIntField(env, sp, f_force_override);
        pref.PrimaryColour   = (uint32_t) (*env)->GetIntField(env, sp, f_primary_colour);
        pref.SecondaryColour = (uint32_t) (*env)->GetIntField(env, sp, f_secondary_colour);
        pref.BackColour      = (uint32_t) (*env)->GetIntField(env, sp, f_back_colour);
        pref.OutlineColour   = (uint32_t) (*env)->GetIntField(env, sp, f_outline_colour);
        pref.Outline         = (*env)->GetFloatField(env, sp, f_outline);

        jstring j_font_name = (jstring) (*env)->GetObjectField(env, sp, f_font_name);
        if (j_font_name) {
            const char *c_font_name = (*env)->GetStringUTFChars(env, j_font_name, NULL);
            if (c_font_name) {
                snprintf(pref.FontName, sizeof(pref.FontName), "%s", c_font_name);
                (*env)->ReleaseStringUTFChars(env, j_font_name, c_font_name);
            }
            (*env)->DeleteLocalRef(env, j_font_name);
        }

        jstring j_fonts_dir = (jstring) (*env)->GetObjectField(env, sp, f_fonts_dir);
        if (j_fonts_dir) {
            const char *c_fonts_dir = (*env)->GetStringUTFChars(env, j_fonts_dir, NULL);
            if (c_fonts_dir) {
                snprintf(pref.FontsDir, sizeof(pref.FontsDir), "%s", c_fonts_dir);
                (*env)->ReleaseStringUTFChars(env, j_fonts_dir, c_fonts_dir);
            }
            (*env)->DeleteLocalRef(env, j_fonts_dir);
        }

        (*env)->DeleteLocalRef(env, cls);
    }

    ijkmp_set_subtitle_preference(mp, &pref);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static void
IjkMediaPlayer_stepToNextFrame(JNIEnv *env, jobject thiz)
{
    MPTRACE("%s\n", __func__);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: stepToNextFrame: null mp", LABEL_RETURN);

    ijkmp_step_to_next_frame(mp);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static void
IjkMediaPlayer_enableAccurateSeek(JNIEnv *env, jobject thiz, jboolean open)
{
    MPTRACE("%s(%d)\n", __func__, (int) open);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: enableAccurateSeek: null mp", LABEL_RETURN);

    ijkmp_set_enable_accurate_seek(mp, open ? 1 : 0);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static jlong
IjkMediaPlayer_getPlayableDuration(JNIEnv *env, jobject thiz)
{
    jlong retval = 0;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: getPlayableDuration: null mp", LABEL_RETURN);

    retval = ijkmp_get_playable_duration(mp);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

/*
 * 取当前画面的快照。返回 RGBA8888 像素（宽*高*4，行紧凑），失败返回 null；
 * outSize 回填 {width, height}，格式见 ijksdl/android/vulkan/fs_vulkan_renderer.h 的 FSSnapshotType。
 */
static jbyteArray
IjkMediaPlayer_takeSnapshot(JNIEnv *env, jobject thiz, jint type, jintArray out_size)
{
    jbyteArray retval = NULL;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: takeSnapshot: null mp", LABEL_RETURN);

    int w = 0, h = 0;
    void *pixels = NULL;
    if (ijkmp_android_take_snapshot(mp, (int) type, &w, &h, &pixels) == 0
            && pixels && w > 0 && h > 0) {
        jsize size = (jsize) w * h * 4;
        retval = (*env)->NewByteArray(env, size);
        if (retval) {
            (*env)->SetByteArrayRegion(env, retval, 0, size, (const jbyte *) pixels);
            if (out_size) {
                jint dims[2];
                dims[0] = (jint) w;
                dims[1] = (jint) h;
                (*env)->SetIntArrayRegion(env, out_size, 0, 2, dims);
            }
        }
    }
    free(pixels);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

/*
 * 高斯模糊背景：rgba 是 RGBA8888（调用方负责降采样到最长边 400），传 null 清除背景。
 * 渲染器还没建好（还没 setSurface）时会失败，Java 侧会在设置 surface 后重试。
 */
static void
IjkMediaPlayer_setBackgroundImage(JNIEnv *env, jobject thiz, jbyteArray rgba, jint width, jint height)
{
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: setBackgroundImage: null mp", LABEL_RETURN);

    void *pixels = NULL;
    if (rgba && width > 0 && height > 0) {
        jsize need = (jsize) width * height * 4;
        if (need > 0 && (*env)->GetArrayLength(env, rgba) >= need) {
            pixels = malloc(need);
            if (pixels) {
                (*env)->GetByteArrayRegion(env, rgba, 0, need, (jbyte *) pixels);
            }
        }
    }
    ijkmp_android_set_background_image(mp, pixels, width, height);
    free(pixels);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static void
IjkMediaPlayer_setBackgroundBlur(JNIEnv *env, jobject thiz, jint iterations, jfloat sigma)
{
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: setBackgroundBlur: null mp", LABEL_RETURN);

    ijkmp_android_set_background_blur(mp, iterations, sigma);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

/*
 * 色彩调整：亮度/饱和度/对比度，默认都是 1.0。对齐 iOS 的 colorPreference。
 * 渲染器还没建好（还没 setSurface）时会失败，Java 侧会在设置 surface 后重试。
 */
static void
IjkMediaPlayer_setColorAdjust(JNIEnv *env, jobject thiz, jfloat brightness, jfloat saturation, jfloat contrast)
{
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: setColorAdjust: null mp", LABEL_RETURN);

    ijkmp_android_set_color_adjust(mp, brightness, saturation, contrast);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

/* 无视频区域（黑边）的背景色，0~255。对齐 iOS 的 -setBackgroundColor:g:b:。 */
static void
IjkMediaPlayer_setBackgroundColor(JNIEnv *env, jobject thiz, jint red, jint green, jint blue)
{
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: setBackgroundColor: null mp", LABEL_RETURN);

    ijkmp_android_set_background_color(mp, red, green, blue);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

/* HDR 直显开关，对齐 iOS 的 allowHDRDirectDisplay */
static void
IjkMediaPlayer_native_setAllowHDRDirectDisplay(JNIEnv *env, jobject thiz, jboolean allow)
{
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: setAllowHDRDirectDisplay: null mp", LABEL_RETURN);

    ijkmp_android_set_allow_hdr_direct_display(mp, allow ? 1 : 0);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static jboolean
IjkMediaPlayer_native_isDirectDisplayHDRSupported(JNIEnv *env, jobject thiz)
{
    jboolean retval = JNI_FALSE;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: isDirectDisplayHDRSupported: null mp", LABEL_RETURN);

    retval = ijkmp_android_is_direct_display_hdr_supported(mp) ? JNI_TRUE : JNI_FALSE;

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

static jboolean
IjkMediaPlayer_native_isHDRContent(JNIEnv *env, jobject thiz)
{
    jboolean retval = JNI_FALSE;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: isHDRContent: null mp", LABEL_RETURN);

    retval = ijkmp_android_is_hdr_content(mp) ? JNI_TRUE : JNI_FALSE;

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

/* type: 1 audio, 2 video, 3 subtitle */
static jint
IjkMediaPlayer_getFrameCacheRemaining(JNIEnv *env, jobject thiz, jint type)
{
    jint retval = 0;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: getFrameCacheRemaining: null mp", LABEL_RETURN);

    retval = ijkmp_get_frame_cache_remaining(mp, type);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

static void
IjkMediaPlayer_setDeinterlace(JNIEnv *env, jobject thiz, jint deinterlace)
{
    MPTRACE("%s(%d)\n", __func__, (int) deinterlace);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: setDeinterlace: null mp", LABEL_RETURN);

    ijkmp_set_deinterlace(mp, deinterlace);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static jint
IjkMediaPlayer_getDeinterlace(JNIEnv *env, jobject thiz)
{
    jint retval = 0;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: getDeinterlace: null mp", LABEL_RETURN);

    retval = ijkmp_get_deinterlace(mp);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

/* ask the vout to redraw the current frame, e.g. after the surface changed */
static void
IjkMediaPlayer_refreshPicture(JNIEnv *env, jobject thiz)
{
    MPTRACE("%s\n", __func__);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: refreshPicture: null mp", LABEL_RETURN);

    ijkmp_refresh_picture(mp);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

static jint
IjkMediaPlayer_reloadVideoStream(JNIEnv *env, jobject thiz)
{
    jint retval = 0;
    MPTRACE("%s\n", __func__);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: reloadVideoStream: null mp", LABEL_RETURN);

    retval = ijkmp_reload_video_stream(mp);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

static jstring
IjkMediaPlayer_getIFormatExtensions(JNIEnv *env, jobject thiz)
{
    jstring retval = NULL;
    const char *extensions = NULL;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: getIFormatExtensions: null mp", LABEL_RETURN);

    extensions = ijkmp_get_iformat_extensions(mp);
    if (extensions)
        retval = (*env)->NewStringUTF(env, extensions);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

static jstring
IjkMediaPlayer_getPlayerVersion(JNIEnv *env, jclass clazz)
{
    return (*env)->NewStringUTF(env, ijkmp_version());
}

static jstring
IjkMediaPlayer_getFFmpegVersion(JNIEnv *env, jclass clazz)
{
    return (*env)->NewStringUTF(env, av_version_info());
}

static jint
IjkMediaPlayer_startFastRecord(JNIEnv *env, jobject thiz, jstring path)
{
    jint retval = -1;
    const char *c_path = NULL;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: startFastRecord: null mp", LABEL_RETURN);
    JNI_CHECK_GOTO(path, env, "java/lang/IllegalArgumentException", "mpjni: startFastRecord: null path", LABEL_RETURN);

    c_path = (*env)->GetStringUTFChars(env, path, NULL);
    JNI_CHECK_GOTO(c_path, env, "java/lang/OutOfMemoryError", "mpjni: startFastRecord: path.string oom", LABEL_RETURN);

    retval = ijkmp_start_fast_record(mp, c_path);
    (*env)->ReleaseStringUTFChars(env, path, c_path);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

static jint
IjkMediaPlayer_stopFastRecord(JNIEnv *env, jobject thiz)
{
    jint retval = -1;
    MPTRACE("%s\n", __func__);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: stopFastRecord: null mp", LABEL_RETURN);

    retval = ijkmp_stop_fast_record(mp);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

static jint
IjkMediaPlayer_startExactRecord(JNIEnv *env, jobject thiz, jstring path)
{
    jint retval = -1;
    const char *c_path = NULL;
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: startExactRecord: null mp", LABEL_RETURN);
    JNI_CHECK_GOTO(path, env, "java/lang/IllegalArgumentException", "mpjni: startExactRecord: null path", LABEL_RETURN);

    c_path = (*env)->GetStringUTFChars(env, path, NULL);
    JNI_CHECK_GOTO(c_path, env, "java/lang/OutOfMemoryError", "mpjni: startExactRecord: path.string oom", LABEL_RETURN);

    retval = ijkmp_start_exact_record(mp, c_path);
    (*env)->ReleaseStringUTFChars(env, path, c_path);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

static jint
IjkMediaPlayer_stopExactRecord(JNIEnv *env, jobject thiz)
{
    jint retval = -1;
    MPTRACE("%s\n", __func__);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: stopExactRecord: null mp", LABEL_RETURN);

    retval = ijkmp_stop_exact_record(mp);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
    return retval;
}

static jint
IjkMediaPlayer_native_getLogLevel(JNIEnv *env, jclass clazz)
{
    (void) env; (void) clazz;
    return ijkmp_global_get_log_level();
}

static void
IjkMediaPlayer_native_setLogReport(JNIEnv *env, jclass clazz, jint useReport)
{
    (void) env; (void) clazz;
    MPTRACE("%s(%d)\n", __func__, (int) useReport);
    ijkmp_global_set_log_report(useReport);
}

/* ---------------------------------------------------------------------------
 * audio samples observer
 *
 * The callback runs on the audio thread, so the env has to be attached. It is
 * invoked from the decode loop, and the short[] handed to java is only valid
 * while the callback runs: copy it if you want to keep it.
 * ------------------------------------------------------------------------ */

static jmethodID g_post_audio_samples_mid = NULL;

static int
audio_samples_callback(void *opaque, int16_t *samples, int sampleSize, int sampleRate, int channels)
{
    JNIEnv *env = NULL;
    jshortArray j_samples = NULL;

    if (!opaque)
        return 0;

    if (SDL_JNI_SetupThreadEnv(&env) != 0 || !env) {
        ALOGE("audio_samples_callback: SetupThreadEnv failed\n");
        return -1;
    }

    if (!g_post_audio_samples_mid) {
        g_post_audio_samples_mid = (*env)->GetStaticMethodID(env, g_clazz.clazz,
            "postAudioSamplesEventFromNative", "(Ljava/lang/Object;[SII)V");
        if (J4A_ExceptionCheck__catchAll(env) || !g_post_audio_samples_mid) {
            ALOGE("audio_samples_callback: postAudioSamplesEventFromNative not found\n");
            g_post_audio_samples_mid = NULL;
            return -1;
        }
    }

    if (samples && sampleSize > 0) {
        /* the native sampleSize is a byte count (see update_sample_display in
         * ff_ffplay.c, where windowSize is compared against the buffer size in
         * bytes), so the number of int16 samples in the window is half of it */
        jsize sample_count = (jsize) (sampleSize / sizeof(int16_t));

        if (sample_count > 0) {
            j_samples = (*env)->NewShortArray(env, sample_count);
            if (!j_samples || J4A_ExceptionCheck__catchAll(env)) {
                ALOGE("audio_samples_callback: NewShortArray failed\n");
                return -1;
            }
            (*env)->SetShortArrayRegion(env, j_samples, 0, sample_count, (const jshort *) samples);
        }
    }

    (*env)->CallStaticVoidMethod(env, g_clazz.clazz, g_post_audio_samples_mid,
                                 (jobject) opaque, j_samples, (jint) sampleRate, (jint) channels);
    J4A_ExceptionCheck__catchAll(env);

    if (j_samples)
        (*env)->DeleteLocalRef(env, j_samples);

    return 0;
}

static void
IjkMediaPlayer_setAudioSamplesObserver(JNIEnv *env, jobject thiz, jboolean enable)
{
    MPTRACE("%s(%d)\n", __func__, (int) enable);
    IjkMediaPlayer *mp = jni_get_media_player(env, thiz);
    JNI_CHECK_GOTO(mp, env, NULL, "mpjni: setAudioSamplesObserver: null mp", LABEL_RETURN);

    ijkmp_set_audio_sample_observer(mp, enable ? audio_samples_callback : NULL);

LABEL_RETURN:
    ijkmp_dec_ref_p(&mp);
}

// ----------------------------------------------------------------------------

static JNINativeMethod g_methods[] = {
    {
        "_setDataSource",
        "(Ljava/lang/String;[Ljava/lang/String;[Ljava/lang/String;)V",
        (void *) IjkMediaPlayer_setDataSourceAndHeaders
    },
    { "_setDataSourceFd",       "(I)V",     (void *) IjkMediaPlayer_setDataSourceFd },
    { "_setDataSource",         "(Ltv/danmaku/ijk/media/player/misc/IMediaDataSource;)V", (void *)IjkMediaPlayer_setDataSourceCallback },
    { "_setAndroidIOCallback",  "(Ltv/danmaku/ijk/media/player/misc/IAndroidIO;)V", (void *)IjkMediaPlayer_setAndroidIOCallback },

    { "_setVideoSurface",       "(Landroid/view/Surface;)V", (void *) IjkMediaPlayer_setVideoSurface },
    { "_prepareAsync",          "()V",      (void *) IjkMediaPlayer_prepareAsync },
    { "_start",                 "()V",      (void *) IjkMediaPlayer_start },
    { "_stop",                  "()V",      (void *) IjkMediaPlayer_stop },
    { "seekTo",                 "(J)V",     (void *) IjkMediaPlayer_seekTo },
    { "_pause",                 "()V",      (void *) IjkMediaPlayer_pause },
    { "isPlaying",              "()Z",      (void *) IjkMediaPlayer_isPlaying },
    { "getCurrentPosition",     "()J",      (void *) IjkMediaPlayer_getCurrentPosition },
    { "getDuration",            "()J",      (void *) IjkMediaPlayer_getDuration },
    { "_release",               "()V",      (void *) IjkMediaPlayer_release },
    { "_reset",                 "()V",      (void *) IjkMediaPlayer_reset },
    { "setVolume",              "(FF)V",    (void *) IjkMediaPlayer_setVolume },
    { "getAudioSessionId",      "()I",      (void *) IjkMediaPlayer_getAudioSessionId },
    { "native_init",            "()V",      (void *) IjkMediaPlayer_native_init },
    { "native_setup",           "(Ljava/lang/Object;)V", (void *) IjkMediaPlayer_native_setup },
    { "native_finalize",        "()V",      (void *) IjkMediaPlayer_native_finalize },

    { "_setOption",             "(ILjava/lang/String;Ljava/lang/String;)V", (void *) IjkMediaPlayer_setOption },
    { "_setOption",             "(ILjava/lang/String;J)V",                  (void *) IjkMediaPlayer_setOptionLong },

    { "_getColorFormatName",    "(I)Ljava/lang/String;",    (void *) IjkMediaPlayer_getColorFormatName },
    { "_getVideoCodecInfo",     "()Ljava/lang/String;",     (void *) IjkMediaPlayer_getVideoCodecInfo },
    { "_getAudioCodecInfo",     "()Ljava/lang/String;",     (void *) IjkMediaPlayer_getAudioCodecInfo },
    { "_getMediaMeta",          "()Landroid/os/Bundle;",    (void *) IjkMediaPlayer_getMediaMeta },
    { "_setLoopCount",          "(I)V",                     (void *) IjkMediaPlayer_setLoopCount },
    { "_getLoopCount",          "()I",                      (void *) IjkMediaPlayer_getLoopCount },
    { "_getPropertyFloat",      "(IF)F",                    (void *) ijkMediaPlayer_getPropertyFloat },
    { "_setPropertyFloat",      "(IF)V",                    (void *) ijkMediaPlayer_setPropertyFloat },
    { "_getPropertyLong",       "(IJ)J",                    (void *) ijkMediaPlayer_getPropertyLong },
    { "_setPropertyLong",       "(IJ)V",                    (void *) ijkMediaPlayer_setPropertyLong },
    { "_setStreamSelected",     "(IZ)V",                    (void *) ijkMediaPlayer_setStreamSelected },

    { "native_profileBegin",    "(Ljava/lang/String;)V",    (void *) IjkMediaPlayer_native_profileBegin },
    { "native_profileEnd",      "()V",                      (void *) IjkMediaPlayer_native_profileEnd },

    { "native_setLogLevel",     "(I)V",                     (void *) IjkMediaPlayer_native_setLogLevel },
    { "_setFrameAtTime",        "(Ljava/lang/String;JJII)V", (void *) IjkMediaPlayer_setFrameAtTime },

    /* ported from the iOS wrapper */
    { "setAudioExtraDelay",       "(F)V",                     (void *) IjkMediaPlayer_setAudioExtraDelay },
    { "getAudioExtraDelay",       "()F",                      (void *) IjkMediaPlayer_getAudioExtraDelay },
    { "setSubtitleExtraDelay",    "(F)V",                     (void *) IjkMediaPlayer_setSubtitleExtraDelay },
    { "getSubtitleExtraDelay",    "()F",                      (void *) IjkMediaPlayer_getSubtitleExtraDelay },
    { "loadThenActiveSubtitle",   "(Ljava/lang/String;)Z",    (void *) IjkMediaPlayer_loadThenActiveSubtitle },
    { "addOnlyExternalSubtitle",  "(Ljava/lang/String;)I",    (void *) IjkMediaPlayer_addOnlyExternalSubtitle },
    { "addOnlyExternalSubtitles", "([Ljava/lang/String;)I",   (void *) IjkMediaPlayer_addOnlyExternalSubtitles },
    { "setSubtitlePreference",    "(Ltv/danmaku/ijk/media/player/FSSubtitlePreference;)V", (void *) IjkMediaPlayer_setSubtitlePreference },
    { "stepToNextFrame",          "()V",                      (void *) IjkMediaPlayer_stepToNextFrame },
    { "enableAccurateSeek",       "(Z)V",                     (void *) IjkMediaPlayer_enableAccurateSeek },
    { "getPlayableDuration",      "()J",                      (void *) IjkMediaPlayer_getPlayableDuration },
    { "getFrameCacheRemaining",   "(I)I",                     (void *) IjkMediaPlayer_getFrameCacheRemaining },
    { "takeSnapshot",             "(I[I)[B",                  (void *) IjkMediaPlayer_takeSnapshot },
    { "setBackgroundImage",       "([BII)V",                   (void *) IjkMediaPlayer_setBackgroundImage },
    { "setBackgroundBlur",         "(IF)V",                    (void *) IjkMediaPlayer_setBackgroundBlur },
    { "setColorAdjust",            "(FFF)V",                   (void *) IjkMediaPlayer_setColorAdjust },
    { "native_setBackgroundColor", "(III)V",                   (void *) IjkMediaPlayer_setBackgroundColor },
    { "native_setAllowHDRDirectDisplay", "(Z)V",               (void *) IjkMediaPlayer_native_setAllowHDRDirectDisplay },
    { "native_isDirectDisplayHDRSupported", "()Z",             (void *) IjkMediaPlayer_native_isDirectDisplayHDRSupported },
    { "native_isHDRContent",       "()Z",                      (void *) IjkMediaPlayer_native_isHDRContent },
    { "setDeinterlace",           "(I)V",                     (void *) IjkMediaPlayer_setDeinterlace },
    { "getDeinterlace",           "()I",                      (void *) IjkMediaPlayer_getDeinterlace },
    { "refreshPicture",           "()V",                      (void *) IjkMediaPlayer_refreshPicture },
    { "reloadVideoStream",        "()I",                      (void *) IjkMediaPlayer_reloadVideoStream },
    { "getIFormatExtensions",     "()Ljava/lang/String;",     (void *) IjkMediaPlayer_getIFormatExtensions },
    { "getPlayerVersion",         "()Ljava/lang/String;",     (void *) IjkMediaPlayer_getPlayerVersion },
    { "getFFmpegVersion",         "()Ljava/lang/String;",     (void *) IjkMediaPlayer_getFFmpegVersion },
    { "startFastRecord",          "(Ljava/lang/String;)I",    (void *) IjkMediaPlayer_startFastRecord },
    { "stopFastRecord",           "()I",                      (void *) IjkMediaPlayer_stopFastRecord },
    { "startExactRecord",         "(Ljava/lang/String;)I",    (void *) IjkMediaPlayer_startExactRecord },
    { "stopExactRecord",          "()I",                      (void *) IjkMediaPlayer_stopExactRecord },
    { "_setAudioSamplesObserver", "(Z)V",                     (void *) IjkMediaPlayer_setAudioSamplesObserver },
    { "native_getLogLevel",       "()I",                      (void *) IjkMediaPlayer_native_getLogLevel },
    { "native_setLogReport",      "(I)V",                     (void *) IjkMediaPlayer_native_setLogReport },
};

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved)
{
    JNIEnv* env = NULL;

    if ((*vm)->GetEnv(vm, (void**) &env, JNI_VERSION_1_4) != JNI_OK) {
        return -1;
    }
    assert(env != NULL);

    pthread_mutex_init(&g_clazz.mutex, NULL );

    // FindClass returns LocalReference
    IJK_FIND_JAVA_CLASS(env, g_clazz.clazz, JNI_CLASS_IJKPLAYER);
    (*env)->RegisterNatives(env, g_clazz.clazz, g_methods, NELEM(g_methods) );

    ijkmp_global_init();
    ijkmp_global_set_inject_callback(inject_callback);

    FFmpegApi_global_init(env);
    int retval = JNI_OnLoad_SDL(vm, env);
    JNI_CHECK_RET(retval == 0, env, NULL, NULL, -1);

    return JNI_VERSION_1_4;
}

JNIEXPORT void JNI_OnUnload(JavaVM *jvm, void *reserved)
{
    ijkmp_global_uninit();

    pthread_mutex_destroy(&g_clazz.mutex);
}
