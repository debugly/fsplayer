/*
 * ff_ffpipenode.h
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
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#ifndef FFPLAY__FF_FFPIPENODE_H
#define FFPLAY__FF_FFPIPENODE_H

#include "ijksdl/ijksdl_mutex.h"

typedef struct FS_Pipenode_Opaque FS_Pipenode_Opaque;
typedef struct FS_Pipenode FS_Pipenode;
struct FS_Pipenode {
    SDL_mutex *mutex;
    void *opaque;
    int vdec_type;
    void (*func_destroy) (FS_Pipenode *node);
    int  (*func_run_sync)(FS_Pipenode *node);
    int  (*func_flush)   (FS_Pipenode *node); // optional
};

FS_Pipenode *ffpipenode_alloc(size_t opaque_size);
void ffpipenode_free(FS_Pipenode *node);
void ffpipenode_free_p(FS_Pipenode **node);

int  ffpipenode_run_sync(FS_Pipenode *node);
int  ffpipenode_flush(FS_Pipenode *node);

#endif
