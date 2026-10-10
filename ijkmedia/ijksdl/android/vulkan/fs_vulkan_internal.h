/*****************************************************************************
 * fs_vulkan_internal.h
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

#ifndef IJKSDL_ANDROID_VULKAN__FS_VULKAN_INTERNAL_H
#define IJKSDL_ANDROID_VULKAN__FS_VULKAN_INTERNAL_H

#include "fs_vulkan_renderer.h"

#define VK_USE_PLATFORM_ANDROID_KHR 1
#include <vulkan/vulkan.h>

struct SDL_TextureOverlay;

/*
 * 渲染器交给字幕层（SDL_GPU，ijksdl_gpu_vulkan.c）的 Vulkan 上下文。
 * 字幕纹理/FBO 全部在渲染器自己的 device 上创建；提交走字幕层自己的
 * command buffer + fence，不会碰到渲染线程正在记录的那个。
 */
typedef struct FSVulkanContext {
    VkPhysicalDevice physical_device;
    VkDevice         device;
    VkQueue          queue;
    uint32_t         queue_family;
    VkCommandPool    command_pool;
    VkFormat         swapchain_format;
} FSVulkanContext;

/*
 * 安卓侧 SDL_TextureOverlay::getTexture 返回这张“可采样纹理”句柄，
 * 主渲染 pass 直接拿 view 采样（不做 palette 查表：A8 已在 CPU 侧按
 * palette 展开成预乘 RGBA）。
 */
typedef struct FSVulkanSubTexture {
    VkImageView view;
    int width;
    int height;
    int is_a8;
} FSVulkanSubTexture;

const FSVulkanContext *fs_vulkan_renderer_context(FSVulkanRenderer *r);

/* 交给主 pass 的字幕纹理（retain 一份给调用方；无字幕时为 NULL） */
struct SDL_TextureOverlay *fs_vulkan_renderer_get_sub_overlay(FSVulkanRenderer *r);
void fs_vulkan_renderer_set_sub_overlay(FSVulkanRenderer *r, struct SDL_TextureOverlay *overlay);

#endif /* IJKSDL_ANDROID_VULKAN__FS_VULKAN_INTERNAL_H */
