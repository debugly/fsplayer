/*
 *  ff_frame_queue.h
 *
 * Copyright (c) 2022 debugly <qianlongxu@gmail.com>
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

#ifndef ff_frame_queue_h
#define ff_frame_queue_h

#include "ff_ffplay_def.h"

void frame_queue_unref_item(Frame *vp);
int frame_queue_init(FrameQueue *f, PacketQueue *pktq, int max_size, int keep_last);
void frame_queue_destroy(FrameQueue *f);
void frame_queue_signal(FrameQueue *f);
Frame *frame_queue_peek(FrameQueue *f);
Frame *frame_queue_peek_next(FrameQueue *f);
Frame *frame_queue_peek_offset(FrameQueue *f, int offset);
Frame *frame_queue_peek_last(FrameQueue *f);
Frame *frame_queue_peek_pre_writable(FrameQueue *f);
Frame *frame_queue_peek_writable(FrameQueue *f);
Frame *frame_queue_peek_writable_noblock(FrameQueue *f);
// wait until we have a readable a new frame
Frame *frame_queue_peek_readable(FrameQueue *f);
//return a readable frame or NULL, not wait
Frame *frame_queue_peek_readable_noblock(FrameQueue *f);
int frame_queue_push(FrameQueue *f);
int frame_queue_nb_remaining(FrameQueue *f);
int frame_queue_is_full(FrameQueue *f);
void frame_queue_next(FrameQueue *f);
/* return last shown position */
int64_t frame_queue_last_pos(FrameQueue *f);
#endif /* ff_frame_queue_h */
