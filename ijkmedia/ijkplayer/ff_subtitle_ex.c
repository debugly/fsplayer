/*
 *  ff_subtitle_ex.c
 *
 * Copyright (c) 2022 debugly <qianlongxu@gmail.com>
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

// after activate not need seek, because video stream will be seeked.

#include "ff_subtitle_ex.h"
#include "ff_ffplay_def.h"
#include "ff_packet_list.h"

typedef struct FFExSubtitle {
    AVFormatContext* ic;
    PacketQueue * pktq;
    SDL_Thread _read_thread;
    SDL_Thread *read_thread;
    int stream_id;//ic 里的
    int eof;
    int64_t seek_req;
    float startTime;
    AVDictionary *opts;
    int abort_request;
}FFExSubtitle;

static int stream_has_enough_packets(PacketQueue *queue, int min_frames)
{
    return queue->abort_request || queue->nb_packets > min_frames;
}

static int ex_read_thread(void *opaque)
{
    FFExSubtitle *sub = opaque;
    if (!sub) {
        return -1;
    }
    
    AVPacket *pkt = av_packet_alloc();
    pkt->flags = 0;
    if (sub->ic) {
        do {
            if (sub->seek_req >= 0) {
                av_log(NULL, AV_LOG_DEBUG,"external subtitle seek to:%lld\n",fftime_to_seconds(sub->seek_req));
                if (avformat_seek_file(sub->ic, -1, INT64_MIN, sub->seek_req, INT64_MAX, 0) < 0) {
                    av_log(NULL, AV_LOG_ERROR, "external subtitle could not seek to position %lld\n", sub->seek_req);
                }
                sub->seek_req = -1;
                sub->eof = 0;
                packet_queue_flush(sub->pktq);
                continue;
            }
            
            if (sub->eof) {
                av_usleep(3 * 1000);
                continue;
            }
            
            if (stream_has_enough_packets(sub->pktq, 16)) {
                av_usleep(3 * 1000);
                continue;
            }
            int ret = av_read_frame(sub->ic, pkt);
            if (ret >= 0) {
                if (pkt->stream_index != sub->stream_id) {
                    av_packet_unref(pkt);
                    continue;
                }
                packet_queue_put(sub->pktq, pkt);
                continue;
            } else if (ret == AVERROR_EOF) {
                packet_queue_put_nullpacket(sub->pktq, pkt, sub->stream_id);
                sub->eof = 1;
                continue;
            } else if (ret == AVERROR_EXIT) {
                break;
            } else {
                av_usleep(3 * 1000);
                continue;
            }
        } while (sub->pktq->abort_request == 0 && sub->abort_request == 0);
    }
    av_packet_free(&pkt);
    return 0;
}

int exSub_seek_to(FFExSubtitle *sub, float sec)
{
    if (!sub || !sub->ic) {
        return -1;
    }
    if (sec < 0) {
        sec = 0;
    }
    //startTime unit is second!!
    sec -= sub->startTime;
    if (sec < 0) {
        sec = 0;
    }
    sub->seek_req = seconds_to_fftime(sec);
    return 0;
}

static int ex_read_interrupt_cb(void *ctx)
{
    FFExSubtitle *sub = ctx;
    return sub->abort_request;
}

static int exSub_open_filepath(FFExSubtitle *sub, const char *file_name)
{
    if (!sub) {
        return -1;
    }

    if (!file_name || strlen(file_name) == 0) {
        return -2;
    }
    
    assert(!sub->ic);
    
    int ret = 0;
    AVFormatContext* ic = avformat_alloc_context();
    
    if (ic) {
        ic->interrupt_callback.callback = ex_read_interrupt_cb;
        ic->interrupt_callback.opaque = sub;
    } else {
        ret = AVERROR(ENOMEM);
        goto fail;
    }
    
    if (avformat_open_input(&ic, file_name, NULL, &sub->opts) < 0) {
        ret = -1;
        goto fail;
    }
    
    if (avformat_find_stream_info(ic, NULL) < 0) {
        ret = -2;
        goto fail;
    }

    if (ic) {
        av_log(NULL, AV_LOG_DEBUG, "ex subtitle demuxer:%s\n",ic->iformat->name);
    }
    AVStream *sub_st = NULL;
    int stream_id = -1;
    //字幕流的索引
    for (size_t i = 0; i < ic->nb_streams; ++i) {
        AVStream *stream = ic->streams[i];
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) {
            sub_st = stream;
            stream_id = (int)i;
            stream->discard = AVDISCARD_DEFAULT;
        } else {
            stream->discard = AVDISCARD_ALL;
        }
    }
    
    if (stream_id == -1) {
        ret = -3;
        av_log(NULL, AV_LOG_ERROR, "none subtitle stream in %s\n", file_name);
        goto fail;
    }
    
    sub->ic = ic;
    sub->stream_id = stream_id;
    sub->seek_req = -1;
    return 0;
fail:
    if (ic)
        avformat_close_input(&ic);
    return ret;
}

static int exSub_create(FFExSubtitle **subp, PacketQueue * pktq)
{
    if (!subp) {
        return -1;
    }
    
    FFExSubtitle *sub = av_malloc(sizeof(FFExSubtitle));
    if (!sub) {
        return -2;
    }
    bzero(sub, sizeof(FFExSubtitle));
    
    sub->pktq = pktq;
    *subp = sub;
    return 0;
}

int exSub_open_input(FFExSubtitle **subp, PacketQueue * pktq, const char *file_name, float startTime, AVDictionary *opts)
{
    if (!subp) {
        return -1;
    }
    
    FFExSubtitle *mySub = NULL;
    if (exSub_create(&mySub, pktq)) {
        return -2;
    }
    
    av_dict_copy(&mySub->opts, opts, 0);
    if (exSub_open_filepath(mySub, file_name) != 0) {
        exSub_close_input(&mySub);
        return -3;
    }
    mySub->startTime = startTime;
    *subp = mySub;
    return 0;
}

void exSub_start_read(FFExSubtitle *sub)
{
    sub->read_thread = SDL_CreateThreadEx(&sub->_read_thread, ex_read_thread, sub, "ex_read_thread");
}

void exSub_close_input(FFExSubtitle **subp)
{
    if (!subp) {
        return;
    }
    
    FFExSubtitle *sub = *subp;
    if (!sub) {
        return;
    }
    sub->abort_request = 1;
    //maybe open input failed, read_thread is NULL.
    if (sub->read_thread) {
        SDL_WaitThread(sub->read_thread, NULL);
        sub->read_thread = NULL;
    }
    
    av_dict_free(&sub->opts);
    if (sub->ic)
        avformat_close_input(&sub->ic);
    av_freep(subp);
}

AVStream * exSub_get_stream(FFExSubtitle *sub)
{
    if (sub->stream_id < sub->ic->nb_streams) {
        return sub->ic->streams[sub->stream_id];
    }
    return NULL;
}

int exSub_get_stream_id(FFExSubtitle *sub)
{
    return sub->stream_id;
}
