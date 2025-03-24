/*
 * ff_ffpipeline.c
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

#include "ff_ffpipeline.h"
#include <stdlib.h>
#include <string.h>

FSFF_Pipeline *ffpipeline_alloc(SDL_Class *opaque_class, size_t opaque_size)
{
    FSFF_Pipeline *pipeline = (FSFF_Pipeline*) calloc(1, sizeof(FSFF_Pipeline));
    if (!pipeline)
        return NULL;

    pipeline->opaque_class = opaque_class;
    pipeline->opaque       = calloc(1, opaque_size);
    if (!pipeline->opaque) {
        free(pipeline);
        return NULL;
    }

    return pipeline;
}

void ffpipeline_free(FSFF_Pipeline *pipeline)
{
    if (!pipeline)
        return;

    if (pipeline->func_destroy) {
        pipeline->func_destroy(pipeline);
    }

    free(pipeline->opaque);
    memset(pipeline, 0, sizeof(FSFF_Pipeline));
    free(pipeline);
}

void ffpipeline_free_p(FSFF_Pipeline **pipeline)
{
    if (!pipeline)
        return;

    ffpipeline_free(*pipeline);
}

FSFF_Pipenode* ffpipeline_open_video_decoder(FSFF_Pipeline *pipeline, FFPlayer *ffp)
{
    return pipeline->func_open_video_decoder(pipeline, ffp);
}

FSFF_Pipenode* ffpipeline_init_video_decoder(FSFF_Pipeline *pipeline, FFPlayer *ffp)
{
    return pipeline->func_init_video_decoder(pipeline, ffp);
}

int ffpipeline_config_video_decoder(FSFF_Pipeline *pipeline, FFPlayer *ffp)
{
    return pipeline->func_config_video_decoder(pipeline, ffp);
}

SDL_Aout *ffpipeline_open_audio_output(FSFF_Pipeline *pipeline, FFPlayer *ffp)
{
    return pipeline->func_open_audio_output(pipeline, ffp);
}
