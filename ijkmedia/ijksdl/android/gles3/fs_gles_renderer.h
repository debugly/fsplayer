/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef FS_GLES_RENDERER_H
#define FS_GLES_RENDERER_H
#include "../vulkan/fs_vulkan_renderer.h"
#include "ijksdl/ijksdl_gpu.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct FSGLESRenderer FSGLESRenderer;
FSGLESRenderer *fs_gles_renderer_create(void);
void fs_gles_renderer_destroy(FSGLESRenderer *r);
int fs_gles_renderer_set_surface(FSGLESRenderer *r, ANativeWindow *window);
int fs_gles_renderer_display(FSGLESRenderer *r, const AVFrame *frame, int disp_w, int disp_h,
                             int rotate_degrees, int sar_num, int sar_den);
int fs_gles_renderer_display_sub_overlay(FSGLESRenderer *r);
void fs_gles_renderer_set_sub_overlay(FSGLESRenderer *r, SDL_TextureOverlay *overlay);
SDL_TextureOverlay *fs_gles_renderer_get_sub_overlay(FSGLESRenderer *r);
/* Borrowed shell; player owns SDL_GPUFreeP. Detach before destroying renderer. */
SDL_GPU *fs_gles_renderer_get_gpu(FSGLESRenderer *r);
void fs_gles_renderer_detach_gpu(FSGLESRenderer *r);
void fs_gles_renderer_set_scaling_mode(FSGLESRenderer *r, int mode);
int fs_gles_renderer_get_scaling_mode(FSGLESRenderer *r);
void fs_gles_renderer_set_rotate_degrees(FSGLESRenderer *r, float x, float y, float z);
void fs_gles_renderer_set_color_adjust(FSGLESRenderer *r, float brightness, float saturation,
                                       float contrast);
void fs_gles_renderer_set_background_color(FSGLESRenderer *r, int red, int green, int blue);
void fs_gles_renderer_set_background_image(FSGLESRenderer *r, const void *pixels, int width,
                                           int height);
void fs_gles_renderer_set_background_blur(FSGLESRenderer *r, int iterations, float sigma);
void fs_gles_renderer_set_allow_hdr_display(FSGLESRenderer *r, int allow);
int fs_gles_renderer_is_hdr_content(FSGLESRenderer *r);
int fs_gles_renderer_is_hdr_display_active(FSGLESRenderer *r);
int fs_gles_renderer_take_snapshot(FSGLESRenderer *r, int type, int *out_w, int *out_h,
                                   void **out_pixels);
/* Hardware capability is SDR-only; reject BT2020/PQ/HLG before codec open.
 * Decoder Surface is independent of the output window. Getter returns a NEW
 * JNI local reference; caller owns DeleteLocalRef. */
int fs_gles_renderer_is_mediacodec_supported(FSGLESRenderer *r);
jobject fs_gles_renderer_get_mediacodec_surface(JNIEnv *env, FSGLESRenderer *r);
#ifdef __cplusplus
}
#endif
#endif
