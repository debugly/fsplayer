/*
 * ff_ass_renderer.h
 *
 * Copyright (c) 2024 debugly <qianlongxu@gmail.com>
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

#ifndef ff_ass_steam_renderer_h
#define ff_ass_steam_renderer_h

#include <ass/ass.h>
#include <libavutil/log.h>
#include <libavutil/opt.h>

typedef struct FF_ASS_Renderer FF_ASS_Renderer;
typedef struct AVStream AVStream;
typedef struct FFSubtitleBuffer FFSubtitleBuffer;

typedef struct FF_ASS_Renderer_Format {
    const AVClass *priv_class;
    int priv_data_size;
    int (*init)(FF_ASS_Renderer *);
    int (*set_subtitle_header)(FF_ASS_Renderer *s, uint8_t *subtitle_header, int subtitle_header_size);
    void (*set_attach_font)(FF_ASS_Renderer *s, AVStream *st);
    void (*set_video_size)(FF_ASS_Renderer *s, int w, int h);
    void (*process_chunk)(FF_ASS_Renderer *s, char *ass_line, int64_t start, int64_t duration);
    void (*flush_events)(FF_ASS_Renderer *s);
    int  (*upload_buffer)(FF_ASS_Renderer *, double time_ms, FFSubtitleBuffer **buffer, int ignore_change);
    int  (*get_PlayResY)(FF_ASS_Renderer *s);
    void (*set_font_scale)(FF_ASS_Renderer *, double scale);
    void (*set_force_style)(FF_ASS_Renderer *s, char * style, int bits);
    void (*uninit)(FF_ASS_Renderer *);
} FF_ASS_Renderer_Format;

typedef struct FF_ASS_Renderer {
    void *priv_data;
    const FF_ASS_Renderer_Format *iformat;
    int refCount;
} FF_ASS_Renderer;

FF_ASS_Renderer *ff_ass_render_create_default(uint8_t *subtitle_header, int subtitle_header_size, int video_w, int video_h, AVDictionary **opts);

FF_ASS_Renderer * ff_ass_render_retain(FF_ASS_Renderer *ar);
void ff_ass_render_release(FF_ASS_Renderer **arp);

int ff_ass_upload_buffer(FF_ASS_Renderer * assRenderer, float begin, FFSubtitleBuffer **buffer, int ignore_change);
void ff_ass_process_chunk(FF_ASS_Renderer * assRenderer, const char *ass_line, float begin, float end);
void ff_ass_flush_events(FF_ASS_Renderer * assRenderer);

#endif /* ff_ass_steam_renderer_h */
