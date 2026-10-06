/*****************************************************************************
 * ijksdl_vout_android_vulkan.h
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

#ifndef IJKSDL_ANDROID__IJKSDL_VOUT_ANDROID_VULKAN_H
#define IJKSDL_ANDROID__IJKSDL_VOUT_ANDROID_VULKAN_H

#include <jni.h>
#include "../ijksdl_stdinc.h"
#include "../ijksdl_vout.h"
#include "../ijksdl_gpu.h"

/*
 * 安卓 Vulkan 视频渲染器（全新实现，替代 OpenGL ES / ANativeWindow 方案）。
 *
 * 软解路径：FFmpeg 软解出的 YUV AVFrame -> 上传到 Vulkan 纹理 ->
 * YUV->RGB 转换管线 -> swapchain 呈现到 Android Surface。
 *
 * 硬解零拷贝路径：MediaCodec -> AImageReader(gralloc) -> VkImage 外部显存 ->
 * 采样器上的 YCbCr 转换 -> swapchain 呈现。
 */

SDL_Vout *SDL_VoutAndroid_CreateForVulkan(void);

/* 由上层 (ijkmp_android_set_surface) 调用，把 Java Surface 传给渲染器。 */
void SDL_VoutAndroid_SetAndroidSurface(JNIEnv *env, SDL_Vout *vout, jobject android_surface);

/*
 * 硬解零拷贝通路是否可用（Vulkan 1.1 + AImageReader + 外部显存扩展）。
 * 不可用时上层应保持软解。
 */
int SDL_VoutAndroid_IsMediaCodecSupported(SDL_Vout *vout);

/*
 * 返回 AImageReader 的输出 Surface，供 MediaCodec 作为解码输出目标。
 * 返回 NewLocalRef，调用方负责 DeleteLocalRef；不支持时返回 NULL。
 */
jobject SDL_VoutAndroid_GetMediaCodecSurface(JNIEnv *env, SDL_Vout *vout);

/*
 * 返回字幕用的 SDL_GPU（和渲染器共用 Vulkan device）。
 *
 * 所有权归 ffplayer（ffp_destroy 里 SDL_GPUFreeP 释放），vout 只是在销毁前
 * 调 SDL_VulkanGPU_DetachDevice 释放它的 Vulkan 资源；vout 自身不释放它。
 * 不可用时返回 NULL（字幕功能应关闭）。
 */
SDL_GPU *SDL_VoutAndroid_GetGPU(SDL_Vout *vout);

/*
 * 设置画面缩放模式：0 等比完整显示（默认）1 等比铺满 2 非等比拉伸，
 * 取值见 vulkan/fs_vulkan_renderer.h 的 FSScalingMode（对齐 iOS 的 FSScalingMode）。
 * 播放中随时可调用，下一帧生效。
 */
void SDL_VoutAndroid_SetScalingMode(SDL_Vout *vout, int mode);

/*
 * 设置高斯模糊背景（语义对齐 iOS 的 backgroundImage/backgroundBlurIterations/
 * backgroundBlurSigma）。pixels 是 RGBA8888，需已降采样到最长边 400；传 NULL 清除。
 * 播放中随时可调用，下一帧生效。
 */
void SDL_VoutAndroid_SetBackgroundImage(SDL_Vout *vout, const void *pixels, int width, int height);
void SDL_VoutAndroid_SetBackgroundBlur(SDL_Vout *vout, int iterations, float sigma);

/*
 * 取一张快照：在渲染线程上把当前帧重画到离屏图像再回读。
 * type 见 vulkan/fs_vulkan_renderer.h 的 FSSnapshotType（对齐 iOS 的 FSSnapshotType）。
 * 成功返回 0，*out_pixels 是 malloc 出来的 RGBA8888（宽*高*4，行紧凑），调用方 free。
 * 会阻塞等待渲染线程，最长约 5 秒。
 */
int SDL_VoutAndroid_TakeSnapshot(SDL_Vout *vout, int type,
                                 int *out_w, int *out_h, void **out_pixels);

#endif
