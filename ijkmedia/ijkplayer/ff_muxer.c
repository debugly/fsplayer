/*
* ff_record.h
*
* Copyright (c) 2025 debugly <qianlongxu@gmail.com>
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

#include "ff_muxer.h"
#include "ff_ffplay_def.h"
#include "ff_packet_list.h"

typedef struct FSMuxer {
    const AVFormatContext *ifmt_ctx;
    AVFormatContext *ofmt_ctx;
    SDL_Thread *write_tid;
    SDL_Thread _write_tid;
    PacketQueue packetq;
    int has_key_video_frame;
    
    int is_audio_first;
    int is_video_first;
    int64_t audio_start_pts;
    int64_t video_start_pts;
} FSMuxer;

int ff_create_muxer(void **out_ffr, const char *file_name, const AVFormatContext *ifmt_ctx, int audio_stream, int video_stream)
{
    int r = 0;
    
    if (!file_name || !strlen(file_name)) { // 没有路径
        r = -1;
        av_log(NULL, AV_LOG_ERROR, "recrod filename is invalid\n");
        goto end;
    }
    
    if (audio_stream == -1 && video_stream == -1) {
        r = -2;
        av_log(NULL, AV_LOG_ERROR, "recrod stream is invalid\n");
        goto end;
    }
    
    //file_name extension is important!!
    //Could not find tag for codec flv1 in stream #1, codec not currently supported in container
    //vp9 only supported in MP4.
    //Unable to choose an output format for '1747121836247.mkv'; use a standard extension for the filename or specify the format manually.
    
    FSMuxer *fsr = mallocz(sizeof(FSMuxer));
    
    if (packet_queue_init(&fsr->packetq) < 0){
        r = -3;
        goto end;
    }

    // 初始化一个用于输出的AVFormatContext结构体
    avformat_alloc_output_context2(&fsr->ofmt_ctx, NULL, NULL, file_name);
    
    if (!fsr->ofmt_ctx) {
        r = -4;
        av_log(NULL, AV_LOG_ERROR, "recrod check your file extention %s\n", file_name);
        goto end;
    }
    
    for (int i = 0; i < ifmt_ctx->nb_streams; i++) {
        if (i == audio_stream || i == video_stream) {
            AVStream *in_stream = ifmt_ctx->streams[i];
            AVStream *out_stream = avformat_new_stream(fsr->ofmt_ctx, NULL);
            if (!out_stream) {
                r = -5;
                av_log(NULL, AV_LOG_ERROR, "recrod Failed allocating output stream\n");
                goto end;
            }
            AVCodecParameters *in_codecpar = in_stream->codecpar;
            r = avcodec_parameters_copy(out_stream->codecpar, in_codecpar);
            if (r < 0) {
                r = -6;
                av_log(NULL, AV_LOG_ERROR, "recrod Failed to copy context from input to output stream codec context\n");
                goto end;
            }
            out_stream->codecpar->codec_tag = 0;
            // 设置start_time
            out_stream->start_time = AV_NOPTS_VALUE;
            out_stream->index = i;
            if (in_stream->codecpar->extradata_size) {
                out_stream->codecpar->extradata = malloc(in_stream->codecpar->extradata_size);
                memcpy(out_stream->codecpar->extradata, in_stream->codecpar->extradata, in_stream->codecpar->extradata_size);
                out_stream->codecpar->extradata_size = in_stream->codecpar->extradata_size;
            }
//            if (fsr->ofmt_ctx->oformat->flags & AVFMT_GLOBALHEADER) {
//                out_stream->codec->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
//            }
        }
    }
    
    av_dump_format(fsr->ofmt_ctx, 0, file_name, 1);
    fsr->ifmt_ctx = ifmt_ctx;
    
    if (out_ffr) {
        *out_ffr = (void *)fsr;
    }
    return 0;
end:
    return r;
}

static int do_write_muxer(void *ffr, AVPacket *pkt)
{
    if (!ffr) {
        return 0;
    }
    FSMuxer *fsr = (FSMuxer *)ffr;
    int ret = 0;
    
    if (pkt == NULL) {
        av_log(NULL, AV_LOG_ERROR, "recrod packet == NULL");
        return -1;
    }
    
    AVStream *in_stream  = fsr->ifmt_ctx->streams[pkt->stream_index];
    AVStream *out_stream = fsr->ofmt_ctx->streams[pkt->stream_index];
    if (pkt->pts != AV_NOPTS_VALUE) {
        // 转换PTS/DTS
        pkt->pts = av_rescale_q_rnd(pkt->pts, in_stream->time_base, out_stream->time_base, (AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
    } else {
        
    }
    
    pkt->dts = av_rescale_q_rnd(pkt->dts, in_stream->time_base, out_stream->time_base, (AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
    pkt->duration = av_rescale_q(pkt->duration, in_stream->time_base, out_stream->time_base);
    pkt->pos = -1;
    
    if (AVMEDIA_TYPE_AUDIO == in_stream->codecpar->codec_type) {
        if (!fsr->is_audio_first) { // 录制的第一帧
            fsr->is_audio_first = 1;
            fsr->audio_start_pts = pkt->pts;
            pkt->pts = 0;
            pkt->dts = 0;
        } else {
            // 设置了 stream 和 ofmt_ctx 的 start_time都没作用。
            pkt->pts = pkt->pts - fsr->audio_start_pts;
            pkt->dts = pkt->dts - fsr->audio_start_pts;
        }
    } else if (AVMEDIA_TYPE_VIDEO == in_stream->codecpar->codec_type) {
        if (!fsr->is_video_first) { // 录制的第一帧
            fsr->is_video_first = 1;
            fsr->video_start_pts = pkt->pts;
            pkt->pts = 0;
            pkt->dts = 0;
        } else {
            // 设置了 stream 和 ofmt_ctx 的 start_time都没作用。
            pkt->pts = pkt->pts - fsr->video_start_pts;
            pkt->dts = pkt->dts - fsr->video_start_pts;
        }
    }

    // 写入一个AVPacket到输出文件
    if ((ret = av_interleaved_write_frame(fsr->ofmt_ctx, pkt)) < 0) {
        av_log(NULL, AV_LOG_ERROR, "recrod Error muxing packet\n");
    }
    av_packet_unref(pkt);

    return ret;
}

static int write_thread(void *arg)
{
    FSMuxer *fsr = (FSMuxer *)arg;
    
    AVPacket *pkt = av_packet_alloc();
    
    int r = 0;
    // 打开输出文件
    if (!(fsr->ofmt_ctx->oformat->flags & AVFMT_NOFILE)) {
        if (avio_open(&fsr->ofmt_ctx->pb, fsr->ofmt_ctx->url, AVIO_FLAG_WRITE) < 0) {
            r = -8;
            av_log(NULL, AV_LOG_ERROR, "recrod Could not open output file '%s'", fsr->ofmt_ctx->url);
            goto end;
        }
    }
    
    AVDictionary *opts = NULL;
    // 设置 movflags 为 faststart
    if (strcmp(fsr->ofmt_ctx->oformat->name, "mp4") == 0 || strcmp(fsr->ofmt_ctx->oformat->name, "mov") == 0) {
        av_dict_set(&opts, "movflags", "faststart", 0);
    }
    // 写视频文件头
    if (avformat_write_header(fsr->ofmt_ctx, &opts) < 0) {
        r = -9;
        av_log(NULL, AV_LOG_ERROR, "recrod Error occurred when opening output file\n");
        goto end;
    }
    
    while (fsr->packetq.abort_request == 0) {
        int serial = 0;
        int get_pkt = packet_queue_get(&fsr->packetq, pkt, 1, &serial);
        if (get_pkt < 0) {
            r = -10;
            break;
        } else if (get_pkt == 0) {
            r = -11;
            break;
        } else {
            
        }
        
        do_write_muxer(fsr, pkt);
    }
end:
    av_packet_free(&pkt);
    
    if (fsr->ofmt_ctx != NULL) {
        r = av_write_trailer(fsr->ofmt_ctx);
        if (fsr->ofmt_ctx && !(fsr->ofmt_ctx->oformat->flags & AVFMT_NOFILE)) {
            r = avio_close(fsr->ofmt_ctx->pb);
        }
        avformat_free_context(fsr->ofmt_ctx);
        fsr->ofmt_ctx = NULL;
    }
    packet_queue_destroy(&fsr->packetq);
    return r;
}

int ff_start_muxer(void *ffr)
{
    if (!ffr) {
        return -1;
    }
    int r = 0;
    FSMuxer *fsr = (FSMuxer *)ffr;
    packet_queue_start(&fsr->packetq);
    fsr->write_tid = SDL_CreateThreadEx(&fsr->_write_tid, write_thread, fsr, "fsmux");
    if (!fsr->write_tid) {
        av_log(NULL, AV_LOG_FATAL, "recrod SDL_CreateThread(): %s\n", SDL_GetError());
        r = -7;
        goto end;
    }
end:
    return r;
}

static int ff_write_muxer(FSMuxer *fsr, struct AVPacket *packet)
{
    if (!fsr) {
        return -1;
    }
    
    AVPacket *pkt = (AVPacket *)av_malloc(sizeof(AVPacket));
    av_new_packet(pkt, 0);
    av_packet_ref(pkt, packet);
   
    return packet_queue_put(&fsr->packetq, pkt);
}

int ff_write_audio_muxer(void *ffr, struct AVPacket *packet)
{
    if (!ffr) {
        return -1;
    }
    
    FSMuxer *fsr = (FSMuxer *)ffr;
    
    if (!fsr->has_key_video_frame) {
        return -1;
    }
    
    return ff_write_muxer(fsr, packet);
}

int ff_write_video_muxer(void *ffr, struct AVPacket *packet)
{
    if (!ffr) {
        return -1;
    }
    
    FSMuxer *fsr = (FSMuxer *)ffr;
    
    if (!fsr->has_key_video_frame) {
        if (packet->flags & AV_PKT_FLAG_KEY) {
            fsr->has_key_video_frame = 1;
        }
    }
    
    if (!fsr->has_key_video_frame) {
        return -1;
    }
    
    return ff_write_muxer(fsr, packet);
}

void ff_stop_muxer(void *ffr)
{
    if (!ffr) {
        return;
    }
    
    FSMuxer *fsr = (FSMuxer *)ffr;
    packet_queue_abort(&fsr->packetq);
    return;
}

int ff_destroy_muxer(void **ffr)
{
    if (!ffr || !*ffr) {
        return -1;
    }
    int r = 0;
    FSMuxer *fsr = (FSMuxer *)*ffr;
    if (fsr) {
        if (fsr->write_tid) {
            SDL_WaitThread(fsr->write_tid, &r);
        }
        av_freep(ffr);
    }
    return r;
}
