/*
 * ffpipenode_ffplay_vdec.c
 *
 * Copyright (c) 2014 Bilibili
 * Copyright (c) 2014 Zhang Rui <bbcallen@gmail.com>
 *
 * This file is part of ijkPlayer.
 *
 * ijkPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * ijkPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include "ffpipenode_ffplay_vdec.h"
#include "../ff_ffpipenode.h"
#include "../ff_ffplay.h"

struct FS_Pipenode_Opaque {
    FFPlayer *ffp;
};

static void func_destroy(FS_Pipenode *node)
{
    // do nothing
}

static int func_run_sync(FS_Pipenode *node)
{
    FS_Pipenode_Opaque *opaque = node->opaque;

    return ffp_video_thread(opaque->ffp);
}

FS_Pipenode *ffpipenode_create_video_decoder_from_ffplay(FFPlayer *ffp)
{
    FS_Pipenode *node = ffpipenode_alloc(sizeof(FS_Pipenode_Opaque));
    if (!node)
        return node;

    FS_Pipenode_Opaque *opaque = node->opaque;
    opaque->ffp         = ffp;

    node->func_destroy  = func_destroy;
    node->func_run_sync = func_run_sync;

    ffp_set_video_codec_info(ffp, AVCODEC_MODULE_NAME, avcodec_get_name(ffp->is->viddec.avctx->codec_id));
    //maybe hw is not support the video format.
    //node->vdec_type = ffp->is->viddec.avctx->hw_device_ctx ? FFP_PROPV_DECODER_AVCODEC_HW : FFP_PROPV_DECODER_AVCODEC;
    return node;
}
