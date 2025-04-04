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
#include "libavformat/url.h"
#include "libavformat/version.h"

#define FS_REGISTER_DEMUXER(x)                                         \
    {                                                                   \
        extern AVInputFormat ijkff_##x##_demuxer;                       \
        ijkav_register_input_format(&ijkff_##x##_demuxer);              \
    }

#define FS_REGISTER_PROTOCOL(x)                                        \
    {                                                                   \
        extern URLProtocol ijkimp_ff_##x##_protocol;                        \
        int ijkav_register_##x##_protocol(URLProtocol *protocol, int protocol_size);\
        ijkav_register_##x##_protocol(&ijkimp_ff_##x##_protocol, sizeof(URLProtocol));  \
    }

static const AVInputFormat *ijkav_find_input_format(const char *iformat_name)
{
    const AVInputFormat *fmt = NULL;
    if (!iformat_name)
        return NULL;
    void *opaque = NULL;
    
    while ((fmt = av_demuxer_iterate(&opaque))) {
        if (!fmt->name)
            continue;
        if (!strcmp(iformat_name, fmt->name))
            return fmt;
    }
    return NULL;
}

static void ijkav_register_input_format(AVInputFormat *iformat)
{
    if (ijkav_find_input_format(iformat->name)) {
        av_log(NULL, AV_LOG_WARNING, "skip     demuxer : %s (duplicated)\n", iformat->name);
    } else {
        av_log(NULL, AV_LOG_INFO,    "register demuxer : %s\n", iformat->name);
        //av_register_input_format(iformat);
    }
}


void ijkav_register_all(void)
{
    static int initialized;

    if (initialized)
        return;
    initialized = 1;

    /* protocols */
    av_log(NULL, AV_LOG_INFO, "===== custom modules begin =====\n");
#ifdef __ANDROID__
    FS_REGISTER_PROTOCOL(ijkmediadatasource);
#endif

    FS_REGISTER_PROTOCOL(ijkio);
    FS_REGISTER_PROTOCOL(async);
    FS_REGISTER_PROTOCOL(ijktcphook);
    FS_REGISTER_PROTOCOL(ijkhttphook);
    FS_REGISTER_PROTOCOL(ijksegment);
    /* demuxers */
    FS_REGISTER_DEMUXER(ijklivehook);
    av_log(NULL, AV_LOG_INFO, "===== custom modules end =====\n");
}
