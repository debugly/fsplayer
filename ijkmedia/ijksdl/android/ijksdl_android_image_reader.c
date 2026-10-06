/*****************************************************************************
 * ijksdl_android_image_reader.c
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

#include "ijksdl_android_image_reader.h"

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#include <android/hardware_buffer.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <media/NdkImage.h>
#include <media/NdkImageReader.h>

#include "../ijksdl_log.h"
#include "../ijksdl_mutex.h"

/* ---- libmediandk 延迟符号解析 ------------------------------------------- */

typedef media_status_t (*fp_AImageReader_newWithUsage)(int32_t, int32_t, int32_t,
                                                       uint64_t, int32_t, AImageReader **);
typedef media_status_t (*fp_AImageReader_getWindow)(AImageReader *, ANativeWindow **);
typedef media_status_t (*fp_AImageReader_setImageListener)(AImageReader *,
                                                           AImageReader_ImageListener *);
typedef media_status_t (*fp_AImageReader_acquireLatestImage)(AImageReader *, AImage **);
typedef void           (*fp_AImageReader_delete)(AImageReader *);
typedef media_status_t (*fp_AImage_getHardwareBuffer)(const AImage *, AHardwareBuffer **);
typedef void           (*fp_AImage_delete)(AImage *);
typedef void           (*fp_AHardwareBuffer_describe)(const AHardwareBuffer *, AHardwareBuffer_Desc *);
/* libandroid.so，API 26 起提供 */
typedef jobject        (*fp_ANativeWindow_toSurface)(JNIEnv *, ANativeWindow *);

typedef struct {
    void *handle;
    void *android_handle;
    bool  ready;
    fp_AImageReader_newWithUsage        AImageReader_newWithUsage;
    fp_AImageReader_getWindow           AImageReader_getWindow;
    fp_AImageReader_setImageListener    AImageReader_setImageListener;
    fp_AImageReader_acquireLatestImage  AImageReader_acquireLatestImage;
    fp_AImageReader_delete              AImageReader_delete;
    fp_AImage_getHardwareBuffer         AImage_getHardwareBuffer;
    fp_AImage_delete                    AImage_delete;
    fp_AHardwareBuffer_describe         AHardwareBuffer_describe;
    fp_ANativeWindow_toSurface          ANativeWindow_toSurface;
} SDL_AndroidMediaCodecLib;

static SDL_AndroidMediaCodecLib g_mc_lib;
static pthread_once_t g_mc_once = PTHREAD_ONCE_INIT;

static void *mc_dlsym(void *handle, const char *name)
{
    void *sym = dlsym(handle, name);
    if (!sym)
        ALOGW("ijimage: symbol %s not found\n", name);
    return sym;
}

static void mc_load_library(void)
{
    g_mc_lib.handle = dlopen("libmediandk.so", RTLD_NOW | RTLD_GLOBAL);
    if (!g_mc_lib.handle) {
        ALOGW("ijimage: dlopen libmediandk.so failed: %s\n", dlerror());
        return;
    }

    /* ANativeWindow_toSurface 在 libandroid.so，API 26+ 才导出 */
    g_mc_lib.android_handle = dlopen("libandroid.so", RTLD_NOW | RTLD_GLOBAL);
    if (g_mc_lib.android_handle) {
        g_mc_lib.ANativeWindow_toSurface = (fp_ANativeWindow_toSurface)
            dlsym(g_mc_lib.android_handle, "ANativeWindow_toSurface");
    }

    g_mc_lib.AImageReader_newWithUsage =
        (fp_AImageReader_newWithUsage) mc_dlsym(g_mc_lib.handle, "AImageReader_newWithUsage");
    g_mc_lib.AImageReader_getWindow =
        (fp_AImageReader_getWindow) mc_dlsym(g_mc_lib.handle, "AImageReader_getWindow");
    g_mc_lib.AImageReader_setImageListener =
        (fp_AImageReader_setImageListener) mc_dlsym(g_mc_lib.handle, "AImageReader_setImageListener");
    g_mc_lib.AImageReader_acquireLatestImage =
        (fp_AImageReader_acquireLatestImage) mc_dlsym(g_mc_lib.handle, "AImageReader_acquireLatestImage");
    g_mc_lib.AImageReader_delete =
        (fp_AImageReader_delete) mc_dlsym(g_mc_lib.handle, "AImageReader_delete");
    g_mc_lib.AImage_getHardwareBuffer =
        (fp_AImage_getHardwareBuffer) mc_dlsym(g_mc_lib.handle, "AImage_getHardwareBuffer");
    g_mc_lib.AImage_delete =
        (fp_AImage_delete) mc_dlsym(g_mc_lib.handle, "AImage_delete");
    g_mc_lib.AHardwareBuffer_describe =
        (fp_AHardwareBuffer_describe) mc_dlsym(g_mc_lib.handle, "AHardwareBuffer_describe");

    g_mc_lib.ready = g_mc_lib.AImageReader_newWithUsage &&
                     g_mc_lib.AImageReader_getWindow &&
                     g_mc_lib.AImageReader_setImageListener &&
                     g_mc_lib.AImageReader_acquireLatestImage &&
                     g_mc_lib.AImageReader_delete &&
                     g_mc_lib.AImage_getHardwareBuffer &&
                     g_mc_lib.AImage_delete &&
                     g_mc_lib.AHardwareBuffer_describe &&
                     g_mc_lib.ANativeWindow_toSurface;

    if (!g_mc_lib.ready)
        ALOGW("ijimage: libmediandk symbols incomplete, AImageReader disabled\n");
    else
        ALOGI("ijimage: libmediandk ready\n");
}

bool SDL_AndroidImageReader_isAvailable(void)
{
    pthread_once(&g_mc_once, mc_load_library);
    return g_mc_lib.ready;
}

/* ---- reader 对象 --------------------------------------------------------- */

struct SDL_AndroidImageReader {
    AImageReader *reader;
    ANativeWindow *window;

    SDL_mutex *mutex;
    SDL_cond  *cond;
    volatile bool image_available;

    AImage *image;
    AHardwareBuffer *hwbuf;
    int width;
    int height;
};

static void image_callback(void *context, AImageReader *reader)
{
    SDL_AndroidImageReader *r = (SDL_AndroidImageReader *) context;
    (void) reader;
    if (!r)
        return;

    SDL_LockMutex(r->mutex);
    r->image_available = true;
    SDL_CondSignal(r->cond);
    SDL_UnlockMutex(r->mutex);
}

SDL_AndroidImageReader *SDL_AndroidImageReader_create(int max_images)
{
    if (!SDL_AndroidImageReader_isAvailable())
        return NULL;

    if (max_images <= 0)
        max_images = 3;

    SDL_AndroidImageReader *r = (SDL_AndroidImageReader *) calloc(1, sizeof(*r));
    if (!r)
        return NULL;

    r->mutex = SDL_CreateMutex();
    r->cond  = SDL_CreateCond();
    if (!r->mutex || !r->cond) {
        SDL_AndroidImageReader_destroy(r);
        return NULL;
    }

    /*
     * 尺寸无关紧要：AImageReader 只搬运硬件 buffer。
     * AIMAGE_FORMAT_PRIVATE + GPU_SAMPLED_IMAGE 表示输出可被 GPU 直接采样的
     * 不透明硬件 buffer（gralloc），这正是零拷贝的来源。
     */
    media_status_t ret = g_mc_lib.AImageReader_newWithUsage(
        16, 16, AIMAGE_FORMAT_PRIVATE, AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE,
        max_images, &r->reader);
    if (ret != AMEDIA_OK || !r->reader) {
        ALOGE("ijimage: AImageReader_newWithUsage failed: %d\n", (int) ret);
        SDL_AndroidImageReader_destroy(r);
        return NULL;
    }

    ret = g_mc_lib.AImageReader_getWindow(r->reader, &r->window);
    if (ret != AMEDIA_OK || !r->window) {
        ALOGE("ijimage: getWindow failed: %d\n", (int) ret);
        SDL_AndroidImageReader_destroy(r);
        return NULL;
    }

    AImageReader_ImageListener listener = {
        .context = r,
        .onImageAvailable = image_callback,
    };
    g_mc_lib.AImageReader_setImageListener(r->reader, &listener);

    ALOGI("ijimage: reader created, max_images=%d\n", max_images);
    return r;
}

jobject SDL_AndroidImageReader_getSurface(JNIEnv *env, SDL_AndroidImageReader *r)
{
    if (!env || !r || !r->window || !g_mc_lib.ANativeWindow_toSurface)
        return NULL;

    /* libandroid: 返回 NewLocalRef，调用方负责 DeleteLocalRef。 */
    return g_mc_lib.ANativeWindow_toSurface(env, r->window);
}

static void release_image_locked(SDL_AndroidImageReader *r)
{
    if (r->image) {
        g_mc_lib.AImage_delete(r->image);
        r->image = NULL;
    }
    /* hwbuf 属于 image，随 image 失效；这里只清指针，不做 AHardwareBuffer_release。 */
    r->hwbuf = NULL;
}

void SDL_AndroidImageReader_releaseImage(SDL_AndroidImageReader *r)
{
    if (!r)
        return;
    release_image_locked(r);
}

int SDL_AndroidImageReader_acquireLatest(SDL_AndroidImageReader *r, void **out_hwbuf,
                                         int *out_w, int *out_h, int timeout_ms)
{
    if (!r || !r->reader || !out_hwbuf)
        return -1;

    if (out_w) *out_w = 0;
    if (out_h) *out_h = 0;
    *out_hwbuf = NULL;

    release_image_locked(r);

    if (timeout_ms <= 0)
        timeout_ms = 100;

    SDL_LockMutex(r->mutex);
    if (!r->image_available)
        SDL_CondWaitTimeout(r->cond, r->mutex, (uint32_t) timeout_ms);
    r->image_available = false;
    SDL_UnlockMutex(r->mutex);

    AImage *image = NULL;
    media_status_t ret = g_mc_lib.AImageReader_acquireLatestImage(r->reader, &image);
    if (ret != AMEDIA_OK || !image) {
        /* 无可用 buffer：不是致命错误，交给上层重试/沿用上一帧。 */
        return -1;
    }

    AHardwareBuffer *hwbuf = NULL;
    ret = g_mc_lib.AImage_getHardwareBuffer(image, &hwbuf);
    if (ret != AMEDIA_OK || !hwbuf) {
        ALOGE("ijimage: getHardwareBuffer failed: %d\n", (int) ret);
        g_mc_lib.AImage_delete(image);
        return -1;
    }

    AHardwareBuffer_Desc desc;
    memset(&desc, 0, sizeof(desc));
    g_mc_lib.AHardwareBuffer_describe(hwbuf, &desc);

    r->image = image;
    r->hwbuf = hwbuf;
    r->width = (int) desc.width;
    r->height = (int) desc.height;

    *out_hwbuf = hwbuf;
    if (out_w) *out_w = r->width;
    if (out_h) *out_h = r->height;
    return 0;
}

void SDL_AndroidImageReader_destroy(SDL_AndroidImageReader *r)
{
    if (!r)
        return;

    if (r->reader)
        g_mc_lib.AImageReader_setImageListener(r->reader, NULL);

    release_image_locked(r);

    if (r->reader) {
        g_mc_lib.AImageReader_delete(r->reader);
        r->reader = NULL;
    }
    /* window 由 reader 持有，删除 reader 后失效。 */
    r->window = NULL;

    if (r->cond)  SDL_DestroyCond(r->cond);
    if (r->mutex) SDL_DestroyMutex(r->mutex);
    free(r);
}
