/*
 * ijkmeta.c
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

#include "ijkmeta.h"
#include "ff_ffinc.h"
#include "ijksdl/ijksdl_misc.h"
#include "ff_ffplay.h"

#define FS_META_INIT_CAPACITY 13

struct IjkMediaMeta {
    SDL_mutex *mutex;

    AVDictionary *dict;

    size_t children_count;
    size_t children_capacity;
    IjkMediaMeta **children;
};

IjkMediaMeta *ijkmeta_create(void)
{
    IjkMediaMeta *meta = (IjkMediaMeta *)calloc(1, sizeof(IjkMediaMeta));
    if (!meta)
        return NULL;

    meta->mutex = SDL_CreateMutex();
    if (!meta->mutex)
        goto fail;

    return meta;
fail:
    ijkmeta_destroy(meta);
    return NULL;
}

void ijkmeta_reset(IjkMediaMeta *meta)
{
    if (meta && meta->dict)
        av_dict_free(&meta->dict);
}

void ijkmeta_destroy(IjkMediaMeta *meta)
{
    if (!meta)
        return;

    if (meta->dict) {
        av_dict_free(&meta->dict);
    }

    if (meta->children) {
        for(int i = 0; i < meta->children_count; ++i) {
            IjkMediaMeta *child = meta->children[i];
            if (child) {
                ijkmeta_destroy(child);
            }
        }
        free(meta->children);
        meta->children = NULL;
    }

    SDL_DestroyMutexP(&meta->mutex);
    free(meta);
}

void ijkmeta_destroy_p(IjkMediaMeta **meta)
{
    if (!meta)
        return;

    ijkmeta_destroy(*meta);
    *meta = NULL;
}

void ijkmeta_lock(IjkMediaMeta *meta)
{
    if (!meta || !meta->mutex)
        return;

    SDL_LockMutex(meta->mutex);
}

void ijkmeta_unlock(IjkMediaMeta *meta)
{
    if (!meta || !meta->mutex)
        return;

    SDL_UnlockMutex(meta->mutex);
}

void ijkmeta_append_child_l(IjkMediaMeta *meta, IjkMediaMeta *child)
{
    if (!meta || !child)
        return;

    if (!meta->children) {
        meta->children = (IjkMediaMeta **)calloc(FS_META_INIT_CAPACITY, sizeof(IjkMediaMeta *));
        if (!meta->children)
            return;
        meta->children_count    = 0;
        meta->children_capacity = FS_META_INIT_CAPACITY;
    } else if (meta->children_count >= meta->children_capacity) {
        size_t new_capacity = meta->children_capacity * 2;
        IjkMediaMeta **new_children = (IjkMediaMeta **)calloc(new_capacity, sizeof(IjkMediaMeta *));
        if (!new_children)
            return;

        memcpy(new_children, meta->children, meta->children_capacity * sizeof(IjkMediaMeta *));
        free(meta->children);
        meta->children          = new_children;
        meta->children_capacity = new_capacity;
    }

    meta->children[meta->children_count] = child;
    meta->children_count++;
}

void ijkmeta_set_int64_l(IjkMediaMeta *meta, const char *name, int64_t value)
{
    if (!meta)
        return;

    av_dict_set_int(&meta->dict, name, value, 0);
}

void ijkmeta_set_string_l(IjkMediaMeta *meta, const char *name, const char *value)
{
    if (!meta)
        return;

    av_dict_set(&meta->dict, name, value, 0);
}

static int64_t get_bit_rate(AVCodecParameters *codecpar)
{
    int64_t bit_rate;
    int bits_per_sample;

    switch (codecpar->codec_type) {
        case AVMEDIA_TYPE_VIDEO:
        case AVMEDIA_TYPE_DATA:
        case AVMEDIA_TYPE_SUBTITLE:
        case AVMEDIA_TYPE_ATTACHMENT:
            bit_rate = codecpar->bit_rate;
            break;
        case AVMEDIA_TYPE_AUDIO:
            bits_per_sample = av_get_bits_per_sample(codecpar->codec_id);
            bit_rate = bits_per_sample ? codecpar->sample_rate * codecpar->ch_layout.nb_channels * bits_per_sample : codecpar->bit_rate;
            break;
        default:
            bit_rate = 0;
            break;
    }
    return bit_rate;
}

//https://stackoverflow.com/questions/15245046/how-to-retrieve-http-headers-from-a-stream-in-ffmpeg
//https://www.ffmpeg.org/ffmpeg-protocols.html#http
//https://cast.readme.io/docs/icy
int ijkmeta_update_icy_from_avformat_context_l(IjkMediaMeta *meta, AVFormatContext *ic)
{
    int r = 0;
    if (!meta || !ic)
        return r;
    
    char* metadata = NULL;
    av_opt_get(ic, "icy_metadata_packet", AV_OPT_SEARCH_CHILDREN, (uint8_t**) &metadata);
    if (!metadata) {
        return 0;
    }
    
    char *temp = NULL;
    char *ptr = av_strtok(metadata, ";", &temp);
    while (ptr) {
        char *fs=ptr,*token;
        char *colon = strchr(fs, '=');
        if (!colon)
            continue;
        *colon = '\0';
        token = colon + 2;
        token[strlen(token)-1] = '\0';
        //av_log(NULL, AV_LOG_DEBUG, "icy_metadata key value:%s=%s\n",fs,token);
        
        const char *old_value = ijkmeta_get_string_l(meta, fs);
        if (token != old_value && (token && old_value && strcmp(token, old_value))) {
            ijkmeta_set_string_l(meta, fs, token);
            r++;
        }
        ptr = av_strtok(NULL, ";", &temp);
    }
    av_free(metadata);
    return r;
}

void ijkmeta_set_avformat_context_l(IjkMediaMeta *meta, AVFormatContext *ic)
{
    if (!meta || !ic)
        return;

    if (ic->iformat && ic->iformat->name)
        ijkmeta_set_string_l(meta, FSM_KEY_FORMAT, ic->iformat->name);

    if (ic->duration != AV_NOPTS_VALUE)
        ijkmeta_set_int64_l(meta, FSM_KEY_DURATION_US, ic->duration);

    if (ic->start_time != AV_NOPTS_VALUE)
        ijkmeta_set_int64_l(meta, FSM_KEY_START_US, ic->start_time);

    if (ic->bit_rate)
        ijkmeta_set_int64_l(meta, FSM_KEY_BITRATE, ic->bit_rate);
    
    //printf all ic metadata
    AVDictionaryEntry *tag = NULL;
    while ((tag = av_dict_get(ic->metadata, "", tag, AV_DICT_IGNORE_SUFFIX)))
        if (tag->value)
            av_log(NULL, AV_LOG_DEBUG, "ic metadata item:%s=%s\n", tag->key, tag->value);
    
    char *ic_string_val_keys[] = {FSM_KEY_ARTIST,FSM_KEY_ALBUM,FSM_KEY_TYER,FSM_KEY_MINOR_VER,FSM_KEY_COMPATIBLE_BRANDS,FSM_KEY_MAJOR_BRAND,FSM_KEY_LYRICS,FSM_KEY_ICY_BR,FSM_KEY_ICY_DESC,FSM_KEY_ICY_GENRE,FSM_KEY_ICY_NAME,FSM_KEY_ICY_PUB,FSM_KEY_ICY_URL,FSM_KEY_ICY_ST,FSM_KEY_ICY_SU,NULL};
    {
        char **ic_key_header = ic_string_val_keys;
        char *ic_key;
        while ((ic_key = *ic_key_header)) {
            AVDictionaryEntry *entry = av_dict_get(ic->metadata, ic_key, NULL, AV_DICT_IGNORE_SUFFIX);
            if (entry && entry->value)
                ijkmeta_set_string_l(meta, ic_key, entry->value);
            ic_key_header++;
        }
    }
    
    {
        IjkMediaMeta *chapter_meta = NULL;
        for (int i = 0; i < ic->nb_chapters; i++) {
            if (!chapter_meta) {
                chapter_meta = ijkmeta_create();
            }
            AVChapter *chapter = ic->chapters[i];
            //ms
            double tb = av_q2d(chapter->time_base) * 1000;
            long start = (long)(chapter->start * tb);
            long end = (long)(chapter->end * tb);
            IjkMediaMeta *sub_meta = ijkmeta_create();
            ijkmeta_set_int64_l(sub_meta, FSM_META_KEY_START, start);
            ijkmeta_set_int64_l(sub_meta, FSM_META_KEY_END, end);
            ijkmeta_set_int64_l(sub_meta, FSM_META_KEY_ID, chapter->id);
            
            //set all raw meta
            AVDictionaryEntry *tag = NULL;
            while ((tag = av_dict_get(chapter->metadata, "", tag, AV_DICT_IGNORE_SUFFIX)))
                ijkmeta_set_string_l(sub_meta, tag->key, tag->value);
            
            ijkmeta_append_child_l(chapter_meta, sub_meta);
        }
        if (chapter_meta) {
            ijkmeta_set_string_l(chapter_meta, FSM_KEY_TYPE, FSM_VAL_TYPE__CHAPTER);
            ijkmeta_append_child_l(meta, chapter_meta);
        }
    }
    
    IjkMediaMeta *stream_meta = NULL;
    for (int i = 0; i < ic->nb_streams; i++) {
        if (!stream_meta)
            ijkmeta_destroy_p(&stream_meta);

        AVStream *st = ic->streams[i];
        if (!st || !st->codecpar)
            continue;
        
        {
            AVDictionaryEntry *tag = NULL;
            while ((tag = av_dict_get(st->metadata, "", tag, AV_DICT_IGNORE_SUFFIX)))
                if (tag->value)
                    av_log(NULL, AV_LOG_DEBUG, "%d st metadata item:%s=%s\n", st->codecpar->codec_type, tag->key, tag->value);
        }
        
        stream_meta = ijkmeta_create();
        if (!stream_meta)
            continue;

        AVCodecParameters *codecpar = st->codecpar;
        const char *codec_name = avcodec_get_name(codecpar->codec_id);
        if (codec_name)
            ijkmeta_set_string_l(stream_meta, FSM_KEY_CODEC_NAME, codec_name);
        if (codecpar->profile != FF_PROFILE_UNKNOWN) {
            const AVCodec *codec = avcodec_find_decoder(codecpar->codec_id);
            if (codec) {
                ijkmeta_set_int64_l(stream_meta, FSM_KEY_CODEC_PROFILE_ID, codecpar->profile);
                const char *profile = av_get_profile_name(codec, codecpar->profile);
                if (profile)
                    ijkmeta_set_string_l(stream_meta, FSM_KEY_CODEC_PROFILE, profile);
                if (codec->long_name)
                    ijkmeta_set_string_l(stream_meta, FSM_KEY_CODEC_LONG_NAME, codec->long_name);
                ijkmeta_set_int64_l(stream_meta, FSM_KEY_CODEC_LEVEL, codecpar->level);
                if (codecpar->format != AV_PIX_FMT_NONE)
                    ijkmeta_set_string_l(stream_meta, FSM_KEY_CODEC_PIXEL_FORMAT, av_get_pix_fmt_name(codecpar->format));
            }
        }

        int64_t bitrate = get_bit_rate(codecpar);
        if (bitrate > 0) {
            ijkmeta_set_int64_l(stream_meta, FSM_KEY_BITRATE, bitrate);
        }

        switch (codecpar->codec_type) {
            case AVMEDIA_TYPE_VIDEO: {
                ijkmeta_set_string_l(stream_meta, FSM_KEY_TYPE, FSM_VAL_TYPE__VIDEO);

                if (codecpar->width > 0)
                    ijkmeta_set_int64_l(stream_meta, FSM_KEY_WIDTH, codecpar->width);
                if (codecpar->height > 0)
                    ijkmeta_set_int64_l(stream_meta, FSM_KEY_HEIGHT, codecpar->height);
                if (st->sample_aspect_ratio.num > 0 && st->sample_aspect_ratio.den > 0) {
                    ijkmeta_set_int64_l(stream_meta, FSM_KEY_SAR_NUM, codecpar->sample_aspect_ratio.num);
                    ijkmeta_set_int64_l(stream_meta, FSM_KEY_SAR_DEN, codecpar->sample_aspect_ratio.den);
                }
                if (st->avg_frame_rate.num > 0 && st->avg_frame_rate.den > 0) {
                    ijkmeta_set_int64_l(stream_meta, FSM_KEY_FPS_NUM, st->avg_frame_rate.num);
                    ijkmeta_set_int64_l(stream_meta, FSM_KEY_FPS_DEN, st->avg_frame_rate.den);
                }
                if (st->r_frame_rate.num > 0 && st->r_frame_rate.den > 0) {
                    ijkmeta_set_int64_l(stream_meta, FSM_KEY_TBR_NUM, st->avg_frame_rate.num);
                    ijkmeta_set_int64_l(stream_meta, FSM_KEY_TBR_DEN, st->avg_frame_rate.den);
                }
                break;
            }
            case AVMEDIA_TYPE_AUDIO: {
                ijkmeta_set_string_l(stream_meta, FSM_KEY_TYPE, FSM_VAL_TYPE__AUDIO);

                if (codecpar->sample_rate)
                    ijkmeta_set_int64_l(stream_meta, FSM_KEY_SAMPLE_RATE, codecpar->sample_rate);

                AVDictionaryEntry *lang = av_dict_get(st->metadata, FSM_KEY_LANGUAGE, NULL, AV_DICT_IGNORE_SUFFIX);
                if (lang && lang->value)
                    ijkmeta_set_string_l(stream_meta, FSM_KEY_LANGUAGE, lang->value);
                char describe[64];
                if (av_channel_layout_describe(&codecpar->ch_layout, describe, sizeof(describe)) > 0) {
                    ijkmeta_set_string_l(stream_meta, FSM_KEY_DESCRIBE, describe);
                }
                AVDictionaryEntry *title = av_dict_get(st->metadata, FSM_KEY_TITLE, NULL, AV_DICT_IGNORE_SUFFIX);
                if (title && title->value)
                    ijkmeta_set_string_l(stream_meta, FSM_KEY_TITLE, title->value);
                break;
            }
            case AVMEDIA_TYPE_SUBTITLE: {
                ijkmeta_set_string_l(stream_meta, FSM_KEY_TYPE, FSM_VAL_TYPE__TIMEDTEXT);
                AVDictionaryEntry *lang = av_dict_get(st->metadata, FSM_KEY_LANGUAGE, NULL, AV_DICT_IGNORE_SUFFIX);
                if (lang && lang->value)
                    ijkmeta_set_string_l(stream_meta, FSM_KEY_LANGUAGE, lang->value);
                AVDictionaryEntry *title = av_dict_get(st->metadata, FSM_KEY_TITLE, NULL, AV_DICT_IGNORE_SUFFIX);
                if (title && title->value)
                    ijkmeta_set_string_l(stream_meta, FSM_KEY_TITLE, title->value);
                break;
            }
            default: {
                ijkmeta_set_string_l(stream_meta, FSM_KEY_TYPE, FSM_VAL_TYPE__UNKNOWN);
                break;
            }
        }

        ijkmeta_set_int64_l(stream_meta, FSM_KEY_STREAM_IDX, i);
        
        ijkmeta_append_child_l(meta, stream_meta);
        stream_meta = NULL;
    }

    if (!stream_meta)
        ijkmeta_destroy_p(&stream_meta);
}

const char *ijkmeta_get_string_l(IjkMediaMeta *meta, const char *name)
{
    if (!meta || !meta->dict || !name)
        return NULL;

    AVDictionaryEntry *entry = av_dict_get(meta->dict, name, NULL, 0);
    if (!entry)
        return NULL;

    return entry->value;
}

int64_t ijkmeta_get_int64_l(IjkMediaMeta *meta, const char *name, int64_t defaultValue)
{
    if (!meta || !meta->dict)
        return defaultValue;

    AVDictionaryEntry *entry = av_dict_get(meta->dict, name, NULL, 0);
    if (!entry || !entry->value)
        return defaultValue;

    return atoll(entry->value);
}

size_t ijkmeta_get_children_count_l(IjkMediaMeta *meta)
{
    if (!meta || !meta->children)
        return 0;

    return meta->children_count;
}

IjkMediaMeta *ijkmeta_get_child_l(IjkMediaMeta *meta, size_t index)
{
    if (!meta)
        return NULL;

    if (index >= meta->children_count)
        return NULL;

    return meta->children[index];
}
