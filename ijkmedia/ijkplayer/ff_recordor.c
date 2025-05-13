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

#include "ff_recordor.h"
#include "ff_ffplay_def.h"

typedef struct FSRecordor {
    const AVFormatContext *ifmt_ctx;
    AVFormatContext *ofmt_ctx;
    pthread_mutex_t record_mutex;
    int is_record;

    int is_video_first;
    int is_audio_first;
    int64_t start_pts;
    int64_t start_dts;
} FSRecordor;

int ff_create_recordor(void **out_ffr, const char *file_name, const AVFormatContext *ifmt_ctx, int audio_stream, int video_stream)
{
    int r = 0;
    
    if (!file_name || !strlen(file_name)) { // 没有路径
        r = -1;
        av_log(NULL, AV_LOG_ERROR, "filename is invalid");
        goto end;
    }
    //file_name extension is important!!
    //Could not find tag for codec flv1 in stream #1, codec not currently supported in container
    //vp9 only supported in MP4.
    //Unable to choose an output format for '1747121836247.mkv'; use a standard extension for the filename or specify the format manually.
    
    FSRecordor *fsr = mallocz(sizeof(FSRecordor));
    // 初始化一个用于输出的AVFormatContext结构体
    avformat_alloc_output_context2(&fsr->ofmt_ctx, NULL, NULL, file_name);
    
    if (!fsr->ofmt_ctx) {
        r = -4;
        av_log(NULL, AV_LOG_ERROR, "check your file extention %s\n", file_name);
        goto end;
    }
     
    for (int i = 0; i < ifmt_ctx->nb_streams; i++) {
        if (i == audio_stream || i == video_stream) {
            AVStream *in_stream = ifmt_ctx->streams[i];
            AVStream *out_stream = avformat_new_stream(fsr->ofmt_ctx, NULL);
            if (!out_stream) {
                r = -5;
                av_log(NULL, AV_LOG_ERROR, "Failed allocating output stream\n");
                goto end;
            }
            AVCodecParameters *in_codecpar = in_stream->codecpar;
            r = avcodec_parameters_copy(out_stream->codecpar, in_codecpar);
            if (r < 0) {
                r = -6;
                av_log(NULL, AV_LOG_ERROR, "Failed to copy context from input to output stream codec context\n");
                goto end;
            }
            out_stream->codecpar->codec_tag = 0;
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

int ff_start_recordor(void *ffr)
{
    if (!ffr) {
        return -1;
    }
    int r = 0;
    FSRecordor *fsr = (FSRecordor *)ffr;
    // 打开输出文件
    if (!(fsr->ofmt_ctx->oformat->flags & AVFMT_NOFILE)) {
        if (avio_open(&fsr->ofmt_ctx->pb, fsr->ofmt_ctx->url, AVIO_FLAG_WRITE) < 0) {
            r = -7;
            av_log(NULL, AV_LOG_ERROR, "Could not open output file '%s'", fsr->ofmt_ctx->url);
            goto end;
        }
    }
    
    // 写视频文件头
    if (avformat_write_header(fsr->ofmt_ctx, NULL) < 0) {
        r = -8;
        av_log(NULL, AV_LOG_ERROR, "Error occurred when opening output file\n");
        goto end;
    }
    
    fsr->is_record = 1;
    pthread_mutex_init(&fsr->record_mutex, NULL);
end:
    return r;
}

int ff_write_recordor(void *ffr, AVPacket *packet)
{
    if (!ffr) {
        return 0;
    }
    FSRecordor *fsr = (FSRecordor *)ffr;
    int ret = 0;
    AVStream *in_stream;
    AVStream *out_stream;
    
    if (fsr->is_record) {
        if (packet == NULL) {
            av_log(NULL, AV_LOG_ERROR, "packet == NULL");
            return -1;
        }
        
        AVPacket *pkt = (AVPacket *)av_malloc(sizeof(AVPacket)); // 与看直播的 AVPacket分开，不然卡屏
        av_new_packet(pkt, 0);
        if (0 == av_packet_ref(pkt, packet)) {
            pthread_mutex_lock(&fsr->record_mutex);
            
//            if (!fsr->is_first) { // 录制的第一帧，时间从0开始
//                fsr->is_first = 1;
//                pkt->pts = 0;
//                pkt->dts = 0;
//            } else { // 之后的每一帧都要减去，点击开始录制时的值，这样的时间才是正确的
//                pkt->pts = abs(pkt->pts - fsr->start_pts);
//                pkt->dts = abs(pkt->dts - fsr->start_dts);
//            }
            
            in_stream  = fsr->ifmt_ctx->streams[pkt->stream_index];
            out_stream = fsr->ofmt_ctx->streams[pkt->stream_index];
            if (pkt->pts != AV_NOPTS_VALUE) {
                // 转换PTS/DTS
                pkt->pts = av_rescale_q_rnd(pkt->pts, in_stream->time_base, out_stream->time_base, (AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
            } else {
                
            }
            
            pkt->dts = av_rescale_q_rnd(pkt->dts, in_stream->time_base, out_stream->time_base, (AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
            pkt->duration = av_rescale_q(pkt->duration, in_stream->time_base, out_stream->time_base);
            pkt->pos = -1;
            
            if (in_stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
                if (!fsr->is_audio_first) { // 录制的第一帧
                    fsr->is_audio_first = 1;
                    out_stream->start_time = pkt->pts;
                }
                //printf("write audio pts:%lld\n",pkt->pts);
            } else if (in_stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
                if (!fsr->is_video_first) { // 录制的第一帧
                    fsr->is_video_first = 1;
                    out_stream->start_time = pkt->pts;
                }
                //printf("write video pts:%lld\n",pkt->pts);
            }
            
            // 写入一个AVPacket到输出文件
            if ((ret = av_interleaved_write_frame(fsr->ofmt_ctx, pkt)) < 0) {
                av_log(NULL, AV_LOG_ERROR, "Error muxing packet\n");
            }
            
            av_packet_unref(pkt);
            pthread_mutex_unlock(&fsr->record_mutex);
        } else {
            av_log(NULL, AV_LOG_ERROR, "av_packet_ref == NULL");
        }
    }
    return ret;
}

int ff_stop_recordor(void *ffr)
{
    if (!ffr) {
        return -1;
    }
    
    FSRecordor *fsr = (FSRecordor *)ffr;
    if (!fsr->is_record) {
        return -2;
    }
    
    int ret = 0;
    
    pthread_mutex_lock(&fsr->record_mutex);
    if (fsr->ofmt_ctx != NULL) {
        ret = av_write_trailer(fsr->ofmt_ctx);
        if (fsr->ofmt_ctx && !(fsr->ofmt_ctx->oformat->flags & AVFMT_NOFILE)) {
            ret = avio_close(fsr->ofmt_ctx->pb);
        }
        avformat_free_context(fsr->ofmt_ctx);
        fsr->ofmt_ctx = NULL;
        fsr->is_video_first = 0;
        fsr->is_audio_first = 0;
    }
    fsr->is_record = 0;
    pthread_mutex_unlock(&fsr->record_mutex);
    return ret;
}

void ff_destroy_recordor(void **ffr)
{
    if (!ffr || !*ffr) {
        return;
    }
    FSRecordor *fsr = (FSRecordor *)(*ffr);
    pthread_mutex_destroy(&fsr->record_mutex);
    av_freep(ffr);
}
