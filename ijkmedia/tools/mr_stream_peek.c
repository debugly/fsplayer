//
//  mr_stream_peek.c
//
// ijkplayer not use the file, but the file will be used by other module in app.
//
//  Created by debugly on 2023/9/7.
//

#include "mr_stream_peek.h"
#include "mr_stream_component.h"
#include "ff_frame_queue.h"
#include "ff_packet_list.h"
#include "ff_ffplay_def.h"
#include "ff_ffplay_debug.h"
#include <libavformat/avformat.h>
#include <libswresample/swresample.h>

#define MRSampleFormat AV_SAMPLE_FMT_S16P
#define MRSampleRate   16000
#define MRNBChannels   1

typedef struct MRStreamPeeker {
    SDL_mutex* mutex;
    MRStreamComponent* opaque;
    AVFormatContext* ic;
    int stream_idx;
    PacketQueue pktq;
    FrameQueue frameq;
    
    struct SwrContext *swr_ctx;
    struct AudioParams audio_src;
    
    int audio_buf_index;
    int audio_buf_size;
    uint8_t *audio_buf;
    uint8_t *audio_buf1;
    unsigned int audio_buf1_size;
    double audio_clock;
    int audio_clock_serial;
    //video duration
    int duration;
}MRStreamPeeker;

int mr_stream_peek_create(MRStreamPeeker **spp,int frameCacheCount)
{
    if (!spp) {
        return -1;
    }
    
    MRStreamPeeker *sp = av_malloc(sizeof(MRStreamPeeker));
    if (!sp) {
        return -2;
    }
    bzero(sp, sizeof(MRStreamPeeker));
    
    sp->mutex = SDL_CreateMutex();
    if (NULL == sp->mutex) {
        av_free(sp);
       return -2;
    }
    
    if (packet_queue_init(&sp->pktq) < 0) {
        av_free(sp);
        return -3;
    }
    
    if (frame_queue_init(&sp->frameq, &sp->pktq, frameCacheCount, 0) < 0) {
        packet_queue_destroy(&sp->pktq);
        av_free(sp);
        return -4;
    }
    
    sp->stream_idx = -1;
    *spp = sp;
    return 0;
}

int mr_stream_peek_get_opened_stream_idx(MRStreamPeeker *sp)
{
    if (sp && sp->opaque) {
        return sp->stream_idx;
    }
    return -1;
}

int mr_stream_peek_seek_to(MRStreamPeeker *sp, float sec)
{
    if (!sp || !sp->opaque) {
        return -1;
    }
    return streamComponent_seek_to(sp->opaque, sec);
}

//FILE *file_pcm_l = NULL;
static int audio_decode_frame(MRStreamPeeker *sp)
{
    if (sp->pktq.abort_request)
        return -1;
    
    Frame *af;
    
    //skip old audio frames.
    do {
        af = frame_queue_peek_readable_noblock(&sp->frameq);
        if (af == NULL) {
            if (streamComponent_eof_and_pkt_empty(sp->opaque)) {
                return -1;
            } else {
                av_usleep(10);
            }
        } else {
            if (af->serial != sp->pktq.serial) {
                frame_queue_next(&sp->frameq);
                continue;
            } else {
                break;
            }
        }
    } while (1);
    
    AVFrame *frame = af->frame;
    
    static int flag = 1;
    
    if (flag) {
        av_log(NULL, AV_LOG_WARNING, "audio sample rate:%d\n",frame->sample_rate);
        av_log(NULL, AV_LOG_WARNING, "audio format:%s\n",av_get_sample_fmt_name(frame->format));
        flag = 0;
    }
    
    int need_convert =  frame->format != sp->audio_src.fmt ||
                        av_channel_layout_compare(&frame->ch_layout, &sp->audio_src.ch_layout) ||
                        frame->sample_rate != sp->audio_src.freq ||
                        !sp->swr_ctx;

    if (need_convert) {
        swr_free(&sp->swr_ctx);
        AVChannelLayout layout;
        av_channel_layout_default(&layout, MRNBChannels);
        swr_alloc_set_opts2(&sp->swr_ctx,
                            &layout, MRSampleFormat, MRSampleRate,
                            &frame->ch_layout, frame->format, frame->sample_rate,
                            0, NULL);
        if (!sp->swr_ctx) {
            av_log(NULL, AV_LOG_ERROR,
                   "swr_alloc_set_opts2 failed!\n");
            return -1;
        }
        
        if (swr_init(sp->swr_ctx) < 0) {
            av_log(NULL, AV_LOG_ERROR,
                   "Cannot create sample rate converter for conversion of %d Hz %s %d channels to %d Hz %s %d channels!\n",
                    frame->sample_rate, av_get_sample_fmt_name(frame->format), frame->ch_layout.nb_channels,
                   MRSampleRate, av_get_sample_fmt_name(MRSampleFormat), layout.nb_channels);
            swr_free(&sp->swr_ctx);
            return -1;
        }
        
        if (av_channel_layout_copy(&sp->audio_src.ch_layout, &frame->ch_layout) < 0)
            return -1;
        sp->audio_src.freq = frame->sample_rate;
        sp->audio_src.fmt = frame->format;
    }

    int resampled_data_size;
    if (sp->swr_ctx) {
        int out_count = (int)((int64_t)frame->nb_samples * MRSampleRate / frame->sample_rate + 256);
        int out_size = av_samples_get_buffer_size(NULL, MRNBChannels, out_count, MRSampleFormat, 0);
        int len2;
        if (out_size < 0) {
            av_log(NULL, AV_LOG_ERROR, "av_samples_get_buffer_size() failed\n");
            return -1;
        }
        av_fast_malloc(&sp->audio_buf1, &sp->audio_buf1_size, out_size);

        const uint8_t **in = (const uint8_t **)frame->extended_data;
        uint8_t **out = &sp->audio_buf1;
        
        if (!sp->audio_buf1)
            return AVERROR(ENOMEM);
        len2 = swr_convert(sp->swr_ctx, out, out_count, in, frame->nb_samples);
        if (len2 < 0) {
            av_log(NULL, AV_LOG_ERROR, "swr_convert() failed\n");
            return -1;
        }
        if (len2 == out_count) {
            av_log(NULL, AV_LOG_WARNING, "audio buffer is probably too small\n");
            if (swr_init(sp->swr_ctx) < 0)
                swr_free(&sp->swr_ctx);
        }
        sp->audio_buf = sp->audio_buf1;
        int bytes_per_sample = av_get_bytes_per_sample(MRSampleFormat);
        resampled_data_size = len2 * MRNBChannels * bytes_per_sample;
    } else {
        sp->audio_buf = frame->data[0];
        resampled_data_size = av_samples_get_buffer_size(NULL,
                                                   frame->ch_layout.nb_channels,
                                                   frame->nb_samples,
                                                   frame->format,
                                                   1);
    }

    /* update the audio clock with the pts */
    if (!isnan(af->pts))
        sp->audio_clock = af->pts;
    
    sp->audio_clock_serial = af->serial;

//    if (file_pcm_l == NULL) {
//        file_pcm_l = fopen("/Users/matt/Library/Containers/2E018519-4C6C-4E16-B3B1-9F3ED37E67E5/Data/tmp/3.pcm", "wb+");
//    }
//    fwrite(sp->audio_buf, resampled_data_size, 1, file_pcm_l);
    
    frame_queue_next(&sp->frameq);
    return resampled_data_size;
}

static int bytes_per_millisecond(void)
{
    static int _bytes_per_millisecond = 0;

    if (_bytes_per_millisecond == 0) {
        _bytes_per_millisecond = av_samples_get_buffer_size(NULL, MRNBChannels, MRSampleRate / 1000, MRSampleFormat, 1);
    }
    return _bytes_per_millisecond;
}

static int bytes_per_sec(void)
{
    return bytes_per_millisecond() * 1000;
}

int mr_stream_peek_get_data(MRStreamPeeker *peeker, unsigned char *buffer, int len, double * pts_begin, double * pts_end)
{
    const int len_want = len;
    double begin = -1, end = -1;
    
    if (!peeker) {
        return -1;
    }
    
    while (len > 0) {
        if (peeker->audio_buf_index >= peeker->audio_buf_size) {
            int audio_size = audio_decode_frame(peeker);
            if (audio_size < 0) {
                /* if error, just output silence */
                peeker->audio_buf = NULL;
                peeker->audio_buf_size = 0;
                goto the_end;
            } else {
                peeker->audio_buf_size = audio_size;
            }
            peeker->audio_buf_index = 0;
        }
        
        if (streamComponent_get_pkt_serial(peeker->opaque) != peeker->pktq.serial) {
            peeker->audio_buf_index = peeker->audio_buf_size;
            break;
        }
        int rest_len = peeker->audio_buf_size - peeker->audio_buf_index;
        
        if (begin < 0) {
            begin = peeker->audio_clock + peeker->audio_buf_index / bytes_per_sec();
        }
        
        if (rest_len > len)
            rest_len = len;
        memcpy(buffer, (uint8_t *)peeker->audio_buf + peeker->audio_buf_index, rest_len);
        len -= rest_len;
        buffer += rest_len;
        peeker->audio_buf_index += rest_len;
    }
the_end:
    
    end = peeker->audio_clock + peeker->audio_buf_index / bytes_per_sec();
    if (pts_begin) {
        *pts_begin = begin;
    }
    
    if (pts_end) {
        *pts_end = end;
    }
    
    return len_want - len;
}

int mr_stream_peek_open_filepath(MRStreamPeeker *peeker, const char *file_name, int idx)
{
    if (!peeker) {
        return -1;
    }

    if (!file_name || strlen(file_name) == 0) {
        return -2;
    }
        
    int ret = 0;
    AVFormatContext* ic = NULL;
    AVCodecContext* avctx = NULL;
    
    if (avformat_open_input(&ic, file_name, NULL, NULL) < 0) {
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
    
    if (idx == -1) {
        int st_index_video = -1;
        int st_index_audio = -1;
        for (int i = 0; i < ic->nb_streams; i++) {
            AVStream *st = ic->streams[i];
            enum AVMediaType type = st->codecpar->codec_type;
            st->discard = AVDISCARD_ALL;
            // choose first h264

            if (type == AVMEDIA_TYPE_VIDEO) {
                enum AVCodecID codec_id = st->codecpar->codec_id;
                if (codec_id == AV_CODEC_ID_H264) {
                    st_index_video = i;
                    break;
                }
            }
        }
        
        st_index_video =
            av_find_best_stream(ic, AVMEDIA_TYPE_VIDEO,
                                st_index_video, -1, NULL, 0);
            
        st_index_audio =
            av_find_best_stream(ic, AVMEDIA_TYPE_AUDIO,
                                st_index_audio,
                                st_index_video,
                                NULL, 0);
        if (st_index_audio >= 0) {
            idx = st_index_audio;
        }
    }
    
    if (idx == -1) {
        av_log(NULL, AV_LOG_WARNING, "could find audio stream:%s\n", file_name);
        ret = -3;
        goto fail;
    }
    
    AVStream *stream = ic->streams[idx];
    stream->discard = AVDISCARD_DEFAULT;
    
    if (!stream) {
        ret = -3;
        av_log(NULL, AV_LOG_ERROR, "none audio stream in %s\n", file_name);
        goto fail;
    }
    
    const AVCodec* codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) {
        av_log(NULL, AV_LOG_WARNING, "could find codec:%s for %s\n",
                file_name, avcodec_get_name(stream->codecpar->codec_id));
        ret = -4;
        goto fail;
    }
    
    avctx = avcodec_alloc_context3(NULL);
    if (!avctx) {
        ret = -5;
        goto fail;
    }

    if (avcodec_parameters_to_context(avctx, stream->codecpar) < 0) {
        ret = -6;
        goto fail;
    }
    //so important,ohterwise, sub frame has not pts.
    avctx->pkt_timebase = stream->time_base;
    
    if (avcodec_open2(avctx, codec, NULL) < 0) {
        ret = -7;
        goto fail;
    }
    
    if (streamComponent_open(&peeker->opaque, idx, ic, avctx, &peeker->pktq, &peeker->frameq) != 0) {
        ret = -8;
        goto fail;
    }
    peeker->duration = (int)(ic->duration / AV_TIME_BASE);
    peeker->ic = ic;
    peeker->stream_idx = idx;
    return 0;
fail:
    if (ret < 0) {
        if (ic)
            avformat_close_input(&ic);
        if (avctx)
            avcodec_free_context(&avctx);
    }
    return ret;
}

int mr_stream_peek_close(MRStreamPeeker *peeker)
{
    if(!peeker) {
        return -1;
    }
    
    MRStreamComponent *opaque = peeker->opaque;
    
    if(!opaque) {
        if (peeker->ic)
            avformat_close_input(&peeker->ic);
        return -2;
    }
    
    int r = streamComponent_close(&opaque);
    SDL_LockMutex(peeker->mutex);
    peeker->opaque = NULL;
    if (peeker->ic)
        avformat_close_input(&peeker->ic);
    SDL_UnlockMutex(peeker->mutex);
    return r;
}

void mr_stream_peek_destroy(MRStreamPeeker **peeker_out)
{
    if (!peeker_out) {
        return;
    }
    
    MRStreamPeeker *peeker = *peeker_out;
    if (!peeker) {
        return;
    }
    
    mr_stream_peek_close(peeker);
    
    SDL_DestroyMutex(peeker->mutex);
    
    av_freep(peeker_out);
}

int mr_stream_peek_get_buffer_size(int millisecond)
{
    return bytes_per_millisecond() * millisecond;
}

int mr_stream_duration(MRStreamPeeker *peeker)
{
    if (peeker) {
        return peeker->duration;
    }
    return 0;
}
