/*
 * ff_ffplay.h
 *
 * Copyright (c) 2003 Bilibili
 * Copyright (c) 2003 Fabrice Bellard
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

#ifndef FFPLAY__FF_FFPLAY_H
#define FFPLAY__FF_FFPLAY_H

#include "ff_ffplay_def.h"
#include "ff_fferror.h"
#include "ff_ffmsg.h"

void      ffp_global_init(void);
void      ffp_global_uninit(void);
void      ffp_global_set_log_report(int use_report);
int       ffp_global_get_log_level(void);
void      ffp_global_set_log_level(int log_level);
void      ffp_global_set_inject_callback(ijk_inject_callback cb);

FFPlayer *ffp_create(void);
void      ffp_destroy(FFPlayer *ffp);
void      ffp_destroy_p(FFPlayer **pffp);
void      ffp_reset(FFPlayer *ffp);

/* set options before ffp_prepare_async_l() */

void     *ffp_set_inject_opaque(FFPlayer *ffp, void *opaque);
void     *ffp_set_ijkio_inject_opaque(FFPlayer *ffp, void *opaque);
void      ffp_set_option(FFPlayer *ffp, int opt_category, const char *name, const char *value);
void      ffp_set_option_int(FFPlayer *ffp, int opt_category, const char *name, int64_t value);
void      ffp_set_option_intptr(FFPlayer *ffp, int opt_category, const char *name, uintptr_t value);
int       ffp_get_video_codec_info(FFPlayer *ffp, char **codec_info);
int       ffp_get_audio_codec_info(FFPlayer *ffp, char **codec_info);

/* playback controll */
int       ffp_prepare_async_l(FFPlayer *ffp, const char *file_name);
int       ffp_start_from_l(FFPlayer *ffp, long msec);
int       ffp_start_l(FFPlayer *ffp);
int       ffp_pause_l(FFPlayer *ffp);
int       ffp_is_paused_l(FFPlayer *ffp);
int       ffp_stop_l(FFPlayer *ffp);
int       ffp_wait_stop_l(FFPlayer *ffp);

/* all in milliseconds */
int       ffp_seek_to_l(FFPlayer *ffp, long msec);
long      ffp_get_current_position_l(FFPlayer *ffp);
long      ffp_get_duration_l(FFPlayer *ffp);
long      ffp_get_playable_duration_l(FFPlayer *ffp);
void      ffp_set_loop(FFPlayer *ffp, int loop);
int       ffp_get_loop(FFPlayer *ffp);

/* for internal usage */
int       ffp_packet_queue_get_or_buffering(FFPlayer *ffp, PacketQueue *q, AVPacket *pkt, int *serial, int *finished);
int       ffp_queue_picture(FFPlayer *ffp, AVFrame *src_frame, double pts, double duration, int64_t pos, int serial);

int       ffp_get_master_sync_type(VideoState *is);
double    ffp_get_master_clock(VideoState *is);

void      ffp_toggle_buffering_l(FFPlayer *ffp, int start_buffering);
void      ffp_toggle_buffering(FFPlayer *ffp, int start_buffering);
void      ffp_check_buffering_l(FFPlayer *ffp);

int       ffp_video_thread(FFPlayer *ffp);

void      ffp_set_video_codec_info(FFPlayer *ffp, const char *module, const char *codec);
void      ffp_set_audio_codec_info(FFPlayer *ffp, const char *module, const char *codec);
void      ffp_set_subtitle_codec_info(FFPlayer *ffp, const char *module, const char *codec);

void      ffp_set_playback_rate(FFPlayer *ffp, float rate);
void      ffp_set_playback_volume(FFPlayer *ffp, float volume);
int       ffp_set_stream_selected(FFPlayer *ffp, int stream, int selected);

float     ffp_get_property_float(FFPlayer *ffp, int id, float default_value);
void      ffp_set_property_float(FFPlayer *ffp, int id, float value);
int64_t   ffp_get_property_int64(FFPlayer *ffp, int id, int64_t default_value);
void      ffp_set_property_int64(FFPlayer *ffp, int id, int64_t value);

/* must be freed with free(); */
struct IjkMediaMeta *ffp_get_meta_l(FFPlayer *ffp);
void ffp_set_audio_extra_delay(FFPlayer *ffp, const float delay);
float ffp_get_audio_extra_delay(FFPlayer *ffp);
//when get or set extra delay,make sure already added external subtitle.
void      ffp_set_subtitle_extra_delay(FFPlayer *ffp, const float delay, int64_t * need_seek);
float     ffp_get_subtitle_extra_delay(FFPlayer *ffp);
/* ex-subtitle: add + active */
int       ffp_add_active_external_subtitle(FFPlayer *ffp, const char *file_name);
/* ex-subtitle: add but not active; return 0 means succ,1 means already added */
int       ffp_addOnly_external_subtitle(FFPlayer *ffp, const char *file_name);
/* ex-subtitle: add but not active; return added count*/
int       ffp_addOnly_external_subtitles(FFPlayer *ffp, const char *file_names [], int count);
//type: audio:1,video:2,subtitle:3
int       ffp_get_frame_cache_remaining(FFPlayer *ffp,int type);
/* audio samples realtime observer callback, callback can be NULL */
void      ffp_set_audio_sample_observer(FFPlayer *ffp, ijk_audio_samples_callback cb);
/* toggle accurate seek*/
void      ffp_set_enable_accurate_seek(FFPlayer *ffp,int open);
/* step to next frame */
void      ffp_step_to_next_frame(FFPlayer *ffp);
/* set subtitle preference*/
void      ffp_set_subtitle_preference(FFPlayer *ffp, FSSubtitlePreference* sp);
/* get current input format extensions*/
const char * ffp_get_iformat_extensions(FFPlayer *ffp);
/* record */
int       ffp_start_mux(FFPlayer *ffp, const char *file_name);
int       ffp_stop_mux(FFPlayer *ffp);
int       ffp_start_recorder(FFPlayer *ffp, const char *file_name);
int       ffp_stop_recorder(FFPlayer *ffp);
void      ffp_refresh_picture(FFPlayer *ffp);


#endif
