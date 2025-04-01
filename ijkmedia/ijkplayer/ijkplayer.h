/*
 * ijkplayer.h
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

#ifndef FSPLAYER_ANDROID__IJKPLAYER_H
#define FSPLAYER_ANDROID__IJKPLAYER_H

#include <stdbool.h>
#include "ff_ffmsg_queue.h"

#include "ijkmeta.h"

#ifndef MPTRACE
#define MPTRACE ALOGD
#endif

typedef struct IjkMediaPlayer IjkMediaPlayer;
struct FFPlayer;
struct SDL_Vout;

/*-
 MPST_CHECK_NOT_RET(mp->mp_state, MP_STATE_IDLE);
 MPST_CHECK_NOT_RET(mp->mp_state, MP_STATE_INITIALIZED);
 MPST_CHECK_NOT_RET(mp->mp_state, MP_STATE_ASYNC_PREPARING);
 MPST_CHECK_NOT_RET(mp->mp_state, MP_STATE_PREPARED);
 MPST_CHECK_NOT_RET(mp->mp_state, MP_STATE_STARTED);
 MPST_CHECK_NOT_RET(mp->mp_state, MP_STATE_PAUSED);
 MPST_CHECK_NOT_RET(mp->mp_state, MP_STATE_COMPLETED);
 MPST_CHECK_NOT_RET(mp->mp_state, MP_STATE_STOPPED);
 MPST_CHECK_NOT_RET(mp->mp_state, MP_STATE_ERROR);
 MPST_CHECK_NOT_RET(mp->mp_state, MP_STATE_END);
 */

/*-
 * ijkmp_set_data_source()  -> MP_STATE_INITIALIZED
 *
 * ijkmp_reset              -> self
 * ijkmp_release            -> MP_STATE_END
 */
#define MP_STATE_IDLE               0

/*-
 * ijkmp_prepare_async()    -> MP_STATE_ASYNC_PREPARING
 *
 * ijkmp_reset              -> MP_STATE_IDLE
 * ijkmp_release            -> MP_STATE_END
 */
#define MP_STATE_INITIALIZED        1

/*-
 *                   ...    -> MP_STATE_PREPARED
 *                   ...    -> MP_STATE_ERROR
 *
 * ijkmp_reset              -> MP_STATE_IDLE
 * ijkmp_release            -> MP_STATE_END
 */
#define MP_STATE_ASYNC_PREPARING    2

/*-
 * ijkmp_seek_to()          -> self
 * ijkmp_start()            -> MP_STATE_STARTED
 *
 * ijkmp_reset              -> MP_STATE_IDLE
 * ijkmp_release            -> MP_STATE_END
 */
#define MP_STATE_PREPARED           3

/*-
 * ijkmp_seek_to()          -> self
 * ijkmp_start()            -> self
 * ijkmp_pause()            -> MP_STATE_PAUSED
 * ijkmp_stop()             -> MP_STATE_STOPPED
 *                   ...    -> MP_STATE_COMPLETED
 *                   ...    -> MP_STATE_ERROR
 *
 * ijkmp_reset              -> MP_STATE_IDLE
 * ijkmp_release            -> MP_STATE_END
 */
#define MP_STATE_STARTED            4

/*-
 * ijkmp_seek_to()          -> self
 * ijkmp_start()            -> MP_STATE_STARTED
 * ijkmp_pause()            -> self
 * ijkmp_stop()             -> MP_STATE_STOPPED
 *
 * ijkmp_reset              -> MP_STATE_IDLE
 * ijkmp_release            -> MP_STATE_END
 */
#define MP_STATE_PAUSED             5

/*-
 * ijkmp_seek_to()          -> self
 * ijkmp_start()            -> MP_STATE_STARTED (from beginning)
 * ijkmp_pause()            -> self
 * ijkmp_stop()             -> MP_STATE_STOPPED
 *
 * ijkmp_reset              -> MP_STATE_IDLE
 * ijkmp_release            -> MP_STATE_END
 */
#define MP_STATE_COMPLETED          6

/*-
 * ijkmp_stop()             -> self
 * ijkmp_prepare_async()    -> MP_STATE_ASYNC_PREPARING
 *
 * ijkmp_reset              -> MP_STATE_IDLE
 * ijkmp_release            -> MP_STATE_END
 */
#define MP_STATE_STOPPED            7

/*-
 * ijkmp_reset              -> MP_STATE_IDLE
 * ijkmp_release            -> MP_STATE_END
 */
#define MP_STATE_ERROR              8

/*-
 * ijkmp_release            -> self
 */
#define MP_STATE_END                9



#define FSMP_IO_STAT_READ 1


#define FSMP_OPT_CATEGORY_FORMAT FFP_OPT_CATEGORY_FORMAT
#define FSMP_OPT_CATEGORY_CODEC  FFP_OPT_CATEGORY_CODEC
#define FSMP_OPT_CATEGORY_SWS    FFP_OPT_CATEGORY_SWS
#define FSMP_OPT_CATEGORY_PLAYER FFP_OPT_CATEGORY_PLAYER
#define FSMP_OPT_CATEGORY_SWR    FFP_OPT_CATEGORY_SWR


void            ijkmp_global_init(void);
void            ijkmp_global_uninit(void);
void            ijkmp_global_set_log_report(int use_report);
void            ijkmp_global_set_log_level(int log_level);   // log_level = AV_LOG_xxx
int             ijkmp_global_get_log_level(void);
void            ijkmp_global_set_inject_callback(ijk_inject_callback cb);
const char     *ijkmp_version(void);

// ref_count is 1 after open
IjkMediaPlayer *ijkmp_create(int (*msg_loop)(void*));

void*           ijkmp_set_inject_opaque(IjkMediaPlayer *mp, void *opaque);
void*           ijkmp_set_ijkio_inject_opaque(IjkMediaPlayer *mp, void *opaque);
void            ijkmp_set_option(IjkMediaPlayer *mp, int opt_category, const char *name, const char *value);
void            ijkmp_set_option_int(IjkMediaPlayer *mp, int opt_category, const char *name, int64_t value);

int             ijkmp_get_video_codec_info(IjkMediaPlayer *mp, char **codec_info);
int             ijkmp_get_audio_codec_info(IjkMediaPlayer *mp, char **codec_info);
void            ijkmp_set_playback_rate(IjkMediaPlayer *mp, float rate);
void            ijkmp_set_playback_volume(IjkMediaPlayer *mp, float rate);

int             ijkmp_set_stream_selected(IjkMediaPlayer *mp, int stream, int selected);

float           ijkmp_get_property_float(IjkMediaPlayer *mp, int id, float default_value);
void            ijkmp_set_property_float(IjkMediaPlayer *mp, int id, float value);
int64_t         ijkmp_get_property_int64(IjkMediaPlayer *mp, int id, int64_t default_value);
void            ijkmp_set_property_int64(IjkMediaPlayer *mp, int id, int64_t value);

// must be freed with free();
IjkMediaMeta   *ijkmp_get_meta_l(IjkMediaPlayer *mp);

// preferred to be called explicity, can be called multiple times
// NOTE: ijkmp_shutdown may block thread
void            ijkmp_shutdown(IjkMediaPlayer *mp);

void            ijkmp_inc_ref(IjkMediaPlayer *mp);

// call close at last release, also free memory
// NOTE: ijkmp_dec_ref may block thread
void            ijkmp_dec_ref(IjkMediaPlayer *mp);
void            ijkmp_dec_ref_p(IjkMediaPlayer **pmp);

int             ijkmp_set_data_source(IjkMediaPlayer *mp, const char *url);
int             ijkmp_prepare_async(IjkMediaPlayer *mp);
int             ijkmp_start(IjkMediaPlayer *mp);
int             ijkmp_pause(IjkMediaPlayer *mp);
int             ijkmp_stop(IjkMediaPlayer *mp);
int             ijkmp_seek_to(IjkMediaPlayer *mp, long msec);
int             ijkmp_get_state(IjkMediaPlayer *mp);
bool            ijkmp_is_playing(IjkMediaPlayer *mp);
long            ijkmp_get_current_position(IjkMediaPlayer *mp);
long            ijkmp_get_duration(IjkMediaPlayer *mp);
long            ijkmp_get_playable_duration(IjkMediaPlayer *mp);
void            ijkmp_set_loop(IjkMediaPlayer *mp, int loop);
int             ijkmp_get_loop(IjkMediaPlayer *mp);

void           *ijkmp_get_weak_thiz(IjkMediaPlayer *mp);
void           *ijkmp_set_weak_thiz(IjkMediaPlayer *mp, void *weak_thiz);

/* return < 0 if aborted, 0 if no packet and > 0 if packet. */
/* need to call msg_free_res for freeing the resouce obtained in msg */
int             ijkmp_get_msg(IjkMediaPlayer *mp, AVMessage *msg, int block);
void            ijkmp_set_audio_extra_delay(IjkMediaPlayer* mp, const float delay);
float           ijkmp_get_audio_extra_delay(IjkMediaPlayer *mp);
void            ijkmp_set_subtitle_extra_delay(IjkMediaPlayer *mp,const float delay);
float           ijkmp_get_subtitle_extra_delay(IjkMediaPlayer *mp);
/* add + active ex-subtitle */
int             ijkmp_add_active_external_subtitle(IjkMediaPlayer* mp, const char* file_name);
/* add only ex-subtitle */
int             ijkmp_addOnly_external_subtitle(IjkMediaPlayer* mp, const char* file_name);
/* add only ex-subtitle */
int             ijkmp_addOnly_external_subtitles(IjkMediaPlayer* mp, const char* file_names [], int count);
/* get frame queue cache remaining count;
 audio type is 1,video type is 2,subtitle type is 3
 */
int             ijkmp_get_frame_cache_remaining(IjkMediaPlayer *mp, int type);
/* register audio samples observer*/
void            ijkmp_set_audio_sample_observer(IjkMediaPlayer *mp, ijk_audio_samples_callback cb);
/* toggle accurate seek */
void ijkmp_set_enable_accurate_seek(IjkMediaPlayer *mp, int open);
/* step to next frame */
void ijkmp_step_to_next_frame(IjkMediaPlayer *mp);

typedef struct FSSubtitlePreference FSSubtitlePreference;
void ijkmp_set_subtitle_preference(IjkMediaPlayer *mp, FSSubtitlePreference* sp);
#endif
