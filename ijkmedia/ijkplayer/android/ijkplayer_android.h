/*
 * ijkplayer_android.h
 *
 * Copyright (c) 2013 Bilibili
 * Copyright (c) 2013 Zhang Rui <bbcallen@gmail.com>
 *
 * This file is part of ijkPlayer.
 *
 * ijkPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * ijkPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#ifndef IJKPLAYER_ANDROID__IJKPLAYER_ANDROID_H
#define IJKPLAYER_ANDROID__IJKPLAYER_ANDROID_H

#include <jni.h>
#include "ijkplayer_android_def.h"
#include "../ijkplayer.h"

typedef struct ijkmp_android_media_format_context {
    const char *mime_type;
    int         profile;
    int         level;
} ijkmp_android_media_format_context;

// ref_count is 1 after open
IjkMediaPlayer *ijkmp_android_create(int(*msg_loop)(void*));

void ijkmp_android_set_surface(JNIEnv *env, IjkMediaPlayer *mp, jobject android_surface);
void ijkmp_android_set_volume(JNIEnv *env, IjkMediaPlayer *mp, float left, float right);
int  ijkmp_android_get_audio_session_id(JNIEnv *env, IjkMediaPlayer *mp);
void ijkmp_android_set_mediacodec_select_callback(IjkMediaPlayer *mp, bool (*callback)(void *opaque, ijkmp_mediacodecinfo_context *mcc), void *opaque);

/*
 * 取一张当前画面的快照（type 见 ijksdl/android/vulkan/fs_vulkan_renderer.h 的
 * FSSnapshotType，对齐 iOS）。会先让视频线程把当前帧重画一次。
 * 成功返回 0，*out_pixels 是 malloc 出来的 RGBA8888，调用方 free。
 * 限制：MediaCodec 零拷贝通路下暂停时取不到最后一帧，会返回 -1（见 .c 里的说明）。
 */
int ijkmp_android_take_snapshot(IjkMediaPlayer *mp, int type,
                                int *out_w, int *out_h, void **out_pixels);

/*
 * 高斯模糊背景（对齐 iOS）。pixels 是 RGBA8888，调用方负责降采样到最长边 400；
 * 传 NULL 清除背景。渲染器还没建好（还没 setSurface）时返回 -1，调用方应稍后重试。
 */
int ijkmp_android_set_background_image(IjkMediaPlayer *mp, const void *pixels, int width, int height);
int ijkmp_android_set_background_blur(IjkMediaPlayer *mp, int iterations, float sigma);

/* 色彩调整（亮度/饱和度/对比度，默认 1.0）与黑边背景色（0~255，默认黑）。 */
int ijkmp_android_set_color_adjust(IjkMediaPlayer *mp, float brightness, float saturation, float contrast);
int ijkmp_android_set_background_color(IjkMediaPlayer *mp, int red, int green, int blue);

#endif
