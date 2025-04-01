/*
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
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

/**
 * @file
 * unbuffered private I/O API
 */

#ifndef FSAVFORMAT_IJKIOURL_H
#define FSAVFORMAT_IJKIOURL_H

#include <stdint.h>
#include "ijkplayer/ijkavutil/ijkdict.h"
#include "ijkioapplication.h"

struct IjkURLProtocol;

#define FSURL_PAUSED  0x10
#define FSURL_STARTED 0x20

typedef struct IjkURLContext {
    const struct IjkURLProtocol *prot;
    IjkIOApplicationContext *ijkio_app_ctx;
    int state;
    void *priv_data;
} IjkURLContext;

typedef struct IjkURLProtocol {
    const char *name;
    int     (*url_open2)(IjkURLContext *h, const char *url, int flags, IjkAVDictionary **options);
    int     (*url_read)( IjkURLContext *h, unsigned char *buf, int size);
    int64_t (*url_seek)( IjkURLContext *h, int64_t pos, int whence);
    int     (*url_close)(IjkURLContext *h);
    int     (*url_pause)(IjkURLContext *h);  // option
    int     (*url_resume)(IjkURLContext *h);  // option
    int priv_data_size;
    int flags;
} IjkURLProtocol;

#endif  // FSAVFORMAT_IJKIOURL_H
