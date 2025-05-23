/*
* ff_recorder_frame_queue.c
*
* Copyright (c) 2025 debugly <qianlongxu@gmail.com>
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

#include "ff_recorder_frame_queue.h"
#include <stdlib.h>
#include <pthread.h>
#include <libavutil/frame.h>

typedef struct RFrameQueue {
    AVFrame **frames;
    int capacity;
    int size;
    int head;
    int tail;
    pthread_mutex_t lock;
    int closed;
} RFrameQueue;

// 创建帧队列
RFrameQueue* rframe_queue_create(int capacity) {
    RFrameQueue *queue = (RFrameQueue*)malloc(sizeof(RFrameQueue));
    if (!queue) return NULL;
    
    queue->frames = (AVFrame**)calloc(capacity, sizeof(AVFrame*));
    if (!queue->frames) {
        free(queue);
        return NULL;
    }
    
    queue->capacity = capacity;
    queue->size = 0;
    queue->head = 0;
    queue->tail = 0;
    queue->closed = 0;
    
    pthread_mutex_init(&queue->lock, NULL);
    
    return queue;
}

// 销毁帧队列
void rframe_queue_destroy(RFrameQueue *queue) {
    if (!queue) return;
    
    pthread_mutex_lock(&queue->lock);
    
    // 释放队列中剩余的AVFrame
    for (int i = 0; i < queue->size; i++) {
        int idx = (queue->head + i) % queue->capacity;
        if (queue->frames[idx]) {
            av_frame_free(&queue->frames[idx]);
        }
    }
    
    pthread_mutex_unlock(&queue->lock);
    
    // 销毁互斥锁
    pthread_mutex_destroy(&queue->lock);
    
    free(queue->frames);
    free(queue);
}

// 向队列中添加帧（非阻塞，队列满时返回-1）
int rframe_queue_put(RFrameQueue *queue, AVFrame *frame) {
    if (!queue || !frame) return -1;
    
    pthread_mutex_lock(&queue->lock);
    
    // 检查队列是否已满或已关闭
    if (queue->size >= queue->capacity || queue->closed) {
        pthread_mutex_unlock(&queue->lock);
        return -1;
    }
    
    // 将帧添加到队列
    queue->frames[queue->tail] = frame;
    queue->tail = (queue->tail + 1) % queue->capacity;
    queue->size++;
    
    pthread_mutex_unlock(&queue->lock);
    return 0;
}

// 从队列中获取帧（非阻塞，队列为空时返回NULL）
AVFrame* rframe_queue_get(RFrameQueue *queue) {
    if (!queue) return NULL;
    
    pthread_mutex_lock(&queue->lock);
    
    // 检查队列是否为空或已关闭
    if (queue->size <= 0 || queue->closed) {
        pthread_mutex_unlock(&queue->lock);
        return NULL;
    }
    
    // 从队列中取出帧
    AVFrame *frame = queue->frames[queue->head];
    queue->head = (queue->head + 1) % queue->capacity;
    queue->size--;
    
    pthread_mutex_unlock(&queue->lock);
    return frame;
}

// 关闭队列
void rframe_queue_close(RFrameQueue *queue) {
    if (!queue) return;
    
    pthread_mutex_lock(&queue->lock);
    
    // 设置关闭标志
    queue->closed = 1;
    
    pthread_mutex_unlock(&queue->lock);
}

// 获取队列当前大小
int rframe_queue_size(RFrameQueue *queue) {
    if (!queue) return 0;
    
    pthread_mutex_lock(&queue->lock);
    int size = queue->size;
    pthread_mutex_unlock(&queue->lock);
    
    return size;
}

// 判断队列是否为空
int rframe_queue_empty(RFrameQueue *queue) {
    return rframe_queue_size(queue) == 0;
}

// 判断队列是否已满
int rframe_queue_full(RFrameQueue *queue) {
    if (!queue) return 0;
    
    pthread_mutex_lock(&queue->lock);
    int full = (queue->size >= queue->capacity);
    pthread_mutex_unlock(&queue->lock);
    
    return full;
}
