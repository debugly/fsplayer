/*
 * ff_ffpipeline.h
 *
 * Copyright (c) 2014 Bilibili
 * Copyright (c) 2014 Zhang Rui <bbcallen@gmail.com>
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
 * License along with FSPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#ifndef FFPLAY__FF_FFPIPELINE_H
#define FFPLAY__FF_FFPIPELINE_H

#include "ijksdl/ijksdl_class.h"
#include "ijksdl/ijksdl_mutex.h"
#include "ijksdl/ijksdl_aout.h"
#include "ff_ffpipenode.h"
#include "ff_ffplay_def.h"

typedef struct FS_Pipeline_Opaque FS_Pipeline_Opaque;
typedef struct FS_Pipeline FS_Pipeline;
struct FS_Pipeline {
    SDL_Class             *opaque_class;
    FS_Pipeline_Opaque *opaque;

    void            (*func_destroy)                   (FS_Pipeline *pipeline);
    FS_Pipenode *(*func_open_video_decoder)        (FS_Pipeline *pipeline, FFPlayer *ffp);
    SDL_Aout       *(*func_open_audio_output)         (FS_Pipeline *pipeline, FFPlayer *ffp);
    FS_Pipenode *(*func_init_video_decoder)        (FS_Pipeline *pipeline, FFPlayer *ffp);
    int           (*func_config_video_decoder)        (FS_Pipeline *pipeline, FFPlayer *ffp);
};

FS_Pipeline *ffpipeline_alloc(SDL_Class *opaque_class, size_t opaque_size);
void ffpipeline_free(FS_Pipeline *pipeline);
void ffpipeline_free_p(FS_Pipeline **pipeline);

FS_Pipenode *ffpipeline_open_video_decoder(FS_Pipeline *pipeline, FFPlayer *ffp);
SDL_Aout       *ffpipeline_open_audio_output(FS_Pipeline *pipeline, FFPlayer *ffp);

FS_Pipenode* ffpipeline_init_video_decoder(FS_Pipeline *pipeline, FFPlayer *ffp);
int ffpipeline_config_video_decoder(FS_Pipeline *pipeline, FFPlayer *ffp);
//return value greater than zero means has other decoder.
int ffpipeline_has_another_video_decoder(FS_Pipeline *pipeline, FFPlayer *ffp);
//create other video decoder pipenode.
FS_Pipenode* ffpipeline_open_another_video_decoder(FS_Pipeline *pipeline, FFPlayer *ffp);

#endif
