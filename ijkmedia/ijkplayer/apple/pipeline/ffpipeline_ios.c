/*
 * ffpipeline_ios.c
 *
 * Copyright (c) 2014 Zhou Quan <zhouqicy@gmail.com>
 * Copyright (c) 2019 debugly <qianlongxu@gmail.com>
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
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include "ffpipeline_ios.h"
#include "ffpipenode_ffplay_vdec.h"
#include "ff_ffplay.h"
#import "ijksdl/apple/ijksdl_aout_ios_audiounit.h"

struct FS_Pipeline_Opaque {
    FFPlayer    *ffp;
};

static void func_destroy(FS_Pipeline *pipeline)
{
    
}

static FS_Pipenode *func_open_video_decoder(FS_Pipeline *pipeline, FFPlayer *ffp)
{
    return ffpipenode_create_video_decoder_from_ffplay(ffp);
}

static SDL_Aout *func_open_audio_output(FS_Pipeline *pipeline, FFPlayer *ffp)
{
    return SDL_AoutIos_CreateForAudioUnit();
}

static SDL_Class g_pipeline_class = {
    .name = "ffpipeline_ios",
};

FS_Pipeline *ffpipeline_create_from_ios(FFPlayer *ffp)
{
    FS_Pipeline *pipeline = ffpipeline_alloc(&g_pipeline_class, sizeof(FS_Pipeline_Opaque));
    if (!pipeline)
        return pipeline;

    FS_Pipeline_Opaque *opaque             = pipeline->opaque;
    opaque->ffp                               = ffp;
    pipeline->func_destroy                    = func_destroy;
    pipeline->func_open_video_decoder         = func_open_video_decoder;
    pipeline->func_open_audio_output          = func_open_audio_output;
    
    return pipeline;
}
