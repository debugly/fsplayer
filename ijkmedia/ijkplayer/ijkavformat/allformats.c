/*
 * Copyright (c) 2003 Bilibili
 * Copyright (c) 2003 Fabrice Bellard
 * Copyright (c) 2015 Zhang Rui <bbcallen@gmail.com>
 * Copyright (c) 2019 debugly <qianlongxu@gmail.com>
 *
 * This file is part of FSPlayer.
 * Based on libavformat/allformats.c
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include "libavformat/avformat.h"
#include "libavformat/demux.h"
#include "libavformat/url.h"
#include "libavformat/version.h"
#include "../ff_version.h"

#if IS_LESS_THAN_FFMPEG_7
#define FFInputFormat AVInputFormat
#endif

#define FS_REGISTER_DEMUXER(x)                                         \
    {                                                                   \
        extern FFInputFormat ijkff_##x##_demuxer;                       \
        int ijkav_register_##x##_demuxer(FFInputFormat *demuxer, int demuxer_size); \
        ijkav_register_##x##_demuxer(&ijkff_##x##_demuxer, sizeof(FFInputFormat)); \
    }

#define FS_REGISTER_PROTOCOL(x)                                        \
    {                                                                   \
        extern URLProtocol ijkimp_ff_##x##_protocol;                        \
        int ijkav_register_##x##_protocol(URLProtocol *protocol, int protocol_size);\
        ijkav_register_##x##_protocol(&ijkimp_ff_##x##_protocol, sizeof(URLProtocol));  \
    }

av_unused static void print_all_muxers(void)
{
    printf("---all muxers------------------------\n");
    void *iter = NULL;
    const AVOutputFormat *out_fmt;
    int i = 0;
    while ((out_fmt = av_muxer_iterate(&iter))) {
        i++;
        printf("%s(%s)\n",out_fmt->name,out_fmt->extensions);
    }
    printf("---all muxers:%d\n",i);
}

av_unused static void print_all_demuxers(void)
{
    printf("---all demuxers------------------------\n");
    void *iter = NULL;
    const AVInputFormat *in_fmt;
    int i = 0;
    while ((in_fmt = av_demuxer_iterate(&iter))) {
        i++;
        printf("%s(%s)\n",in_fmt->name,in_fmt->extensions);
    }
    printf("---all demuxers:%d\n",i);
}

av_unused static int print_all_protocols(int in_out)
{
    char *pup = NULL;
    void **a_pup = (void **)&pup;
    int i = 0;
    while (1) {
        const char *p = avio_enum_protocols(a_pup, in_out);
        if (p != NULL) {
            i++;
            printf("%s ",p);
        } else {
            break;
        }
    }
    pup = NULL;
    printf("\n");
    return i;
}

av_unused static void print_all_output_protocols(void)
{
    printf("---all output protocols------------------------\n");
    int sum = print_all_protocols(1);
    printf("---all output protocols:%d\n", sum);
}

av_unused static void print_all_input_protocols(void)
{
    printf("---all input protocols------------------------\n");
    int sum = print_all_protocols(0);
    printf("---all input protocols:%d\n", sum);
}

av_unused static int print_all_codes(int en_de)
{
    void *iterate_data = NULL;
    const AVCodec *codec = NULL;
    int i = 0;
    while (NULL != (codec = av_codec_iterate(&iterate_data))) {
        
        const char *type;
        
        if (codec->type == AVMEDIA_TYPE_VIDEO) {
            type = "video";
        } else if (codec->type == AVMEDIA_TYPE_AUDIO) {
            type = "audio";
        } else if (codec->type == AVMEDIA_TYPE_SUBTITLE) {
            type = "subtile";
        } else if (codec->type == AVMEDIA_TYPE_DATA) {
            type = "data";
        } else if (codec->type == AVMEDIA_TYPE_ATTACHMENT) {
            type = "attach";
        } else {
            type = "unknown";
        }
        if (en_de) {
            if (av_codec_is_encoder(codec)) {
                i++;
                printf("%6d %8s %s\n",codec->id, type, codec->name);
            }
        } else {
            if (av_codec_is_decoder(codec)) {
                i++;
                printf("%6d %8s %s\n",codec->id, type, codec->name);
            }
        }
    }
    return i;
}

av_unused static void print_all_encodes(void)
{
    printf("---all encoders ------------------------\n");
    int sum = print_all_codes(1);
    printf("---all encoders:%d\n", sum);
}

av_unused static void print_all_decodes(void)
{
    printf("---all decoders ------------------------\n");
    int sum = print_all_codes(0);
    printf("---all decoders:%d\n", sum);
}

void ijkav_register_all(void)
{
    static int initialized;

    if (initialized)
        return;
    initialized = 1;

//    print_all_muxers();
//    print_all_demuxers();
//    print_all_output_protocols();
//    print_all_input_protocols();
//    print_all_encodes();
//    print_all_decodes();
    
    /* protocols */
    av_log(NULL, AV_LOG_INFO, "===== custom modules begin =====\n");
#ifdef __ANDROID__
    FS_REGISTER_PROTOCOL(ijkmediadatasource);
#endif
    FS_REGISTER_PROTOCOL(ijkio);
    FS_REGISTER_PROTOCOL(ijktcphook);
    FS_REGISTER_PROTOCOL(ijkhttphook);
    FS_REGISTER_PROTOCOL(ijksegment);
    /* demuxers */
    FS_REGISTER_DEMUXER(ijklivehook);
    av_log(NULL, AV_LOG_INFO, "===== custom modules end =====\n");
}
