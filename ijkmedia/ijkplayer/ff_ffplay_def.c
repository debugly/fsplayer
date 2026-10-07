/*
 *  ff_play_def.c
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


#include "ff_ffplay_def.h"
#include "ff_packet_list.h"
#include "ff_frame_queue.h"

int decoder_init(Decoder *d, AVCodecContext *avctx, PacketQueue *queue, SDL_cond *empty_queue_cond) 
{
    memset(d, 0, sizeof(Decoder));
    d->pkt = av_packet_alloc();
    if (!d->pkt)
        return AVERROR(ENOMEM);
    d->avctx = avctx;
    d->queue = queue;
    d->empty_queue_cond = empty_queue_cond;
    d->start_pts = AV_NOPTS_VALUE;
    d->pkt_serial = 1;
    d->first_frame_decoded_time = SDL_GetTickHR();
    d->first_frame_decoded = 0;
    d->after_seek_frame = 0;
    SDL_ProfilerReset(&d->decode_profiler, -1);
    return 0;
}

int decoder_start(Decoder *d, int (*fn)(void *), void *arg, const char *name)
{
    packet_queue_start(d->queue);
    if (d->pkt_serial != d->queue->serial) {
        av_log(NULL, AV_LOG_INFO, "correct %s serial from %d to %d\n", name, d->pkt_serial, d->queue->serial);
        d->pkt_serial = d->queue->serial;
    }
    
    d->decoder_tid = SDL_CreateThreadEx(&d->_decoder_tid, fn, arg, name);
    if (!d->decoder_tid) {
        av_log(NULL, AV_LOG_ERROR, "SDL_CreateThread(): %s\n", SDL_GetError());
        return AVERROR(ENOMEM);
    }
    return 0;
}

void decoder_destroy(Decoder *d)
{
    av_bsf_free(&d->bsf);
    av_packet_free(&d->pkt);
    avcodec_free_context(&d->avctx);
}


/*
 * 把 avctx->extradata 从 AVCC（MP4 的 avcC 记录）换成等价的 Annex-B
 * （start code + SPS/PPS）。
 *
 * 目的：avcodec_open2 内部会按 AVCodec.bsfs 建一个 h264_mp4toannexb 过滤器
 * （decode.c 的 decode_bsfs_init）。实测在 MP4 上它虽然建起来了、却没能把
 * AVCC 码流转换好，MediaCodec 因此一帧不吐；而本来是 Annex-B 的源（TS）能正常
 * 解码。所以转换由调用方自己做（见 decoder_bsf_init）。
 *
 * 为了不让两份过滤器叠加，这里把 extradata 置成 Annex-B：内部那份过滤器会
 * 因此认定"码流本来就是 Annex-B"而直接放行（见 bsf/h264_mp4toannexb.c 的
 * h264_mp4toannexb_init 开头），转换只由调用方那一份完成。解码器仍可从
 * Annex-B 的 extradata 解析出 SPS/PPS 作为 csd。
 *
 * AVCC->Annex-B 的解析复用 FFmpeg 自己的过滤器，不另写 avcC 解析。
 */
int decoder_extradata_annexb(AVCodecContext *avctx, AVStream *st)
{
    const AVBitStreamFilter *filter;
    AVBSFContext *bsf = NULL;
    const char *bsf_name = NULL;
    uint8_t *extra;
    int ret;

    if (!avctx || !st || !st->codecpar->extradata ||
        st->codecpar->extradata_size < 7)
        return 0;
    /* avcC 记录以 configurationVersion=1 开头，Annex-B 不是 */
    if (st->codecpar->extradata[0] != 1)
        return 0;

    if (avctx->codec_id == AV_CODEC_ID_H264)
        bsf_name = "h264_mp4toannexb";
    else if (avctx->codec_id == AV_CODEC_ID_HEVC)
        bsf_name = "hevc_mp4toannexb";
    if (!bsf_name)
        return 0;

    filter = av_bsf_get_by_name(bsf_name);
    if (!filter)
        return AVERROR(EINVAL);

    ret = av_bsf_alloc(filter, &bsf);
    if (ret < 0)
        return ret;

    ret = avcodec_parameters_copy(bsf->par_in, st->codecpar);
    if (ret >= 0) {
        bsf->time_base_in = st->time_base;
        ret = av_bsf_init(bsf);
    }
    if (ret < 0) {
        av_bsf_free(&bsf);
        return ret;
    }

    if (bsf->par_out->extradata && bsf->par_out->extradata_size > 0 &&
        bsf->par_out->extradata != st->codecpar->extradata) {
        extra = av_mallocz(bsf->par_out->extradata_size +
                           AV_INPUT_BUFFER_PADDING_SIZE);
        if (extra) {
            memcpy(extra, bsf->par_out->extradata, bsf->par_out->extradata_size);
            av_freep(&avctx->extradata);
            avctx->extradata      = extra;
            avctx->extradata_size = bsf->par_out->extradata_size;
            av_log(avctx, AV_LOG_INFO,
                   "extradata converted to annexb: %d -> %d bytes\n",
                   st->codecpar->extradata_size, avctx->extradata_size);
        }
    }

    av_bsf_free(&bsf);
    return 0;
}

/*
 * 给解码器挂上它声明的码流封装转换（AVCodec.bsfs 里声明的过滤器，例如
 * MediaCodec 系列解码器要的 h264_mp4toannexb：MP4 存的是 AVCC 长度前缀
 * 码流，MediaCodec 只吃 Annex-B）。
 *
 * 配合 decoder_extradata_annexb 使用：先调它把 extradata 换成 Annex-B，
 * 再在 avcodec_open2 之后调本函数建真正的过滤器。avctx->extradata 已不是
 * AVCC，所以只认 st->codecpar 上的原始 extradata。
 */
int decoder_bsf_init(Decoder *d, AVCodecContext *avctx, AVStream *st)
{
    const AVBitStreamFilter *filter;
    const char *bsf_name = NULL;
    int ret;

    av_bsf_free(&d->bsf);
    d->bsf_insert_aud = 0;

    if (!avctx || !st || !st->codecpar->extradata)
        return 0;

    if (avctx->codec_id == AV_CODEC_ID_H264) {
        bsf_name = "h264_mp4toannexb";
        /*
         * MediaCodec 解码器（至少 TV 模拟器上的 c2.goldfish.h264.decoder）
         * 靠 AUD（Access Unit Delimiter）划分访问单元。MP4 里不带 AUD，只喂
         * Annex-B 的话入队全部正常、输入缓冲也都被回收，但一帧输出都没有；
         * TS 之所以能播，只是因为 mpegts 封装会自动插入 AUD。AUD 是标准 NAL，
         * 对不需要它的解码器也无害，所以这里统一补上。
         */
        d->bsf_insert_aud = 1;
    } else if (avctx->codec_id == AV_CODEC_ID_HEVC) {
        bsf_name = "hevc_mp4toannexb";
    } else {
        return 0;
    }

    /* 源本来就是 Annex-B（TS 等）时无需转换 */
    if (st->codecpar->extradata_size < 7 || st->codecpar->extradata[0] != 1)
        return 0;

    filter = av_bsf_get_by_name(bsf_name);
    if (!filter) {
        av_log(avctx, AV_LOG_ERROR, "bsf %s not found.\n", bsf_name);
        return AVERROR(EINVAL);
    }

    ret = av_bsf_alloc(filter, &d->bsf);
    if (ret < 0)
        return ret;

    ret = avcodec_parameters_copy(d->bsf->par_in, st->codecpar);
    if (ret >= 0) {
        d->bsf->time_base_in = st->time_base;
        ret = av_bsf_init(d->bsf);
    }
    if (ret < 0) {
        av_bsf_free(&d->bsf);
        d->bsf_insert_aud = 0;
        return ret;
    }

    av_log(avctx, AV_LOG_INFO, "decoder bsf enabled: %s (aud=%d)\n",
           filter->name, d->bsf_insert_aud);
    return 0;
}

void decoder_abort(Decoder *d, FrameQueue *fq)
{
    packet_queue_abort(d->queue);
    frame_queue_signal(fq);
    SDL_WaitThread(d->decoder_tid, NULL);
    d->decoder_tid = NULL;
    packet_queue_flush(d->queue);
}
