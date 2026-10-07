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
 * 缩放模式，取值和语义对齐 iOS 的 FSScalingMode（FSVideoRenderingProtocol.h）：
 *   AspectFit  等比缩放，完整显示画面（默认，可能有黑边）
 *   AspectFill 等比缩放，铺满显示区（可能裁掉一部分画面）
 *   Fill       非等比拉伸，正好铺满显示区
 */
typedef enum {
    FS_SCALING_MODE_ASPECT_FIT = 0,
    FS_SCALING_MODE_ASPECT_FILL = 1,
    FS_SCALING_MODE_FILL = 2,
} FSScalingMode;

/*
 * 快照类型，数值和语义对齐 iOS 的 FSSnapshotType（FSVideoRenderingProtocol.h）：
 *   ORIGIN                  原始视频尺寸，不带字幕、不带效果
 *   SCREEN                  屏幕上所见（含缩放/letterbox/旋转/字幕）
 *   EFFECT_ORIGIN           原始尺寸，带字幕，不带效果
 *   EFFECT_SUBTITLE_ORIGIN  原始尺寸，带字幕和效果（Android 目前只有旋转算效果）
 * Android 没有 HDR/色彩效果，EFFECT_* 与 ORIGIN 的差别只在旋转和字幕。
 */
typedef enum {
    FS_SNAPSHOT_TYPE_ORIGIN = 0,
    FS_SNAPSHOT_TYPE_SCREEN = 1,
    FS_SNAPSHOT_TYPE_EFFECT_ORIGIN = 2,
    FS_SNAPSHOT_TYPE_EFFECT_SUBTITLE_ORIGIN = 3,
} FSSnapshotType;

/*
 * 高斯模糊背景（语义对齐 iOS 的 backgroundImage / backgroundBlurIterations /
 * backgroundBlurSigma）。
 *
 * pixels 是 RGBA8888（宽*高*4，行紧凑），调用方应已按 iOS 的做法把图降采样到
 * 最长边 400（Java 侧用 Bitmap.createScaledBitmap）。传 NULL 清除背景。
 * 上传和模糊都在渲染线程上按需做一次，不是每帧都跑。
 */
void fs_vulkan_renderer_set_background_image(FSVulkanRenderer *r,
                                             const void *pixels, int width, int height);

/* iterations 默认 3（至少 1）；sigma 默认 30（<=0 时回到 30），单位是工作分辨率的纹素。 */
void fs_vulkan_renderer_set_background_blur(FSVulkanRenderer *r, int iterations, float sigma);

/*
 * 色彩调整（亮度/饱和度/对比度），语义对齐 iOS 的 colorPreference：默认都是 1.0，
 * 三者都是 1.0 时原样输出。只作用于视频画面，不影响字幕（和 iOS 一致）。
 */
void fs_vulkan_renderer_set_color_adjust(FSVulkanRenderer *r,
                                         float brightness, float saturation, float contrast);

/* 无视频区域（黑边）的背景色，0~255，默认黑。对齐 iOS 的 -setBackgroundColor:g:b:。 */
void fs_vulkan_renderer_set_background_color(FSVulkanRenderer *r, int red, int green, int blue);

/*
 * HDR：内容是 BT.2020 即视为 HDR（和 iOS 一致），transfer 取 PQ/HLG/线性，
 * 屏不支持直显时按 iOS 的 hdr2sdr 做色调映射（peak_luminance = 50）。
 * allow 对应 iOS 的 allowHDRDirectDisplay，默认 1。
 */
void fs_vulkan_renderer_set_allow_hdr_display(FSVulkanRenderer *r, int allow);
int  fs_vulkan_renderer_is_hdr_content(FSVulkanRenderer *r);
int  fs_vulkan_renderer_is_hdr_display_active(FSVulkanRenderer *r);

/*
 * 取一张快照（在渲染线程上把当前帧再画一次到离屏图像再回读）。
 * 调用方在别的线程上阻塞等待，最多等几秒；成功时 *out_pixels 是 malloc 出来的
 * RGBA8888（宽*高*4，行紧凑），由调用方 free。
 */
int fs_vulkan_renderer_take_snapshot(FSVulkanRenderer *r, int type,
                                     int *out_w, int *out_h, void **out_pixels);

/* 设置缩放模式；下一帧生效（可在播放中随时切换）。 */
void fs_vulkan_renderer_set_scaling_mode(FSVulkanRenderer *r, int mode);
int fs_vulkan_renderer_get_scaling_mode(FSVulkanRenderer *r);

/*
 * 设置画面手动三轴旋转（度），语义对齐 iOS 的 xRotateDegrees/yRotateDegrees/
 * zRotateDegrees：绕画面中心的正交三轴旋转，最终与自动 Z 旋转（元数据）相乘。
 * 三轴都是 0 时与原行为完全一致。下一帧生效。
 */
void fs_vulkan_renderer_set_rotate_degrees(FSVulkanRenderer *r, float x, float y, float z);

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
