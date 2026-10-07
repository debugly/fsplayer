/*
 * ffpipeline_android.h
 *
 * Copyright (c) 2014 Bilibili
 * Copyright (c) 2014 Zhang Rui <bbcallen@gmail.com>
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

#ifndef FFPLAY__FF_FFPIPELINE_ANDROID_H
#define FFPLAY__FF_FFPIPELINE_ANDROID_H

#include <stdbool.h>
#include <jni.h>
#include "../ijkplayer_android_def.h"
#include "../../ff_ffpipeline.h"
#include "ijksdl/ijksdl_vout.h"

typedef struct FFPlayer   FFPlayer;

FS_Pipeline *ffpipeline_create_from_android(FFPlayer *ffp);

void    ffpipeline_set_vout(FS_Pipeline* pipeline, SDL_Vout *vout);

int     ffpipeline_set_surface(JNIEnv *env, FS_Pipeline* pipeline, jobject surface);

int     ffpipeline_lock_surface(FS_Pipeline* pipeline);
int     ffpipeline_unlock_surface(FS_Pipeline* pipeline);
jobject ffpipeline_get_surface_as_global_ref_l(JNIEnv *env, FS_Pipeline* pipeline);
jobject ffpipeline_get_surface_as_global_ref(JNIEnv *env, FS_Pipeline* pipeline);

bool    ffpipeline_is_surface_need_reconfigure_l(FS_Pipeline* pipeline);
void    ffpipeline_set_surface_need_reconfigure_l(FS_Pipeline* pipeline, bool need_reconfigure);

void    ffpipeline_set_mediacodec_select_callback(FS_Pipeline* pipeline, bool (*callback)(void *opaque, ijkmp_mediacodecinfo_context *mcc), void *opaque);
bool    ffpipeline_select_mediacodec_l(FS_Pipeline* pipeline, ijkmp_mediacodecinfo_context *mcc);

void    ffpipeline_set_volume(FS_Pipeline* pipeline, float left, float right);

#endif
