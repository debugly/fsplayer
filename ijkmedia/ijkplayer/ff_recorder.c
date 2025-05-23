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

#include "ff_recorder.h"
#include "ff_ffplay_def.h"
#include "ff_recorder_frame_queue.h"
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

// 视频配置参数
typedef struct {
    int width;               // 视频宽度
    int height;              // 视频高度
    int fps;                 // 帧率
    AVRational time_base;    // 时间基准（1/fps）
    int gop_size;            // GOP 长度（关键帧间隔）
    int bitrate;             // 码率（bps）
} VideoConfig;

// 音频配置参数
typedef struct {
    int sample_rate;         // 采样率（Hz）
    int channels;            // 声道数
    int sample_fmt;          // 采样格式（AV_SAMPLE_FMT_S16等）
    AVRational time_base;    // 时间基准（1/sample_rate）
} AudioConfig;

// 编码器上下文
typedef struct FSRecorder {
    const AVFormatContext *ifmt_ctx;
    AVFormatContext *fmt_ctx;
    AVStream *video_st;
    AVStream *audio_st;
    AVCodecContext *video_codec_ctx;
    AVCodecContext *audio_codec_ctx;
    struct SwsContext *sws_ctx;// 视频缩放上下文（可选）
    SwrContext *swr_ctx;       // 音频重采样上下文（可选）
    int64_t video_pts;         // 视频 PTS 计数器
    int64_t audio_pts;         // 音频 PTS 计数器
    RFrameQueue * framequeue;
    SDL_Thread *write_tid;
    SDL_Thread _write_tid;
    int abort;
} FSRecorder;

static int ff_init_recorder(FSRecorder *fsr, const char *output_file, const AVFormatContext *ifmt_ctx, const VideoConfig *video_cfg, const AudioConfig *audio_cfg)
{
    int r = 0;
    
    if (!output_file || !strlen(output_file)) { // 没有路径
        r = -1;
        av_log(NULL, AV_LOG_ERROR, "recrod filename is invalid");
        goto end;
    }
    //file_name extension is important!!
    //Could not find tag for codec flv1 in stream #1, codec not currently supported in container
    //vp9 only supported in MP4.
    //Unable to choose an output format for '1747121836247.mkv'; use a standard extension for the filename or specify the format manually.
    
    // 初始化一个用于输出的AVFormatContext结构体
    avformat_alloc_output_context2(&fsr->fmt_ctx, NULL, NULL, output_file);
    
    if (!fsr->fmt_ctx) {
        r = -4;
        av_log(NULL, AV_LOG_ERROR, "recrod check your file extention %s\n", output_file);
        goto end;
    }
    
    // ---------------------- 初始化视频流 ----------------------
    // 查找 H.264 编码器
    const AVCodec *video_codec = avcodec_find_encoder(AV_CODEC_ID_H264);
    if (!video_codec) {
        av_log(NULL, AV_LOG_ERROR, "H.264 encoder not found\n");
        return -1;
    }

    // 创建视频流
    fsr->video_st = avformat_new_stream(fsr->fmt_ctx, video_codec);
    if (!fsr->video_st) {
        av_log(NULL, AV_LOG_ERROR, "Failed to create video stream\n");
        return -1;
    }
    fsr->video_st->time_base = video_cfg->time_base;

    // 配置视频编码器上下文
    fsr->video_codec_ctx = avcodec_alloc_context3(video_codec);
    fsr->video_codec_ctx->codec_id = video_codec->id;
    fsr->video_codec_ctx->codec_type = AVMEDIA_TYPE_VIDEO;
    fsr->video_codec_ctx->width = video_cfg->width;
    fsr->video_codec_ctx->height = video_cfg->height;
    fsr->video_codec_ctx->time_base = video_cfg->time_base;
    fsr->video_codec_ctx->framerate = av_inv_q(video_cfg->time_base);
    fsr->video_codec_ctx->gop_size = video_cfg->gop_size;       // GOP 长度
    fsr->video_codec_ctx->max_b_frames = 0;                     // 无 B 帧
    fsr->video_codec_ctx->pix_fmt = AV_PIX_FMT_YUV420P;        // 输出像素格式
    av_opt_set_int(fsr->video_codec_ctx, "preset", 6, 0);       // medium 预设
    av_opt_set_int(fsr->video_codec_ctx, "tune", 1, 0);         // 调整为电影/动画
    av_opt_set_int(fsr->video_codec_ctx, "crf", 23, 0);         // 固定码率控制（23为默认画质）
    av_opt_set_int(fsr->video_codec_ctx, "b", video_cfg->bitrate, 0); // 码率（bps）

    // 打开视频编码器
    if (avcodec_open2(fsr->video_codec_ctx, video_codec, NULL) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Failed to open video codec\n");
        return -1;
    }

    // ---------------------- 初始化音频流 ----------------------
    // 查找 AAC 编码器
    const AVCodec *audio_codec = avcodec_find_encoder(AV_CODEC_ID_AAC);
    if (!audio_codec) {
        av_log(NULL, AV_LOG_ERROR, "AAC encoder not found\n");
        return -1;
    }

    // 创建音频流
    fsr->audio_st = avformat_new_stream(fsr->fmt_ctx, audio_codec);
    if (!fsr->audio_st) {
        av_log(NULL, AV_LOG_ERROR, "Failed to create audio stream\n");
        return -1;
    }
    fsr->audio_st->time_base = audio_cfg->time_base;

    // 配置音频编码器上下文
    fsr->audio_codec_ctx = avcodec_alloc_context3(audio_codec);
    fsr->audio_codec_ctx->codec_id = audio_codec->id;
    fsr->audio_codec_ctx->codec_type = AVMEDIA_TYPE_AUDIO;
    fsr->audio_codec_ctx->sample_rate = audio_cfg->sample_rate;
    fsr->audio_codec_ctx->channels = audio_cfg->channels;
    fsr->audio_codec_ctx->channel_layout = av_get_default_channel_layout(audio_cfg->channels);
    fsr->audio_codec_ctx->sample_fmt = audio_cfg->sample_fmt;
    fsr->audio_codec_ctx->time_base = audio_cfg->time_base;
    av_opt_set_int(fsr->audio_codec_ctx, "bitrate", 128000, 0); // AAC 码率

    // 打开音频编码器
    if (avcodec_open2(fsr->audio_codec_ctx, audio_codec, NULL) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Failed to open audio codec\n");
        return -1;
    }

    // ---------------------- 初始化格式上下文 ----------------------
    // 设置输出文件参数
    if (fsr->fmt_ctx->oformat->flags & AVFMT_GLOBALHEADER) {
        fsr->video_codec_ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }

    // 写入文件头
    if (avio_open(&fsr->fmt_ctx->pb, output_file, AVIO_FLAG_WRITE) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Failed to open output file\n");
        return -1;
    }
    
    av_dump_format(fsr->fmt_ctx, 0, output_file, 1);
    
    AVDictionary *opts = NULL;
    // 设置 movflags 为 faststart
    if (strcmp(fsr->fmt_ctx->oformat->name, "mp4") == 0 || strcmp(fsr->fmt_ctx->oformat->name, "mov") == 0) {
        av_dict_set(&opts, "movflags", "faststart", 0);
    }
    
    if (avformat_write_header(fsr->fmt_ctx, &opts) < 0) {
            av_log(NULL, AV_LOG_ERROR, "Failed to write header\n");
            return -1;
    }

    // 初始化 PTS 计数器
    fsr->video_pts = 0;
    fsr->audio_pts = 0;
    
    fsr->ifmt_ctx = ifmt_ctx;

    // 创建队列
    fsr->framequeue = rframe_queue_create(100);

    return 0;
end:
    return r;
}

int ff_create_recorder(void **out_ffr, const char *output_file, const struct AVFormatContext *ifmt_ctx)
{
    FSRecorder *fsr = mallocz(sizeof(FSRecorder));
    
    // 视频配置
    VideoConfig video_cfg = {
        .width = 1920,
        .height = 1080,
        .fps = 30,
        .time_base = (AVRational){1, 30},
        .gop_size = 30,
        .bitrate = 4000000, // 4 Mbps
    };

    // 音频配置（假设输入为 44.1kHz 立体声 16位 PCM）
    AudioConfig audio_cfg = {
        .sample_rate = 44100,
        .channels = 2,
        .sample_fmt = AV_SAMPLE_FMT_S16,
        .time_base = (AVRational){1, 44100},
    };
    
    int ret = ff_init_recorder(fsr, output_file, ifmt_ctx, &video_cfg, &audio_cfg);
    if (ret) {
        freep((void **)&fsr);
        return ret;
    }
    
    if (out_ffr) {
        *out_ffr = (void *)fsr;
    }
    return 0;
}

// 发送视频帧到录制器（原 encode_video_frame）
int record_video_frame(FSRecorder *rec_ctx, AVFrame *frame) {
    AVPacket pkt = {0};
    av_init_packet(&pkt);

    // 设置 PTS
    frame->pts = rec_ctx->video_pts++;

    // 发送帧到编码器
    if (avcodec_send_frame(rec_ctx->video_codec_ctx, frame) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Failed to send video frame to encoder\n");
        av_packet_unref(&pkt);
        return -1;
    }

    // 接收编码后的数据包
    while (avcodec_receive_packet(rec_ctx->video_codec_ctx, &pkt) == 0) {
        pkt.stream_index = rec_ctx->video_st->index;
        av_packet_rescale_ts(&pkt, rec_ctx->video_codec_ctx->time_base,
                            rec_ctx->fmt_ctx->streams[0]->time_base);
        if (av_interleaved_write_frame(rec_ctx->fmt_ctx, &pkt) < 0) {
            av_log(NULL, AV_LOG_ERROR, "Failed to write video packet\n");
            av_packet_unref(&pkt);
            return -1;
        }
        av_packet_unref(&pkt);
    }

    return 0;
}

// 发送音频帧到录制器（原 encode_audio_frame）
int record_audio_frame(FSRecorder *rec_ctx, AVFrame *frame)
{
    AVPacket pkt = {0};
    av_init_packet(&pkt);

    // 设置 PTS
    frame->pts = rec_ctx->audio_pts;
    rec_ctx->audio_pts += frame->nb_samples; // 按采样数递增

    // 发送帧到编码器
    if (avcodec_send_frame(rec_ctx->audio_codec_ctx, frame) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Failed to send audio frame to encoder\n");
        av_packet_unref(&pkt);
        return -1;
    }

    // 接收编码后的数据包
    while (avcodec_receive_packet(rec_ctx->audio_codec_ctx, &pkt) == 0) {
        pkt.stream_index = rec_ctx->audio_st->index;
        av_packet_rescale_ts(&pkt, rec_ctx->audio_codec_ctx->time_base,
                            rec_ctx->fmt_ctx->streams[1]->time_base);
        if (av_interleaved_write_frame(rec_ctx->fmt_ctx, &pkt) < 0) {
            av_log(NULL, AV_LOG_ERROR, "Failed to write audio packet\n");
            av_packet_unref(&pkt);
            return -1;
        }
        av_packet_unref(&pkt);
    }

    return 0;
}

// 关闭录制器
static int close_fs_recorder(FSRecorder *rec_ctx) {
    int r = 0;
    // 刷新视频编码器
    record_video_frame(rec_ctx, NULL);
    // 刷新音频编码器
    record_audio_frame(rec_ctx, NULL);
    // 写入文件尾
    r = av_write_trailer(rec_ctx->fmt_ctx);

    // 释放资源
    if (rec_ctx->sws_ctx) sws_freeContext(rec_ctx->sws_ctx);
    if (rec_ctx->swr_ctx) swr_free(&rec_ctx->swr_ctx);
    if (rec_ctx->video_codec_ctx) avcodec_free_context(&rec_ctx->video_codec_ctx);
    if (rec_ctx->audio_codec_ctx) avcodec_free_context(&rec_ctx->audio_codec_ctx);
    if (rec_ctx->fmt_ctx) {
        avio_closep(&rec_ctx->fmt_ctx->pb);
        avformat_free_context(rec_ctx->fmt_ctx);
    }
    
    //销毁队列
    rframe_queue_destroy(rec_ctx->framequeue);
    return r;
}

/**
 * 判断AVFrame是视频还是音频
 * @param frame AVFrame指针
 * @return 1=视频，0=音频，-1=无效帧
 */
static int avframe_is_video(const AVFrame *frame) {
    if (!frame) return -1;
    
    // 视频帧判断：有宽度和高度，且像素格式有效
    if (frame->width > 0 && frame->height > 0 &&
        frame->format >= 0 && frame->format < AV_PIX_FMT_NB) {
        return 1;
    }
    
    // 音频帧判断：有采样数和声道布局，且采样格式有效
    if (frame->nb_samples > 0 && frame->channel_layout != 0 &&
        frame->format >= 0 && frame->format < AV_SAMPLE_FMT_NB) {
        return 0;
    }
    
    return -1; // 无效帧
}

static int write_thread(void *arg)
{
    FSRecorder *fsr = (FSRecorder *)arg;
    
    while (fsr->abort == 0) {
        // 从队列中获取帧
        AVFrame *frame = rframe_queue_get(fsr->framequeue);
        if (frame) {
            int type = avframe_is_video(frame);
            if (type == 1) {
                record_video_frame(fsr, frame);
            } else if (type == 0) {
                record_audio_frame(fsr, frame);
            } else {
                //
            }
            // 释放帧
            av_frame_free(&frame);
        }
    }

    int r = close_fs_recorder(fsr);
    return r;
}

int ff_start_recorder(void *ffr)
{
    if (!ffr) {
        return -1;
    }
    int r = 0;
    FSRecorder *fsr = (FSRecorder *)ffr;
    
    fsr->write_tid = SDL_CreateThreadEx(&fsr->_write_tid, write_thread, fsr, "fsrecord");
    if (!fsr->write_tid) {
        av_log(NULL, AV_LOG_FATAL, "recrod SDL_CreateThread(): %s\n", SDL_GetError());
        r = -7;
        goto end;
    }
end:
    return r;
}

int ff_write_recorder(void *ffr, struct AVFrame *frame)
{
    if (!ffr) {
        return -1;
    }
    
    FSRecorder *fsr = (FSRecorder *)ffr;
    return rframe_queue_put(fsr->framequeue, frame);
}

void ff_stop_recorder(void *ffr)
{
    if (!ffr) {
        return;
    }
    
    FSRecorder *fsr = (FSRecorder *)ffr;
    // 关闭
    rframe_queue_close(fsr->framequeue);
    fsr->abort = 1;
    return;
}

int ff_destroy_recorder(void **ffr)
{
    if (!ffr || !*ffr) {
        return -1;
    }
    int r = 0;
    FSRecorder *fsr = (FSRecorder *)*ffr;
    if (fsr) {
        if (fsr->write_tid) {
            SDL_WaitThread(fsr->write_tid, &r);
        }
        av_freep(ffr);
    }
    return r;
}
