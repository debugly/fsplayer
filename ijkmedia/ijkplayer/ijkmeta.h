/*
 * ijkmeta.h
 *
 * Copyright (c) 2014 Bilibili
 * Copyright (c) 2014 Zhang Rui <bbcallen@gmail.com>
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

#ifndef FSPLAYER__IJKMETA_H
#define FSPLAYER__IJKMETA_H

#include <stdint.h>
#include <stdlib.h>

// media meta
#define FSM_KEY_FORMAT             "format"
#define FSM_KEY_DURATION_US        "duration_us"
#define FSM_KEY_START_US           "start_us"
#define FSM_KEY_BITRATE            "bitrate"
#define FSM_KEY_VIDEO_STREAM       "video"
#define FSM_KEY_AUDIO_STREAM       "audio"
#define FSM_KEY_TIMEDTEXT_STREAM   "timedtext"

// stream meta
#define FSM_KEY_TYPE               "type"
#define FSM_VAL_TYPE__VIDEO        "video"
#define FSM_VAL_TYPE__AUDIO        "audio"
#define FSM_VAL_TYPE__TIMEDTEXT    "timedtext"
#define FSM_VAL_TYPE__CHAPTER      "chapter"
#define FSM_VAL_TYPE__UNKNOWN      "unknown"
#define FSM_META_KEY_ID            "id"
#define FSM_META_KEY_START         "start"
#define FSM_META_KEY_END           "end"
#define FSM_META_KEY_TITLE         "title"

#define FSM_KEY_LANGUAGE           "language"
#define FSM_KEY_TITLE              "title"
#define FSM_KEY_STREAM_IDX         "stream_idx"
#define FSM_KEY_ARTIST             "artist"
#define FSM_KEY_ALBUM              "album"
#define FSM_KEY_TYER               "TYER"
#define FSM_KEY_ENCODER            "encoder"
#define FSM_KEY_MINOR_VER          "minor_version"
#define FSM_KEY_COMPATIBLE_BRANDS  "compatible_brands"
#define FSM_KEY_MAJOR_BRAND        "major_brand"
#define FSM_KEY_LYRICS             "LYRICS"
#define FSM_KEY_DESCRIBE           "describe"
#define FSM_KEY_CODEC_NAME         "codec_name"
#define FSM_KEY_CODEC_PROFILE      "codec_profile"
#define FSM_KEY_CODEC_LEVEL        "codec_level"
#define FSM_KEY_CODEC_LONG_NAME    "codec_long_name"
#define FSM_KEY_CODEC_PIXEL_FORMAT "codec_pixel_format"
#define FSM_KEY_CODEC_PROFILE_ID   "codec_profile_id"

#define FSM_KEY_ICY_BR             "icy-br"
#define FSM_KEY_ICY_DESC           "icy-description"
#define FSM_KEY_ICY_GENRE          "icy-genre"
#define FSM_KEY_ICY_NAME           "icy-name"
#define FSM_KEY_ICY_PUB            "icy-pub"
#define FSM_KEY_ICY_URL            "icy-url"
#define FSM_KEY_ICY_ST             "StreamTitle"
#define FSM_KEY_ICY_SU             "StreamUrl"

// stream: video
#define FSM_KEY_WIDTH          "width"
#define FSM_KEY_HEIGHT         "height"
#define FSM_KEY_FPS_NUM        "fps_num"
#define FSM_KEY_FPS_DEN        "fps_den"
#define FSM_KEY_TBR_NUM        "tbr_num"
#define FSM_KEY_TBR_DEN        "tbr_den"
#define FSM_KEY_SAR_NUM        "sar_num"
#define FSM_KEY_SAR_DEN        "sar_den"

// stream: audio
#define FSM_KEY_SAMPLE_RATE    "sample_rate"
//#define FSM_KEY_CHANNEL_LAYOUT "channel_layout"

#define FSM_KEY_EX_SUBTITLE_URL "ex_subtile_url"
// reserved for user
#define FSM_KEY_STREAMS        "streams"

struct AVFormatContext;
struct FFPlayer;
struct VideoState;
typedef struct IjkMediaMeta IjkMediaMeta;

IjkMediaMeta *ijkmeta_create(void);
void ijkmeta_reset(IjkMediaMeta *meta);
void ijkmeta_destroy(IjkMediaMeta *meta);
void ijkmeta_destroy_p(IjkMediaMeta **meta);

void ijkmeta_lock(IjkMediaMeta *meta);
void ijkmeta_unlock(IjkMediaMeta *meta);

void ijkmeta_append_child_l(IjkMediaMeta *meta, IjkMediaMeta *child);
void ijkmeta_set_int64_l(IjkMediaMeta *meta, const char *name, int64_t value);
void ijkmeta_set_string_l(IjkMediaMeta *meta, const char *name, const char *value);
int ijkmeta_update_icy_from_avformat_context_l(IjkMediaMeta *meta, struct AVFormatContext *ic);
void ijkmeta_set_avformat_context_l(IjkMediaMeta *meta, struct AVFormatContext *ic);

// must be freed with free();
const char   *ijkmeta_get_string_l(IjkMediaMeta *meta, const char *name);
int64_t       ijkmeta_get_int64_l(IjkMediaMeta *meta, const char *name, int64_t defaultValue);
size_t        ijkmeta_get_children_count_l(IjkMediaMeta *meta);
// do not free
IjkMediaMeta *ijkmeta_get_child_l(IjkMediaMeta *meta, size_t index);

#endif//FSPLAYER__IJKMETA_H
