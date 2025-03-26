/*
 *  ff_frame_queue.c
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
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include "ff_frame_queue.h"

void frame_queue_unref_item(Frame *vp)
{
    av_frame_unref(vp->frame);
    SDL_VoutUnrefYUVOverlay(vp->bmp);
    
    int count = 0;
    while (count < SUB_REF_MAX_LEN) {
        FFSubtitleBuffer *h = vp->sub_list[count];
        if (!h) {
            break;
        }
        ff_subtitle_buffer_release(&h);
        count++;
    }
    bzero(vp->sub_list, sizeof(vp->sub_list));
}

int frame_queue_init(FrameQueue *f, PacketQueue *pktq, int max_size, int keep_last)
{
    int i;
    memset(f, 0, sizeof(FrameQueue));
    if (!(f->mutex = SDL_CreateMutex())) {
        av_log(NULL, AV_LOG_FATAL, "SDL_CreateMutex(): %s\n", SDL_GetError());
        return AVERROR(ENOMEM);
    }
    if (!(f->cond = SDL_CreateCond())) {
        av_log(NULL, AV_LOG_FATAL, "SDL_CreateCond(): %s\n", SDL_GetError());
        return AVERROR(ENOMEM);
    }
    f->pktq = pktq;
    f->max_size = FFMIN(max_size, FRAME_QUEUE_SIZE);
    f->keep_last = !!keep_last;
    for (i = 0; i < f->max_size; i++)
        if (!(f->queue[i].frame = av_frame_alloc()))
            return AVERROR(ENOMEM);
    return 0;
}

void frame_queue_destory(FrameQueue *f)
{
    int i;
    for (i = 0; i < f->max_size; i++) {
        Frame *vp = &f->queue[i];
        frame_queue_unref_item(vp);
        av_frame_free(&vp->frame);
        if (vp->bmp) {
            SDL_VoutFreeYUVOverlay(vp->bmp);
            vp->bmp = NULL;
        }
    }
    f->duration = 0;
    SDL_DestroyMutex(f->mutex);
    SDL_DestroyCond(f->cond);
}

void frame_queue_signal(FrameQueue *f)
{
    SDL_LockMutex(f->mutex);
    SDL_CondSignal(f->cond);
    SDL_UnlockMutex(f->mutex);
}

Frame *frame_queue_peek(FrameQueue *f)
{
    return &f->queue[(f->rindex + f->rindex_shown) % f->max_size];
}

Frame *frame_queue_peek_next(FrameQueue *f)
{
    return &f->queue[(f->rindex + f->rindex_shown + 1) % f->max_size];
}

Frame *frame_queue_peek_offset(FrameQueue *f, int offset)
{
    if (offset >= f->size) {
        return NULL;
    }
    return &f->queue[(f->rindex + f->rindex_shown + offset) % f->max_size];
}

Frame *frame_queue_peek_last(FrameQueue *f)
{
    return &f->queue[f->rindex];
}

Frame *frame_queue_peek_writable(FrameQueue *f)
{
    /* wait until we have space to put a new frame */
    SDL_LockMutex(f->mutex);
    while (f->size >= f->max_size &&
           !f->pktq->abort_request) {
        SDL_CondWait(f->cond, f->mutex);
    }
    SDL_UnlockMutex(f->mutex);

    if (f->pktq->abort_request)
        return NULL;

    return &f->queue[f->windex];
}

Frame *frame_queue_peek_writable_noblock(FrameQueue *f)
{
    SDL_LockMutex(f->mutex);
    if (f->size >= f->max_size || f->pktq->abort_request) {
        SDL_UnlockMutex(f->mutex);
        return NULL;
    }
    SDL_UnlockMutex(f->mutex);

    return &f->queue[f->windex];
}

Frame *frame_queue_peek_pre_writable(FrameQueue *f)
{
    if (f->pktq->abort_request)
        return NULL;
    
    SDL_LockMutex(f->mutex);
    if (f->size < 1) {
        SDL_UnlockMutex(f->mutex);
        return NULL;
    }
    int idx = f->windex - 1;
    if (idx < 0) {
        idx = f->max_size - 1;
    }
    SDL_UnlockMutex(f->mutex);
    return &f->queue[idx];
}

Frame *frame_queue_peek_readable(FrameQueue *f)
{
    SDL_LockMutex(f->mutex);
    while (f->size - f->rindex_shown <= 0 &&
           !f->pktq->abort_request) {
        SDL_CondWait(f->cond, f->mutex);
    }
    SDL_UnlockMutex(f->mutex);

    if (f->pktq->abort_request)
        return NULL;

    return &f->queue[(f->rindex + f->rindex_shown) % f->max_size];
}

Frame *frame_queue_peek_readable_noblock(FrameQueue *f)
{
    SDL_LockMutex(f->mutex);
    if (f->size - f->rindex_shown <= 0 &&
           !f->pktq->abort_request) {
        SDL_UnlockMutex(f->mutex);
        return NULL;
    }
    SDL_UnlockMutex(f->mutex);

    if (f->pktq->abort_request)
        return NULL;

    return &f->queue[(f->rindex + f->rindex_shown) % f->max_size];
}

int frame_queue_push(FrameQueue *f)
{
    Frame *frame = &f->queue[f->windex];
    double du = frame->duration;
    
    if (++f->windex == f->max_size)
        f->windex = 0;
    int size;
    SDL_LockMutex(f->mutex);
    f->duration += du;
    size = ++f->size;
    SDL_CondSignal(f->cond);
    SDL_UnlockMutex(f->mutex);
    return size;
}

void frame_queue_next(FrameQueue *f)
{
    if (f->keep_last && !f->rindex_shown) {
        f->rindex_shown = 1;
        return;
    }
    
    Frame *frame = &f->queue[f->rindex];
    double du = frame->duration;
    frame_queue_unref_item(frame);
    if (++f->rindex == f->max_size)
        f->rindex = 0;
    SDL_LockMutex(f->mutex);
    f->size--;
    f->duration -= du;
    SDL_CondSignal(f->cond);
    SDL_UnlockMutex(f->mutex);
}

/* return the number of undisplayed frames in the queue */
int frame_queue_nb_remaining(FrameQueue *f)
{
    return f->size - f->rindex_shown;
}

int frame_queue_is_full(FrameQueue *f)
{
    return frame_queue_nb_remaining(f) >= f->max_size;
}

/* return last shown position */
#ifdef FFP_MERGE
static int64_t frame_queue_last_pos(FrameQueue *f)
{
    Frame *fp = &f->queue[f->rindex];
    if (f->rindex_shown && fp->serial == f->pktq->serial)
        return fp->pos;
    else
        return -1;
}
#endif
