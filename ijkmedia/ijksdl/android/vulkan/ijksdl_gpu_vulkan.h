/*****************************************************************************
 * ijksdl_gpu_vulkan.h
 *****************************************************************************
 *
 * Copyright (c) 2024 debugly <qianlongxu@gmail.com>
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

#ifndef IJKSDL_ANDROID_VULKAN__IJKSDL_GPU_VULKAN_H
#define IJKSDL_ANDROID_VULKAN__IJKSDL_GPU_VULKAN_H

#include "fs_vulkan_internal.h"

struct SDL_GPU;

/*
 * 在渲染器的 Vulkan 设备上创建字幕用的 SDL_GPU（纹理 + FBO）。
 * 由 Android vout 创建（和 iOS 的 SDL_CreateGPU_WithContext 对应），
 * 再交给 ffplayer->gpu。
 */
struct SDL_GPU *SDL_VulkanGPU_Create(const FSVulkanContext *ctx);

/*
 * 释放 SDL_GPU 的 Vulkan 资源（纹理、管线、FBO 等），device 必须还活着。
 *
 * ffp_destroy 先销毁 vout（连带 renderer/device）、后才 SDL_GPUFreeP(ffp->gpu)，
 * 所以 vout 销毁时要先调这个函数；之后 SDL_GPUFreeP 只回收壳，不再碰 device。
 */
void SDL_VulkanGPU_DetachDevice(struct SDL_GPU *gpu);

#endif /* IJKSDL_ANDROID_VULKAN__IJKSDL_GPU_VULKAN_H */
