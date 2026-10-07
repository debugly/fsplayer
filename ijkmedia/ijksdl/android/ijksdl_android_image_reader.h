/*****************************************************************************
 * ijksdl_android_image_reader.h
 *****************************************************************************
 *
 * Copyright (c) 2026 debugly <qianlongxu@gmail.com>
 *
 * This file is part of FSPlayer.
 *
 * FSPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
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

/*
 * AImageReader 封装：把 MediaCodec 解码输出的硬件 buffer 以零拷贝方式交给
 * 渲染器（Vulkan external memory / EGLImage）。
 *
 * AImageReader_newWithUsage / AImage_getHardwareBuffer 等符号是 API 26 才有的，
 * 而 FSPlayer minSdk 为 24，因此这里统一用 dlopen("libmediandk.so") + dlsym
 * 延迟解析；API 24/25 设备上 isAvailable() 返回 false，调用方应回退软解。
 */

#ifndef IJKSDL_ANDROID__IJKSDL_ANDROID_IMAGE_READER_H
#define IJKSDL_ANDROID__IJKSDL_ANDROID_IMAGE_READER_H

#include <stdbool.h>
#include <jni.h>

typedef struct SDL_AndroidImageReader SDL_AndroidImageReader;

/* libmediandk 是否可用且符号齐全（API 26+）。 */
bool SDL_AndroidImageReader_isAvailable(void);

/*
 * 创建 AImageReader。
 * 只承载硬件 buffer，尺寸参数无关紧要（内部固定 16x16）。
 * max_images 为同时可 acquire 的上限（建议 3）。
 */
SDL_AndroidImageReader *SDL_AndroidImageReader_create(int max_images);

/*
 * 取 reader 的输出 Surface（返回 NewLocalRef，调用方负责 DeleteLocalRef）。
 * 该 Surface 交给 MediaCodec 作为输出目标。
 */
jobject SDL_AndroidImageReader_getSurface(JNIEnv *env, SDL_AndroidImageReader *r);

/*
 * 等待并取回最新一帧的 AHardwareBuffer。
 * 成功返回 0，*out_hwbuf 为 AHardwareBuffer*，尺寸写入 *out_w / *out_h；
 * 返回的 buffer 由本对象持有，直到下一次 acquire 或 releaseImage。
 * timeout_ms 为等待首帧的最长时间。
 */
int SDL_AndroidImageReader_acquireLatest(SDL_AndroidImageReader *r, void **out_hwbuf,
                                         int *out_w, int *out_h, int timeout_ms);

/* 释放最近一次 acquire 到的 image。 */
void SDL_AndroidImageReader_releaseImage(SDL_AndroidImageReader *r);

void SDL_AndroidImageReader_destroy(SDL_AndroidImageReader *r);

#endif
