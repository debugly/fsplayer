/*
 * ff_ffpipenode.h
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

#ifndef FFPLAY__FF_FFPIPENODE_H
#define FFPLAY__FF_FFPIPENODE_H

#include "ijksdl/ijksdl_mutex.h"

typedef struct FSFF_Pipenode_Opaque FSFF_Pipenode_Opaque;
typedef struct FSFF_Pipenode FSFF_Pipenode;
struct FSFF_Pipenode {
    SDL_mutex *mutex;
    void *opaque;
    int vdec_type;
    void (*func_destroy) (FSFF_Pipenode *node);
    int  (*func_run_sync)(FSFF_Pipenode *node);
    int  (*func_flush)   (FSFF_Pipenode *node); // optional
};

FSFF_Pipenode *ffpipenode_alloc(size_t opaque_size);
void ffpipenode_free(FSFF_Pipenode *node);
void ffpipenode_free_p(FSFF_Pipenode **node);

int  ffpipenode_run_sync(FSFF_Pipenode *node);
int  ffpipenode_flush(FSFF_Pipenode *node);

#endif
