/*****************************************************************************
 * fs_vulkan_renderer.h
 *****************************************************************************
 *
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

#ifndef IJKSDL_ANDROID_VULKAN__FS_VULKAN_RENDERER_H
#define IJKSDL_ANDROID_VULKAN__FS_VULKAN_RENDERER_H

#include <jni.h>
#include "libavutil/frame.h"

typedef struct ANativeWindow ANativeWindow;
typedef struct FSVulkanRenderer FSVulkanRenderer;
struct SDL_TextureOverlay;
struct FSVulkanContext;

/*
 * 创建 Vulkan 渲染器（只创建 instance/device，不创建 swapchain）。
 * surface 稍后通过 fs_vulkan_renderer_set_surface 传入。
 */
FSVulkanRenderer *fs_vulkan_renderer_create(void);

/* 设置/更新渲染目标窗口；首次设置时创建 swapchain 与渲染资源。 */
int fs_vulkan_renderer_set_surface(FSVulkanRenderer *r, ANativeWindow *window);

/*
 * 渲染一帧 YUV 画面。
 * frame 为解码帧（YUV420P 或 NV12，其它格式内部先转 YUV420P）。
 * disp_w/disp_h 为显示宽高（含 SAR 校正后的比例），rotate_degrees 为旋转角（0/90/180/270）。
 */
int fs_vulkan_renderer_display(FSVulkanRenderer *r, const AVFrame *frame,
                               int disp_w, int disp_h,
                               int rotate_degrees, int sar_num, int sar_den);

/*
 * MediaCodec 硬解零拷贝：
 * 渲染器内部持有 AImageReader，把它的输出 Surface 交给解码器；
 * 非 0 表示设备支持该通路（Vulkan 1.1 + VK_ANDROID_external_memory_...）。
 */
int fs_vulkan_renderer_is_mediacodec_supported(FSVulkanRenderer *r);

/* 返回 AImageReader 的输出 Surface（NewLocalRef，调用方 DeleteLocalRef）。 */
jobject fs_vulkan_renderer_get_mediacodec_surface(JNIEnv *env, FSVulkanRenderer *r);

void fs_vulkan_renderer_destroy(FSVulkanRenderer *r);

/* 只有字幕、没有视频帧时画一帧（清屏 + 字幕）。 */
int fs_vulkan_renderer_display_sub_overlay(FSVulkanRenderer *r);

/*
 * 字幕叠加层。
 *
 * 渲染器不知道字幕内部结构：SDL_GPU 层（vulkan/ijksdl_gpu_vulkan.c）把字幕
 * 画成一张纹理，vout 每帧把这张纹理交给渲染器，渲染器在视频之上做一次预乘
 * alpha 混合的四边形绘制。
 */
void fs_vulkan_renderer_set_sub_overlay(FSVulkanRenderer *r, struct SDL_TextureOverlay *overlay);

/* 取回叠加层（Retain，调用方负责 Release），用于字幕画完后取纹理。 */
struct SDL_TextureOverlay *fs_vulkan_renderer_get_sub_overlay(FSVulkanRenderer *r);

/* 暴露底层 Vulkan 设备上下文，供 SDL_GPU 层在同一 device/queue 上工作。 */
const struct FSVulkanContext *fs_vulkan_renderer_context(FSVulkanRenderer *r);

#endif
