/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Real GL tests. The shell helpers below mirror the platform-neutral helpers
 * at the end of ijksdl_gpu_vulkan.c; no GPU operation is mocked.
 */
#include "../fs_gles_renderer.h"
#include <EGL/egl.h>
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifndef FS_GLES_TEST_LINK_PLAYER
SDL_TextureOverlay *SDL_TextureOverlay_Retain(SDL_TextureOverlay *t)
{
    if (t)
        t->refCount++;
    return t;
}
void SDL_TextureOverlay_Release(SDL_TextureOverlay **p)
{
    if (!p || !*p)
        return;
    SDL_TextureOverlay *t = *p;
    *p = NULL;
    if (!--t->refCount) {
        t->dealloc(t);
        free(t);
    }
}
void SDL_FBOOverlayFreeP(SDL_FBOOverlay **p)
{
    if (p && *p) {
        (*p)->dealloc(*p);
        free(*p);
        *p = NULL;
    }
}
void SDL_GPUFreeP(SDL_GPU **p)
{
    if (p && *p) {
        (*p)->dealloc(*p);
        free(*p);
        *p = NULL;
    }
}
#endif
static void no_current(void)
{
    assert(eglGetCurrentContext() == EGL_NO_CONTEXT);
}
static atomic_int running;
static void *render_loop(void *opaque)
{
    FSGLESRenderer *r = opaque;
    while (atomic_load(&running)) {
        assert(!fs_gles_renderer_display_sub_overlay(r));
        no_current();
        usleep(1000);
    }
    return NULL;
}
static uint8_t *snapshot(FSGLESRenderer *r, int type, int *w, int *h)
{
    uint8_t *p = NULL;
    assert(!fs_gles_renderer_take_snapshot(r, type, w, h, (void **)&p));
    assert(p);
    return p;
}
static AVFrame *frame(int fmt, int negative, int full)
{
    AVFrame *f = av_frame_alloc();
    assert(f);
    f->width = 17;
    f->height = 9;
    f->format = fmt;
    assert(!av_frame_get_buffer(f, 32));
    f->color_range = full ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG;
    f->colorspace = AVCOL_SPC_BT709;
    int ten = fmt == AV_PIX_FMT_YUV420P10LE, nv = fmt == AV_PIX_FMT_NV12;
    for (int plane = 0; plane < (nv ? 2 : 3); plane++) {
        int h = plane ? 5 : 9, w = plane ? 9 : 17;
        if (negative) {
            f->data[plane] += (h - 1) * f->linesize[plane];
            f->linesize[plane] = -f->linesize[plane];
        }
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                int value = plane ? (ten ? 512 : 128)
                                  : (y < 4 ? (full ? 0 : (ten ? 64 : 16))
                                           : (full ? (ten ? 1023 : 255) : (ten ? 940 : 235)));
                uint8_t *p = f->data[plane] + y * f->linesize[plane];
                if (ten)
                    ((uint16_t *)p)[x] = (uint16_t)value;
                else if (nv && plane) {
                    p[2 * x] = (uint8_t)value;
                    p[2 * x + 1] = (uint8_t)value;
                } else
                    p[x] = (uint8_t)value;
            }
    }
    return f;
}
static void expect_rgb(const uint8_t *p, int r, int g, int b, int tolerance)
{
    if (abs(p[0] - r) > tolerance || abs(p[1] - g) > tolerance || abs(p[2] - b) > tolerance) {
        fprintf(stderr, "pixel got %d,%d,%d wanted %d,%d,%d tolerance %d\n", p[0], p[1], p[2], r, g,
                b, tolerance);
        abort();
    }
}
static void constant_frame(AVFrame *f, int yv, int uv, int vv)
{
    int values[3] = {yv, uv, vv};
    int ten = f->format == AV_PIX_FMT_YUV420P10LE;
    for (int k = 0; k < 3; k++)
        for (int y = 0; y < (k ? 5 : 9); y++)
            for (int x = 0; x < (k ? 9 : 17); x++) {
                uint8_t *p = f->data[k] + (ptrdiff_t)y * f->linesize[k];
                if (ten)
                    ((uint16_t *)p)[x] = (uint16_t)values[k];
                else
                    p[x] = (uint8_t)values[k];
            }
}
static double hable(double x)
{
    return ((x * (.15 * x + .05) + .004) / (x * (.15 * x + .5) + .06)) - .02 / .3;
}
static double pq(double x)
{
    double p = pow(fmax(x, 0), 1 / 78.84375);
    return pow(fmax(p - .8359375, 0) / fmax(18.8515625 - 18.6875 * p, 1e-30), 1 / .1593017578125);
}
static double hlg(double x)
{
    x = fmax(x, 0);
    return pow(x <= .5 ? x * x / 3 : (exp((x - .55991073) / .17883277) + .28466892) / 12, 1.2);
}
static int quantize(double x)
{
    return (int)lround(fmax(0, fmin(1, x)) * 255);
}
static void reference_rgb(AVFrame *f, int yv, int uv, int vv, int adjust, int out[3])
{
    double kr = .299, kb = .114, max = f->format == AV_PIX_FMT_YUV420P10LE ? 1023 : 255;
    double factor = max == 1023 ? 4 : 1;
    if (f->colorspace == AVCOL_SPC_BT709) {
        kr = .2126;
        kb = .0722;
    }
    if (f->colorspace == AVCOL_SPC_BT2020_NCL) {
        kr = .2627;
        kb = .0593;
    }
    int full = f->color_range == AVCOL_RANGE_JPEG;
    double yy = full ? yv / max : (yv - 16 * factor) / (219 * factor);
    double u = (uv - 128 * factor) / (full ? max : 224 * factor),
           v = (vv - 128 * factor) / (full ? max : 224 * factor);
    double rgb[3] = {yy + 2 * (1 - kr) * v,
                     yy - 2 * kb * (1 - kb) / (1 - kr - kb) * u -
                         2 * kr * (1 - kr) / (1 - kr - kb) * v,
                     yy + 2 * (1 - kb) * u};
    if (f->colorspace == AVCOL_SPC_BT2020_NCL) {
        double lin[3];
        for (int i = 0; i < 3; i++)
            lin[i] = f->color_trc == AVCOL_TRC_SMPTE2084
                         ? pq(rgb[i]) * 200
                         : (f->color_trc == AVCOL_TRC_ARIB_STD_B67 ? hlg(rgb[i]) * 20
                                                                   : pow(fmax(rgb[i], 0), 2.2));
        rgb[0] = 1.660642 * lin[0] - .587719 * lin[1] - .072778 * lin[2];
        rgb[1] = -.124555 * lin[0] + 1.132951 * lin[1] - .008313 * lin[2];
        rgb[2] = -.018174 * lin[0] - .100571 * lin[1] + 1.118771 * lin[2];
        double s = fmax(fmax(fmax(rgb[0], rgb[1]), rgb[2]), 1e-6), scale = hable(s) / hable(20) / s;
        for (int i = 0; i < 3; i++)
            rgb[i] *= scale;
    }
    if (adjust) {
        const double intensity[3] = {.299, .587, .114};
        for (int i = 0; i < 3; i++) {
            rgb[i] = (rgb[i] - .5) * 1.2 + .5 + (.75 * 1.1 - .5) / 2.5 - .1;
            rgb[i] = rgb[i] * intensity[i] + .5 * (rgb[i] - rgb[i] * intensity[i]);
        }
    }
    for (int i = 0; i < 3; i++)
        out[i] = quantize(rgb[i]);
}
static void color_tests(FSGLESRenderer *r)
{
    int spaces[] = {AVCOL_SPC_SMPTE170M, AVCOL_SPC_BT709, AVCOL_SPC_BT2020_NCL};
    for (int ten = 0; ten < 2; ten++)
        for (int full = 0; full < 2; full++)
            for (int cs = 0; cs < 3; cs++)
                for (int tf = 0; tf < (cs == 2 ? 3 : 1); tf++) {
                    AVFrame *f = frame(ten ? AV_PIX_FMT_YUV420P10LE : AV_PIX_FMT_YUV420P, 1, full);
                    int scale = ten ? 4 : 1;
                    constant_frame(f, 128 * scale, 110 * scale, 155 * scale);
                    f->colorspace = spaces[cs];
                    f->color_trc = tf == 0
                                       ? AVCOL_TRC_BT709
                                       : (tf == 1 ? AVCOL_TRC_SMPTE2084 : AVCOL_TRC_ARIB_STD_B67);
                    assert(!fs_gles_renderer_display(r, f, 17, 9, 0, 1, 1));
                    int w, h, expected[3];
                    reference_rgb(f, 128 * scale, 110 * scale, 155 * scale, 0, expected);
                    uint8_t *p = snapshot(r, FS_SNAPSHOT_TYPE_ORIGIN, &w, &h);
                    expect_rgb(p + 4 * (4 * 17 + 8), expected[0], expected[1], expected[2], 2);
                    free(p);
                    fs_gles_renderer_set_color_adjust(r, 1.1f, .5f, 1.2f);
                    reference_rgb(f, 128 * scale, 110 * scale, 155 * scale, 1, expected);
                    p = snapshot(r, FS_SNAPSHOT_TYPE_SCREEN, &w, &h);
                    expect_rgb(p + 4 * (4 * 17 + 8), expected[0], expected[1], expected[2], 2);
                    free(p);
                    fs_gles_renderer_set_color_adjust(r, 1, 1, 1);
                    av_frame_free(&f);
                }
    puts("PASS BT.601/709/2020, PQ/HLG tone mapping, 8/10bit full/limited and nonidentity B/S/C "
         "CPU reference");
}
static void geometry_tests(FSGLESRenderer *r)
{
    AVFrame *f = frame(AV_PIX_FMT_YUV420P, 0, 0);
    constant_frame(f, 235, 128, 128);
    fs_gles_renderer_set_background_color(r, 64, 32, 16);
    int w, h;
    uint8_t *p;
    assert(!fs_gles_renderer_display(r, f, 17, 9, 0, 2, 1));
    p = snapshot(r, FS_SNAPSHOT_TYPE_SCREEN, &w, &h);
    expect_rgb(p, 64, 32, 16, 1);
    expect_rgb(p + 4 * (4 * 17 + 8), 255, 255, 255, 1);
    free(p);
    fs_gles_renderer_set_scaling_mode(r, FS_SCALING_MODE_ASPECT_FILL);
    p = snapshot(r, FS_SNAPSHOT_TYPE_SCREEN, &w, &h);
    expect_rgb(p, 255, 255, 255, 1);
    free(p);
    fs_gles_renderer_set_scaling_mode(r, FS_SCALING_MODE_FILL);
    p = snapshot(r, FS_SNAPSHOT_TYPE_SCREEN, &w, &h);
    expect_rgb(p, 255, 255, 255, 1);
    free(p);
    fs_gles_renderer_set_scaling_mode(r, FS_SCALING_MODE_ASPECT_FIT);
    assert(!fs_gles_renderer_display(r, f, 17, 9, 90, 1, 1));
    p = snapshot(r, FS_SNAPSHOT_TYPE_SCREEN, &w, &h);
    expect_rgb(p, 64, 32, 16, 1);
    expect_rgb(p + 4 * (4 * 17 + 8), 255, 255, 255, 1);
    free(p);
    assert(!fs_gles_renderer_display(r, f, 17, 9, 0, 1, 1));
    fs_gles_renderer_set_rotate_degrees(r, 0, 60, 0);
    p = snapshot(r, FS_SNAPSHOT_TYPE_SCREEN, &w, &h);
    expect_rgb(p, 64, 32, 16, 1);
    expect_rgb(p + 4 * (4 * 17 + 8), 255, 255, 255, 1);
    free(p);
    fs_gles_renderer_set_rotate_degrees(r, 60, 0, 0);
    p = snapshot(r, FS_SNAPSHOT_TYPE_SCREEN, &w, &h);
    expect_rgb(p, 64, 32, 16, 1);
    expect_rgb(p + 4 * (4 * 17 + 8), 255, 255, 255, 1);
    free(p);
    fs_gles_renderer_set_rotate_degrees(r, 0, 0, 90);
    p = snapshot(r, FS_SNAPSHOT_TYPE_SCREEN, &w, &h);
    expect_rgb(p, 64, 32, 16, 1);
    expect_rgb(p + 4 * (4 * 17 + 8), 255, 255, 255, 1);
    free(p);
    p = snapshot(r, FS_SNAPSHOT_TYPE_EFFECT_SUBTITLE_ORIGIN, &w, &h);
    assert(w == 9 && h == 17);
    expect_rgb(p + 4 * (8 * 9 + 4), 255, 255, 255, 1);
    free(p);
    fs_gles_renderer_set_rotate_degrees(r, 0, 0, 0);
    fs_gles_renderer_set_background_color(r, 0, 0, 0);
    av_frame_free(&f);
    puts("PASS SAR, aspect-fit/fill/stretch, metadata Z and orthographic X/Y/Z rotations");
}
int main(void)
{
    FSGLESRenderer *r = fs_gles_renderer_create();
    assert(r);
    no_current();
    SDL_GPU *g = fs_gles_renderer_get_gpu(r);
    assert(g);
    assert(!fs_gles_renderer_is_mediacodec_supported(r));
    assert(!fs_gles_renderer_get_mediacodec_surface(NULL, r));
    /* JNI-disabled harness must reject opaque MC memory before swscale, even
     * when hw_frames_ctx is NULL (normal MediaCodec AVFrame convention). */
    AVFrame opaque = {0};
    opaque.width = 17;
    opaque.height = 9;
    opaque.format = AV_PIX_FMT_MEDIACODEC;
    opaque.data[3] = (uint8_t *)(uintptr_t)1;
    assert(fs_gles_renderer_display(r, &opaque, 17, 9, 0, 1, 1) == -1);
    assert(fs_gles_renderer_display(r, &opaque, 17, 9, 0, 1, 1) == -1);
    no_current();
    puts("PASS JNI-disabled opaque MediaCodec rejection (no swscale/dereference/fake success)");
    atomic_store(&running, 1);
    pthread_t thread;
    assert(!pthread_create(&thread, NULL, render_loop, r));
    int formats[] = {AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUV420P10LE, AV_PIX_FMT_NV12};
    for (int fmt = 0; fmt < 3; fmt++)
        for (int neg = 0; neg < 2; neg++)
            for (int full = 0; full < 2; full++) {
                AVFrame *f = frame(formats[fmt], neg, full);
                assert(!fs_gles_renderer_display(r, f, 17, 9, 0, 1, 1));
                no_current();
                int w, h;
                uint8_t *p = snapshot(r, FS_SNAPSHOT_TYPE_ORIGIN, &w, &h);
                assert(w == 17 && h == 9);
                expect_rgb(p + (1 * 17 + 8) * 4, 0, 0, 0, 1);
                expect_rgb(p + (7 * 17 + 8) * 4, 255, 255, 255, 1);
                free(p);
                av_frame_free(&f);
            }
    puts("PASS 8/10bit planar + NV12, odd sizes, full/limited ranges, padded/negative strides, "
         "orientation");
    color_tests(r);
    geometry_tests(r);
    AVFrame *f = frame(AV_PIX_FMT_YUV420P, 0, 0);
    assert(!fs_gles_renderer_display(r, f, 17, 9, 0, 1, 1));
    uint8_t bgra[] = {0, 0, 128, 128};
    SDL_TextureOverlay *t = g->createTexture(g, 1, 1, SDL_TEXTURE_FMT_BRGA, bgra);
    assert(t);
    no_current();
    SDL_FBOOverlay *fb = g->createFBO(g, 17, 9);
    assert(fb);
    no_current();
    fb->beginDraw(g, fb, 1);
    fb->drawTexture(g, fb, t, (SDL_Rectangle){0, 0, 17, 9, 4});
    fb->endDraw(g, fb);
    no_current();
    SDL_TextureOverlay *sub = fb->getTexture(fb);
    assert(sub);
    fs_gles_renderer_set_sub_overlay(r, sub);
    int w, h;
    uint8_t *p = snapshot(r, FS_SNAPSHOT_TYPE_EFFECT_ORIGIN, &w, &h);
    expect_rgb(p + 4 * (1 * 17 + 8), 128, 0, 0, 1);
    free(p);
    /* Retained FBO texture must remain usable after FBO shell dies. */
    SDL_FBOOverlayFreeP(&fb);
    p = snapshot(r, FS_SNAPSHOT_TYPE_EFFECT_ORIGIN, &w, &h);
    expect_rgb(p + 4 * (1 * 17 + 8), 128, 0, 0, 1);
    free(p);
    fs_gles_renderer_set_sub_overlay(r, NULL);
    SDL_TextureOverlay_Release(&sub);
    SDL_TextureOverlay_Release(&t);
    puts("PASS premultiplied BGRA + FBO composition and retained output lifetime");
    uint8_t indices[] = {1};
    t = g->createTexture(g, 1, 1, SDL_TEXTURE_FMT_A8, indices);
    assert(t);
    t->palette[1] = 0x8000ff00;
    fb = g->createFBO(g, 17, 9);
    assert(fb);
    fb->beginDraw(g, fb, 0);
    fb->drawTexture(g, fb, t, (SDL_Rectangle){0, 0, 17, 9, 1});
    fb->endDraw(g, fb);
    sub = fb->getTexture(fb);
    fs_gles_renderer_set_sub_overlay(r, sub);
    p = snapshot(r, FS_SNAPSHOT_TYPE_EFFECT_ORIGIN, &w, &h);
    expect_rgb(p + 4 * (1 * 17 + 8), 0, 128, 0, 1);
    free(p);
    t->palette[1] = 0x800000ff;
    fb->beginDraw(g, fb, 0);
    fb->drawTexture(g, fb, t, (SDL_Rectangle){0, 0, 17, 9, 1});
    fb->endDraw(g, fb);
    p = snapshot(r, FS_SNAPSHOT_TYPE_EFFECT_ORIGIN, &w, &h);
    expect_rgb(p + 4 * (1 * 17 + 8), 0, 0, 128, 1);
    free(p);
    fs_gles_renderer_set_sub_overlay(r, NULL);
    SDL_TextureOverlay_Release(&sub);
    SDL_FBOOverlayFreeP(&fb);
    puts("PASS palette A8 expansion, alpha, palette update and beginDraw clear");
    fs_gles_renderer_set_color_adjust(r, 1, 1, 0);
    p = snapshot(r, FS_SNAPSHOT_TYPE_SCREEN, &w, &h);
    expect_rgb(p + 4 * (1 * 17 + 8), 128, 128, 128, 1);
    free(p);
    p = snapshot(r, FS_SNAPSHOT_TYPE_ORIGIN, &w, &h);
    expect_rgb(p + 4 * (1 * 17 + 8), 0, 0, 0, 1);
    free(p);
    fs_gles_renderer_set_color_adjust(r, 1, 1, 1);
    uint8_t background[] = {0, 64, 255, 255};
    fs_gles_renderer_set_background_image(r, background, 1, 1);
    fs_gles_renderer_set_rotate_degrees(r, 90, 0, 0);
    p = snapshot(r, FS_SNAPSHOT_TYPE_SCREEN, &w, &h);
    expect_rgb(p + 4 * (1 * 17 + 8), 0, 64, 255, 1);
    free(p);
    puts("PASS snapshot effects isolation, rotation and cached blur background");
    fs_gles_renderer_set_background_image(r, NULL, 0, 0);
    fs_gles_renderer_set_rotate_degrees(r, 0, 0, 0);
    for (int i = 0; i < 240; i++) {
        int luma = 16 + (i * 37) % 220, expected = (int)lround((luma - 16) * 255. / 219);
        constant_frame(f, luma, 128, 128);
        assert(!fs_gles_renderer_display(r, f, 17, 9, 0, 1, 1));
        no_current();
        p = snapshot(r, FS_SNAPSHOT_TYPE_ORIGIN, &w, &h);
        expect_rgb(p + 4 * (4 * 17 + 8), expected, expected, expected, 1);
        free(p);
    }
    /* Creating/destroying another player cannot invalidate this display. */
    FSGLESRenderer *second = fs_gles_renderer_create();
    assert(second);
    fs_gles_renderer_destroy(second);
    assert(!fs_gles_renderer_display(r, f, 17, 9, 0, 1, 1));
    atomic_store(&running, 0);
    pthread_join(thread, NULL);
    av_frame_free(&f);
    fs_gles_renderer_detach_gpu(r);
    assert(!g->opaque);
    fs_gles_renderer_destroy(r);
    no_current();
    /* Texture callback shell holds r alive until this late release. */
    t->clearDirtyRect(t);
    SDL_TextureOverlay_Release(&t);
    SDL_GPUFreeP(&g);
    puts("PASS cross-thread EGL handoff, 240-frame PBO reuse and late teardown");
    return 0;
}
