/*
* ff_recorder_frame_queue.h
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


#ifndef ff_recorder_frame_queue_h
#define ff_recorder_frame_queue_h

#include <stdio.h>

/**
 * RFrameQueue
 */
typedef struct RFrameQueue RFrameQueue;
typedef struct AVFrame AVFrame;
/**
 * 创建RFrameQueue队列
 * @param capacity 队列容量（最多存储的帧数）
 * @return 成功返回队列指针，失败返回NULL
 */
RFrameQueue* rframe_queue_create(int capacity);

/**
 * 销毁RFrameQueue队列，释放所有资源
 * @param queue 队列指针
 */
void rframe_queue_destroy(RFrameQueue *queue);

/**
 * 向队列中添加帧（非阻塞）
 * @param queue 队列指针
 * @param frame 要添加的AVFrame（队列仅保存指针，不复制数据）
 * @return 成功返回0，队列已满或已关闭返回-1
 */
int rframe_queue_put(RFrameQueue *queue, AVFrame *frame);

/**
 * 从队列中获取帧（非阻塞）
 * @param queue 队列指针
 * @return 成功返回AVFrame指针，队列为空或已关闭返回NULL
 */
AVFrame* rframe_queue_get(RFrameQueue *queue);

/**
 * 关闭队列（标记为已关闭，不再接受新数据）
 * @param queue 队列指针
 */
void rframe_queue_close(RFrameQueue *queue);

/**
 * 获取队列当前大小（已存储的帧数）
 * @param queue 队列指针
 * @return 队列大小，失败返回0
 */
int rframe_queue_size(RFrameQueue *queue);

/**
 * 判断队列是否为空
 * @param queue 队列指针
 * @return 为空返回1，否则返回0
 */
int rframe_queue_empty(RFrameQueue *queue);

/**
 * 判断队列是否已满
 * @param queue 队列指针
 * @return 已满返回1，否则返回0
 */
int rframe_queue_full(RFrameQueue *queue);

#endif /* ff_recorder_frame_queue_h */
