/* SPDX-License-Identifier: LGPL-2.1-or-later
 * FSPlayer OpenGL ES 3 backend. See README.md for ownership and threading.
 * The YUV rendering architecture was informed by ijkplayer (Bilibili,
 * Zhang Rui, LGPL-2.1-or-later); this is a new ES3 implementation, not ES2 code.
 */
#include "fs_gles_renderer.h"
#include "libavutil/pixfmt.h"
#include "libswscale/swscale.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <android/log.h>
#include <android/native_window.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#if defined(__ANDROID__) && !defined(FS_GLES_NO_JNI)
#include "../ijksdl_android_jni.h"
#include "libavcodec/mediacodec.h"
#define FS_GLES_ANDROID_CODEC 1
#endif
#ifndef GL_TEXTURE_EXTERNAL_OES
#define GL_TEXTURE_EXTERNAL_OES 0x8D65
#endif
#define LOGI(...) __android_log_print(4, "FSGLESRenderer", __VA_ARGS__)

#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "FSGLESRenderer", __VA_ARGS__)
#define RING 3
#define PI 3.14159265358979323846f
#define U(p, n) glGetUniformLocation((p), (n))
typedef struct Tex Tex;
typedef struct Fbo Fbo;
struct Tex {
    FSGLESRenderer *r;
    GLuint id;
    int w, h, flipped;
    uint8_t *a8;
};
struct Fbo {
    FSGLESRenderer *r;
    GLuint id;
    SDL_TextureOverlay *tex;
    int active;
};
struct FSGLESRenderer {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    int refs, dead, depth;
    EGLDisplay display;
    EGLConfig config;
    EGLContext context;
    EGLSurface pbuffer, surface;
    ANativeWindow *window;
    GLuint video, rgba, blur, vao, vbo;
    GLuint planes[3], pbo[RING];
    GLsync fences[RING];
    unsigned slot;
    int width, height, format, have_frame;
    int disp_w, disp_h, sar_num, sar_den, auto_z, mode;
    float rotation[3], adjust[3], background[3];
    float matrix[9], offset[3], scale[3];
    int hdr, tf, allow_hdr;
    struct SwsContext *sws;
    AVFrame *converted;
    SDL_GPU *gpu;
    int gpu_exported;
    SDL_TextureOverlay *subtitle;
    uint8_t *bg_pixels;
    int bg_w, bg_h, bg_dirty, iterations;
    float sigma;
    GLuint bg_src, bg_tex[2], bg_fbo;
    int snap_busy, snap_pending, snap_type, snap_result, snap_w, snap_h;
    void *snap_pixels;
    GLuint oes, external;
    float tex_matrix[16];
    AVFrame *mc_last; /* Retains identity: allocator cannot recycle a redisplayed buffer. */
    unsigned long oes_frames, cpu_uploads;
    int mc_failed;
#ifdef FS_GLES_ANDROID_CODEC
    jclass mc_class;
    jobject mc_helper, mc_surface;
    jfloatArray mc_matrix;
    jmethodID mc_latch, mc_release;
#endif
};

/* All GL operations use this one recursively locked context. No context is left
 * current after a public call, including on error. We deliberately do not use
 * eglReleaseThread: the embedding application may own EGL thread state. */
static int enter(FSGLESRenderer *r)
{
    if (!r)
        return 0;
    pthread_mutex_lock(&r->mutex);
    if (r->dead || r->context == EGL_NO_CONTEXT) {
        pthread_mutex_unlock(&r->mutex);
        return 0;
    }
    if (!r->depth && !eglMakeCurrent(r->display, r->pbuffer, r->pbuffer, r->context)) {
        LOGE("eglMakeCurrent failed: 0x%x", eglGetError());
        pthread_mutex_unlock(&r->mutex);
        return 0;
    }
    r->depth++;
    return 1;
}
static void leave(FSGLESRenderer *r)
{
    if (!--r->depth) {
        glFlush();
        eglMakeCurrent(r->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
    pthread_mutex_unlock(&r->mutex);
}
static void ref(FSGLESRenderer *r)
{
    ++r->refs;
}
static void unref(FSGLESRenderer *r)
{
    int last;
    pthread_mutex_lock(&r->mutex);
    last = !--r->refs;
    pthread_mutex_unlock(&r->mutex);
    if (last) {
        pthread_cond_destroy(&r->cond);
        pthread_mutex_destroy(&r->mutex);
        free(r);
    }
}
static int dimensions(int w, int h)
{
    return w > 0 && h > 0 && w <= 32768 && h <= 32768 && (size_t)w * h <= SIZE_MAX / 8;
}
static GLuint texture(int w, int h, GLenum internal, GLenum filter)
{
    GLint max = 0;
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &max);
    if (!dimensions(w, h) || w > max || h > max)
        return 0;
    GLuint t = 0;
    glGenTextures(1, &t);
    glBindTexture(GL_TEXTURE_2D, t);
    glTexStorage2D(GL_TEXTURE_2D, 1, internal, w, h);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    if (glGetError() != GL_NO_ERROR) {
        glDeleteTextures(1, &t);
        return 0;
    }
    return t;
}
static GLuint shader(GLenum kind, const char *src)
{
    GLuint s = glCreateShader(kind);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[2048];
        glGetShaderInfoLog(s, sizeof(log), NULL, log);
        LOGE("shader: %s", log);
        glDeleteShader(s);
        return 0;
    }
    return s;
}
static const char *vertex_src =
    "#version 300 es\n"
    "layout(location=0) in vec2 pos; uniform mat3 transform; uniform vec4 rect; uniform int flip; "
    "out vec2 uv;\n"
    "void main(){vec2 p=mix(rect.xy,rect.zw,pos); vec3 q=transform*vec3(p,1); "
    "gl_Position=vec4(q.xy,0,1); uv=vec2(pos.x,flip!=0?1.-pos.y:pos.y);}\n";
static const char *rgba_src =
    "#version 300 es\nprecision highp float; in vec2 uv; uniform sampler2D image; out vec4 color; "
    "void main(){color=texture(image,uv);}\n";
static const char *external_src =
    "#version 300 es\n"
    "#extension GL_OES_EGL_image_external_essl3 : require\n"
    "precision highp float; in vec2 uv; uniform samplerExternalOES image; "
    "uniform mat4 texMatrix; uniform vec3 adjust; out vec4 color;\n"
    "void main(){vec2 coord=(texMatrix*vec4(uv.x,1.-uv.y,0.,1.)).xy;"
    "vec3 rgb=texture(image,coord).rgb;"
    "if(any(notEqual(adjust,vec3(1)))){rgb=(rgb-.5)*adjust.z+.5;rgb+=(.75*adjust.x-.5)/2.5-.1;"
    "vec3 intensity=rgb*vec3(.299,.587,.114);rgb=intensity+adjust.y*(rgb-intensity);}"
    "color=vec4(rgb,1);}\n";
static const char *external_vertex_100 =
    "#version 100\nattribute vec2 pos; uniform mat3 transform; uniform vec4 rect; "
    "uniform int flip; varying vec2 uv;\n"
    "void main(){vec2 p=mix(rect.xy,rect.zw,pos);vec3 q=transform*vec3(p,1.);"
    "gl_Position=vec4(q.xy,0.,1.);uv=vec2(pos.x,flip!=0?1.-pos.y:pos.y);}\n";
static const char *external_src_100 =
    "#version 100\n#extension GL_OES_EGL_image_external : require\n"
    "precision highp float; varying vec2 uv; uniform samplerExternalOES image;"
    "uniform mat4 texMatrix; uniform vec3 adjust;\n"
    "void main(){vec2 coord=(texMatrix*vec4(uv.x,1.-uv.y,0.,1.)).xy;"
    "vec3 rgb=texture2D(image,coord).rgb;"
    "if(any(notEqual(adjust,vec3(1.)))){rgb=(rgb-.5)*adjust.z+.5;rgb+=(.75*adjust.x-.5)/2.5-.1;"
    "vec3 intensity=rgb*vec3(.299,.587,.114);rgb=intensity+adjust.y*(rgb-intensity);}"
    "gl_FragColor=vec4(rgb,1.);}\n";
static const char *blur_src =
    "#version 300 es\nprecision highp float; in vec2 uv; uniform sampler2D image; uniform vec2 "
    "stepUV; uniform float sigma; out vec4 color;\n"
    "void main(){vec4 sum=vec4(0); float total=0.; for(int i=-64;i<=64;i++){float x=float(i); "
    "float w=exp(-.5*x*x/(sigma*sigma)); sum+=texture(image,uv+x*stepUV)*w; total+=w;} "
    "color=sum/total;}\n";
/* Keep HDR maths in parity with vulkan/shaders/hdr_common.glsl. */
static const char *video_src =
    "#version 300 es\nprecision highp float; precision highp usampler2D;\n"
    "in vec2 uv; out vec4 color; uniform sampler2D Y,U,V; uniform usampler2D Y10,U10,V10;\n"
    "uniform int bits, nv12, hdr, tf; uniform mat3 matrix; uniform vec3 offset,rangeScale,adjust;\n"
    "float pq(float x){float p=pow(max(x,0.),1./78.84375); return "
    "pow(max(p-.8359375,0.)/max(18.8515625-18.6875*p,1e-30),1./.1593017578125);}\n"
    "float hlg(float x){x=max(x,0.); return "
    "pow(x<=.5?x*x/3.:(exp((x-.55991073)/.17883277)+.28466892)/12.,1.2);}\n"
    "float hable(float x){return ((x*(.15*x+.05)+.004)/(x*(.15*x+.5)+.06))-.02/.3;}\n"
    /* R16UI is core ES3 (R16 normalized is not). Interpolate integer texels
     * explicitly, retaining 10-bit precision without requiring EXT_texture_norm16. */
    "float sample10(usampler2D s,vec2 coord){ivec2 size=textureSize(s,0);vec2 "
    "p=coord*vec2(size)-.5;ivec2 a=ivec2(floor(p));vec2 f=fract(p);ivec2 hi=size-1;"
    "float "
    "x=float(texelFetch(s,clamp(a,ivec2(0),hi),0).r),y=float(texelFetch(s,clamp(a+ivec2(1,0),ivec2("
    "0),hi),0).r);"
    "float "
    "z=float(texelFetch(s,clamp(a+ivec2(0,1),ivec2(0),hi),0).r),w=float(texelFetch(s,clamp(a+ivec2("
    "1,1),ivec2(0),hi),0).r);return mix(mix(x,y,f.x),mix(z,w,f.x),f.y);}\n"
    "void main(){vec3 yuv; "
    "if(bits==10){yuv=vec3(sample10(Y10,uv),sample10(U10,uv),sample10(V10,uv))/1023.;}"
    "else {yuv=vec3(texture(Y,uv).r,texture(U,uv).r,nv12!=0?texture(U,uv).g:texture(V,uv).r);}"
    "vec3 rgb=matrix*((yuv+offset)*rangeScale);"
    "if(hdr!=0){vec3 v=max(rgb,vec3(0)); if(tf==1)v=vec3(pq(v.r),pq(v.g),pq(v.b))*200.; else "
    "if(tf==2)v=vec3(hlg(v.r),hlg(v.g),hlg(v.b))*20.; else v=pow(v,vec3(2.2));"
    "v=mat3(1.660642,-.124555,-.018174,-.587719,1.132951,-.100571,-.072778,-.008313,1.118771)*v; "
    "float s=max(max(max(v.r,v.g),v.b),1e-6); rgb=v*(hable(s)/hable(20.))/s;}"
    "if(any(notEqual(adjust,vec3(1)))){rgb=(rgb-.5)*adjust.z+.5; rgb+=(.75*adjust.x-.5)/2.5-.1; "
    "vec3 intensity=rgb*vec3(.299,.587,.114); rgb=intensity+adjust.y*(rgb-intensity);} "
    "color=vec4(rgb,1);}\n";
static GLuint program_pair(const char *vertex, const char *fs)
{
    GLuint vs = shader(GL_VERTEX_SHADER, vertex), f = shader(GL_FRAGMENT_SHADER, fs), p = 0;
    if (vs && f) {
        p = glCreateProgram();
        glAttachShader(p, vs);
        glAttachShader(p, f);
        glBindAttribLocation(p, 0, "pos"); /* ESSL100 has no layout(location). */
        glLinkProgram(p);
        GLint ok = 0;
        glGetProgramiv(p, GL_LINK_STATUS, &ok);
        if (!ok) {
            char log[2048];
            glGetProgramInfoLog(p, sizeof(log), NULL, log);
            LOGE("link: %s", log);
            glDeleteProgram(p);
            p = 0;
        }
    }
    if (vs)
        glDeleteShader(vs);
    if (f)
        glDeleteShader(f);
    return p;
}
static GLuint program(const char *fs)
{
    return program_pair(vertex_src, fs);
}
#include "fs_gles_mediacodec.inc"
static const float identity[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
static void quad(FSGLESRenderer *r, GLuint p, const float *m, const float *rect, int flip)
{
    glUseProgram(p);
    glBindVertexArray(r->vao);
    glUniformMatrix3fv(U(p, "transform"), 1, GL_FALSE, m ? m : identity);
    glUniform4fv(U(p, "rect"), 1, rect);
    glUniform1i(U(p, "flip"), flip);
}
static void draw_rgba(FSGLESRenderer *r, GLuint id, const float *m, const float *rect, int flip)
{
    quad(r, r->rgba, m, rect, flip);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, id);
    glUniform1i(U(r->rgba, "image"), 0);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}
static const float full_rect[4] = {-1, 1, 1, -1};

/* SDL_GPU implementation. Each retained overlay keeps the renderer's mutex
 * shell alive even after EGL teardown. Thus late release never touches dead EGL. */
static void tex_dealloc(SDL_TextureOverlay *o)
{
    Tex *t = o->opaque;
    if (!t)
        return;
    FSGLESRenderer *r = t->r;
    if (enter(r)) {
        if (t->id)
            glDeleteTextures(1, &t->id);
        leave(r);
    }
    free(t->a8);
    free(t);
    o->opaque = NULL;
    unref(r);
}
static void *tex_get(SDL_TextureOverlay *o)
{
    return o ? o->opaque : NULL;
}
static int tex_upload(SDL_TextureOverlay *o, SDL_Rectangle q, const void *pixels, int clear)
{
    Tex *t = o->opaque;
    if (!t || q.x < 0 || q.y < 0 || q.w <= 0 || q.h <= 0 || q.x > o->w - q.w || q.y > o->h - q.h)
        return -1;
    int bpp = o->fmt == SDL_TEXTURE_FMT_A8 ? 1 : 4;
    ptrdiff_t stride = q.stride ? q.stride : q.w * bpp;
    if (!clear && (!pixels || llabs((long long)stride) < q.w * bpp))
        return -1;
    size_t bytes = (size_t)q.w * q.h * 4;
    uint8_t *rgba = calloc(1, bytes);
    if (!rgba)
        return -1;
    for (int y = 0; y < q.h; y++) {
        const uint8_t *src = clear ? NULL : (const uint8_t *)pixels + y * stride;
        if (o->fmt == SDL_TEXTURE_FMT_A8) {
            if (!t->a8) {
                free(rgba);
                return -1;
            }
            uint8_t *dst = t->a8 + (size_t)(q.y + y) * o->w + q.x;
            if (clear)
                memset(dst, 0, q.w);
            else
                memcpy(dst, src, q.w);
        } else if (!clear) {
            for (int x = 0; x < q.w; x++) {
                uint8_t *d = rgba + ((size_t)y * q.w + x) * 4;
                d[0] = src[x * 4 + 2];
                d[1] = src[x * 4 + 1];
                d[2] = src[x * 4];
                d[3] = src[x * 4 + 3];
            }
        }
    }
    if (o->fmt != SDL_TEXTURE_FMT_A8) {
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
        glBindTexture(GL_TEXTURE_2D, t->id);
        glTexSubImage2D(GL_TEXTURE_2D, 0, q.x, q.y, q.w, q.h, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    }
    free(rgba);
    return glGetError() == GL_NO_ERROR ? 0 : -1;
}
static void tex_replace(SDL_TextureOverlay *o, SDL_Rectangle q, void *pixels)
{
    Tex *t = o ? o->opaque : NULL;
    if (!t || !enter(t->r))
        return;
    if (!tex_upload(o, q, pixels, 0)) {
        o->dirtyRect = SDL_union_rectangle(o->dirtyRect, q);
        o->changed = 1;
    }
    leave(t->r);
}
static void tex_clear(SDL_TextureOverlay *o)
{
    Tex *t = o ? o->opaque : NULL;
    if (!t || !enter(t->r))
        return;
    SDL_Rectangle q = o->dirtyRect;
    if (q.w > 0 && q.h > 0)
        tex_upload(o, q, NULL, 1);
    o->dirtyRect = (SDL_Rectangle){0};
    leave(t->r);
}
static SDL_TextureOverlay *new_tex(FSGLESRenderer *r, int w, int h, SDL_TEXTURE_FMT fmt,
                                   const void *pixels)
{
    if (!dimensions(w, h) || (fmt != SDL_TEXTURE_FMT_BRGA && fmt != SDL_TEXTURE_FMT_A8))
        return NULL;
    SDL_TextureOverlay *o = calloc(1, sizeof(*o));
    Tex *t = calloc(1, sizeof(*t));
    if (!o || !t) {
        free(o);
        free(t);
        return NULL;
    }
    t->id = texture(w, h, GL_RGBA8, GL_LINEAR);
    if (!t->id) {
        free(o);
        free(t);
        return NULL;
    }
    t->r = r;
    t->w = w;
    t->h = h;
    ref(r);
    o->opaque = t;
    o->w = w;
    o->h = h;
    o->fmt = fmt;
    o->scale = 1;
    o->refCount = 1;
    o->getTexture = tex_get;
    o->replaceRegion = tex_replace;
    o->clearDirtyRect = tex_clear;
    o->dealloc = tex_dealloc;
    if (fmt == SDL_TEXTURE_FMT_A8) {
        t->a8 = calloc((size_t)w, h);
        if (!t->a8) {
            SDL_TextureOverlay_Release(&o);
            return NULL;
        }
    }
    SDL_Rectangle q = {0, 0, w, h, w * (fmt == SDL_TEXTURE_FMT_A8 ? 1 : 4)};
    if (tex_upload(o, q, pixels, !pixels)) {
        SDL_TextureOverlay_Release(&o);
        return NULL;
    }
    return o;
}
static SDL_TextureOverlay *gpu_texture(SDL_GPU *g, int w, int h, SDL_TEXTURE_FMT fmt,
                                       const void *pixels)
{
    FSGLESRenderer *r = g ? g->opaque : NULL;
    if (!enter(r))
        return NULL;
    SDL_TextureOverlay *o = new_tex(r, w, h, fmt, pixels);
    leave(r);
    return o;
}
static int expand_a8(SDL_TextureOverlay *o)
{
    Tex *t = o->opaque;
    if (!t || !t->a8)
        return 0;
    uint8_t *p = malloc((size_t)o->w * o->h * 4);
    if (!p)
        return -1;
    for (size_t i = 0, n = (size_t)o->w * o->h; i < n; i++) {
        uint32_t c = o->palette[t->a8[i]], a = c >> 24;
        p[4 * i] = (uint8_t)((((c >> 16) & 255) * a + 127) / 255);
        p[4 * i + 1] = (uint8_t)((((c >> 8) & 255) * a + 127) / 255);
        p[4 * i + 2] = (uint8_t)(((c & 255) * a + 127) / 255);
        p[4 * i + 3] = (uint8_t)a;
    }
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    glBindTexture(GL_TEXTURE_2D, t->id);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, o->w, o->h, GL_RGBA, GL_UNSIGNED_BYTE, p);
    free(p);
    return glGetError() == GL_NO_ERROR ? 0 : -1;
}
static void fbo_clear(SDL_FBOOverlay *o)
{
    Fbo *f = o ? o->opaque : NULL;
    if (!f || !enter(f->r))
        return;
    glBindFramebuffer(GL_FRAMEBUFFER, f->id);
    glDisable(GL_SCISSOR_TEST);
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    leave(f->r);
}
static void fbo_begin(SDL_GPU *g, SDL_FBOOverlay *o, int ass)
{
    (void)g;
    (void)ass;
    Fbo *f = o ? o->opaque : NULL;
    if (!f)
        return;
    /* Hold the recursive mutex for the batch, but NEVER retain current EGL
     * state between callbacks. This prevents presenting a half-built subtitle.
     * SDL_GPU's begin/draw/end contract is balanced on one subtitle thread. */
    pthread_mutex_lock(&f->r->mutex);
    if (!enter(f->r)) {
        pthread_mutex_unlock(&f->r->mutex);
        return;
    }
    if (f->active) {
        leave(f->r);
        pthread_mutex_unlock(&f->r->mutex);
        return;
    }
    f->active = 1;
    fbo_clear(o);
    leave(f->r);
}
static void fbo_draw(SDL_GPU *g, SDL_FBOOverlay *o, SDL_TextureOverlay *t, SDL_Rectangle q)
{
    (void)g;
    Fbo *f = o ? o->opaque : NULL;
    Tex *tx = t ? t->opaque : NULL;
    if (!f || !tx || tx->r != f->r || !enter(f->r))
        return;
    if (f->active && q.w > 0 && q.h > 0 && !expand_a8(t)) {
        glBindFramebuffer(GL_FRAMEBUFFER, f->id);
        glViewport(0, 0, o->w, o->h);
        glDisable(GL_SCISSOR_TEST);
        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        float rect[4] = {2.f * q.x / o->w - 1, 1 - 2.f * q.y / o->h, 2.f * (q.x + q.w) / o->w - 1,
                         1 - 2.f * (q.y + q.h) / o->h};
        draw_rgba(f->r, tx->id, NULL, rect, tx->flipped);
        glDisable(GL_BLEND);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
    }
    leave(f->r);
}
static void fbo_end(SDL_GPU *g, SDL_FBOOverlay *o)
{
    (void)g;
    Fbo *f = o ? o->opaque : NULL;
    if (!f)
        return;
    pthread_mutex_lock(&f->r->mutex);
    int active = f->active;
    f->active = 0;
    pthread_mutex_unlock(&f->r->mutex);
    if (active)
        pthread_mutex_unlock(&f->r->mutex);
}
static SDL_TextureOverlay *fbo_get(SDL_FBOOverlay *o)
{
    Fbo *f = o ? o->opaque : NULL;
    if (!f)
        return NULL;
    pthread_mutex_lock(&f->r->mutex);
    SDL_TextureOverlay *t = SDL_TextureOverlay_Retain(f->tex);
    pthread_mutex_unlock(&f->r->mutex);
    return t;
}
static void fbo_dealloc(SDL_FBOOverlay *o)
{
    Fbo *f = o ? o->opaque : NULL;
    if (!f)
        return;
    FSGLESRenderer *r = f->r;
    if (enter(r)) {
        glDeleteFramebuffers(1, &f->id);
        leave(r);
    }
    pthread_mutex_lock(&r->mutex);
    SDL_TextureOverlay_Release(&f->tex);
    pthread_mutex_unlock(&r->mutex);
    free(f);
    o->opaque = NULL;
    unref(r);
}
static SDL_FBOOverlay *gpu_fbo(SDL_GPU *g, int w, int h)
{
    FSGLESRenderer *r = g ? g->opaque : NULL;
    if (!enter(r))
        return NULL;
    SDL_FBOOverlay *o = calloc(1, sizeof(*o));
    Fbo *f = calloc(1, sizeof(*f));
    if (!o || !f) {
        free(o);
        free(f);
        leave(r);
        return NULL;
    }
    f->r = r;
    ref(r);
    o->opaque = f;
    o->w = w;
    o->h = h;
    o->clear = fbo_clear;
    o->beginDraw = fbo_begin;
    o->drawTexture = fbo_draw;
    o->endDraw = fbo_end;
    o->getTexture = fbo_get;
    o->dealloc = fbo_dealloc;
    f->tex = new_tex(r, w, h, SDL_TEXTURE_FMT_BRGA, NULL);
    if (!f->tex)
        goto fail;
    Tex *t = f->tex->opaque;
    t->flipped = 1;
    glGenFramebuffers(1, &f->id);
    glBindFramebuffer(GL_FRAMEBUFFER, f->id);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t->id, 0);
    int ok = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (!ok)
        goto fail;
    fbo_clear(o);
    leave(r);
    return o;
fail:
    fbo_dealloc(o);
    free(o);
    leave(r);
    return NULL;
}
static void gpu_dealloc(SDL_GPU *g)
{
    FSGLESRenderer *r = g ? g->opaque : NULL;
    if (!r)
        return;
    pthread_mutex_lock(&r->mutex);
    g->opaque = NULL;
    if (r->gpu == g)
        r->gpu = NULL;
    pthread_mutex_unlock(&r->mutex);
    unref(r);
}
SDL_GPU *fs_gles_renderer_get_gpu(FSGLESRenderer *r)
{
    if (!r)
        return NULL;
    pthread_mutex_lock(&r->mutex);
    SDL_GPU *g = r->dead ? NULL : r->gpu;
    if (g)
        r->gpu_exported = 1;
    pthread_mutex_unlock(&r->mutex);
    return g;
}
void fs_gles_renderer_detach_gpu(FSGLESRenderer *r)
{
    if (!r)
        return;
    pthread_mutex_lock(&r->mutex);
    SDL_GPU *g = r->gpu;
    int exported = r->gpu_exported;
    r->gpu = NULL;
    if (g)
        g->opaque = NULL;
    pthread_mutex_unlock(&r->mutex);
    if (g) {
        if (!exported)
            free(g);
        unref(r);
    }
}

/* EGLDisplay is process-shared: terminating it for one player must not tear
 * down another player's contexts. Balance our own initialize/terminate calls. */
static pthread_mutex_t display_mutex = PTHREAD_MUTEX_INITIALIZER;
static EGLDisplay shared_display = EGL_NO_DISPLAY;
static unsigned display_refs;
static EGLDisplay display_acquire(void)
{
    pthread_mutex_lock(&display_mutex);
    if (!display_refs) {
        EGLDisplay d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        EGLint major, minor;
        if (d != EGL_NO_DISPLAY && eglInitialize(d, &major, &minor))
            shared_display = d;
    }
    EGLDisplay d = shared_display;
    if (d != EGL_NO_DISPLAY)
        display_refs++;
    pthread_mutex_unlock(&display_mutex);
    return d;
}
static void display_release(EGLDisplay d)
{
    pthread_mutex_lock(&display_mutex);
    if (d != EGL_NO_DISPLAY && display_refs && !--display_refs) {
        eglTerminate(d);
        shared_display = EGL_NO_DISPLAY;
    }
    pthread_mutex_unlock(&display_mutex);
}
FSGLESRenderer *fs_gles_renderer_create(void)
{
    FSGLESRenderer *r = calloc(1, sizeof(*r));
    if (!r)
        return NULL;
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&r->mutex, &attr);
    pthread_mutexattr_destroy(&attr);
    pthread_cond_init(&r->cond, NULL);
    r->refs = 1;
    r->format = -1;
    r->iterations = 3;
    r->sigma = 30;
    r->allow_hdr = 1;
    r->adjust[0] = r->adjust[1] = r->adjust[2] = 1;
    r->display = display_acquire();
    EGLint count;
    if (r->display == EGL_NO_DISPLAY)
        goto fail;
    const EGLint attrs[] = {EGL_SURFACE_TYPE,
                            EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
                            EGL_RENDERABLE_TYPE,
                            EGL_OPENGL_ES3_BIT_KHR,
                            EGL_RED_SIZE,
                            8,
                            EGL_GREEN_SIZE,
                            8,
                            EGL_BLUE_SIZE,
                            8,
                            EGL_ALPHA_SIZE,
                            8,
                            EGL_NONE};
    if (!eglChooseConfig(r->display, attrs, &r->config, 1, &count) || !count ||
        !eglBindAPI(EGL_OPENGL_ES_API))
        goto fail;
    const EGLint ctx[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE},
                 pb[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    r->context = eglCreateContext(r->display, r->config, EGL_NO_CONTEXT, ctx);
    r->pbuffer = eglCreatePbufferSurface(r->display, r->config, pb);
    if (r->context == EGL_NO_CONTEXT || r->pbuffer == EGL_NO_SURFACE || !enter(r))
        goto fail;
    GLint ver = 0;
    glGetIntegerv(GL_MAJOR_VERSION, &ver);
    r->video = program(video_src);
    r->rgba = program(rgba_src);
    r->blur = program(blur_src);
    const float vertices[] = {0, 0, 1, 0, 0, 1, 1, 1};
    glGenVertexArrays(1, &r->vao);
    glBindVertexArray(r->vao);
    glGenBuffers(1, &r->vbo);
    glBindBuffer(GL_ARRAY_BUFFER, r->vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);
    glGenBuffers(RING, r->pbo);
    int ok = ver >= 3 && r->video && r->rgba && r->blur && glGetError() == GL_NO_ERROR;
    int essl3 = has_extension("GL_OES_EGL_image_external_essl3");
    int legacy = has_extension("GL_OES_EGL_image_external");
    int oes_version = 0;
    if (ok && essl3) {
        r->oes = program(external_src);
        if (r->oes) oes_version = 300;
    }
    /* An ES3 context can also compile ESSL100. This is ONLY an external
     * sampling shader compatibility fallback, never an ES2 renderer/context. */
    if (ok && !r->oes && legacy) {
        r->oes = program_pair(external_vertex_100, external_src_100);
        if (r->oes) oes_version = 100;
    }
    int codec_ready = ok && mc_init(r);
    LOGI("OES setup: essl3=%d legacy=%d shader=%d mediacodec=%d (ES3 context, SDR only)",
         essl3, legacy, oes_version, codec_ready);
    /* OES is optional: a failed extension/JNI setup must not poison software. */
    GLenum optional_error = glGetError();
    if (optional_error != GL_NO_ERROR)
        LOGE("optional OES setup GL error: 0x%x", optional_error);
    leave(r);
    if (!ok)
        goto fail;
    r->gpu = calloc(1, sizeof(*r->gpu));
    if (!r->gpu)
        goto fail;
    r->gpu->opaque = r;
    r->gpu->createTexture = gpu_texture;
    r->gpu->createFBO = gpu_fbo;
    r->gpu->dealloc = gpu_dealloc;
    ref(r);
    return r;
fail:
    LOGE("ES3 initialization failed, EGL 0x%x", eglGetError());
    fs_gles_renderer_destroy(r);
    return NULL;
}
int fs_gles_renderer_set_surface(FSGLESRenderer *r, ANativeWindow *window)
{
    if (!enter(r))
        return -1;
    if (window == r->window && (!window || r->surface != EGL_NO_SURFACE)) {
        leave(r);
        return 0;
    }
    EGLSurface next = EGL_NO_SURFACE;
    if (window) {
        EGLint visual = 0;
        eglGetConfigAttrib(r->display, r->config, EGL_NATIVE_VISUAL_ID, &visual);
        ANativeWindow_acquire(window);
        if (ANativeWindow_setBuffersGeometry(window, 0, 0, visual) < 0) {
            ANativeWindow_release(window);
            leave(r);
            return -1;
        }
        next = eglCreateWindowSurface(r->display, r->config, window, NULL);
        if (next == EGL_NO_SURFACE) {
            ANativeWindow_release(window);
            leave(r);
            return -1;
        }
    }
    if (r->surface != EGL_NO_SURFACE)
        eglDestroySurface(r->display, r->surface);
    if (r->window)
        ANativeWindow_release(r->window);
    r->window = window;
    r->surface = next;
    leave(r);
    return 0;
}

/* Three PBOs, fences polled before reuse. Busy storage is orphaned rather than
 * mapping UNSYNCHRONIZED memory still read by the GPU. No glFinish/frame waits. */
static int upload(FSGLESRenderer *r, const AVFrame *f)
{
    int nv = f->format == AV_PIX_FMT_NV12, bits = f->format == AV_PIX_FMT_YUV420P10LE ? 10 : 8;
    int count = nv ? 2 : 3, cw = (f->width + 1) / 2, ch = (f->height + 1) / 2;
    int w[3] = {f->width, cw, cw}, h[3] = {f->height, ch, ch},
        bpp[3] = {bits == 10 ? 2 : 1, nv ? 2 : (bits == 10 ? 2 : 1), bits == 10 ? 2 : 1};
    size_t offset[3] = {0}, total = 0;
    for (int i = 0; i < count; i++) {
        if (!f->data[i] || llabs((long long)f->linesize[i]) < (long long)w[i] * bpp[i])
            return -1;
        offset[i] = total;
        total += (size_t)w[i] * h[i] * bpp[i];
    }
    if (r->width != f->width || r->height != f->height || r->format != f->format) {
        GLuint tex[3] = {0};
        for (int i = 0; i < count; i++) {
            tex[i] = texture(w[i], h[i], bits == 10 ? GL_R16UI : (nv && i == 1 ? GL_RG8 : GL_R8),
                             bits == 10 ? GL_NEAREST : GL_LINEAR);
            if (!tex[i]) {
                glDeleteTextures(3, tex);
                return -1;
            }
        }
        glDeleteTextures(3, r->planes);
        memcpy(r->planes, tex, sizeof(tex));
        r->width = f->width;
        r->height = f->height;
        r->format = f->format;
        r->have_frame = 0;
    }
    unsigned s = r->slot++ % RING;
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, r->pbo[s]);
    if (r->fences[s]) {
        GLenum status = glClientWaitSync(r->fences[s], 0, 0);
        if (status == GL_WAIT_FAILED) {
            glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
            return -1;
        }
        /* glBufferData below orphans busy backing storage safely. */
        glDeleteSync(r->fences[s]);
        r->fences[s] = 0;
    }
    glBufferData(GL_PIXEL_UNPACK_BUFFER, (GLsizeiptr)total, NULL, GL_STREAM_DRAW);
    uint8_t *p = glMapBufferRange(GL_PIXEL_UNPACK_BUFFER, 0, (GLsizeiptr)total,
                                  GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
    if (!p) {
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        return -1;
    }
    for (int i = 0; i < count; i++)
        for (int y = 0; y < h[i]; y++)
            memcpy(p + offset[i] + (size_t)y * w[i] * bpp[i],
                   f->data[i] + (ptrdiff_t)y * f->linesize[i], (size_t)w[i] * bpp[i]);
    if (!glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER)) {
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        return -1;
    }
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    for (int i = 0; i < count; i++) {
        glBindTexture(GL_TEXTURE_2D, r->planes[i]);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w[i], h[i],
                        bits == 10 ? GL_RED_INTEGER : (nv && i == 1 ? GL_RG : GL_RED),
                        bits == 10 ? GL_UNSIGNED_SHORT : GL_UNSIGNED_BYTE,
                        (const void *)(uintptr_t)offset[i]);
    }
    r->fences[s] = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    if (!r->fences[s] || glGetError() != GL_NO_ERROR)
        return -1;
    r->have_frame = 1;
    ++r->cpu_uploads;
    if (r->cpu_uploads == 1 || r->cpu_uploads % 300 == 0)
        LOGI("software upload: oes_frames=%lu cpu_uploads=%lu", r->oes_frames, r->cpu_uploads);
    return 0;
}
static void color_metadata(FSGLESRenderer *r, const AVFrame *f)
{
    float kr = .299f, kb = .114f;
    if (f->colorspace == AVCOL_SPC_BT709) {
        kr = .2126f;
        kb = .0722f;
    }
    if (f->colorspace == AVCOL_SPC_BT2020_NCL || f->colorspace == AVCOL_SPC_BT2020_CL) {
        kr = .2627f;
        kb = .0593f;
    }
    float kg = 1 - kr - kb;
    float m[9] = {
        1, 1, 1, 0, -2 * kb * (1 - kb) / kg, 2 * (1 - kb), 2 * (1 - kr), -2 * kr * (1 - kr) / kg,
        0};
    memcpy(r->matrix, m, sizeof(m));
    int bits = f->format == AV_PIX_FMT_YUV420P10LE ? 10 : 8,
        full = f->color_range == AVCOL_RANGE_JPEG || f->format == AV_PIX_FMT_YUVJ420P;
    float max = bits == 10 ? 1023.f : 255.f, factor = bits == 10 ? 4.f : 1.f;
    r->offset[0] = full ? 0 : -16 * factor / max;
    r->offset[1] = r->offset[2] = -128 * factor / max;
    r->scale[0] = full ? 1 : max / (219 * factor);
    r->scale[1] = r->scale[2] = full ? 1 : max / (224 * factor);
    r->hdr = f->color_primaries == AVCOL_PRI_BT2020 || f->colorspace == AVCOL_SPC_BT2020_NCL ||
             f->colorspace == AVCOL_SPC_BT2020_CL;
    r->tf =
        f->color_trc == AVCOL_TRC_SMPTE2084 ? 1 : (f->color_trc == AVCOL_TRC_ARIB_STD_B67 ? 2 : 0);
}
static void transform(FSGLESRenderer *r, int w, int h, int effects, float m[9])
{
    float x = effects ? r->rotation[0] * PI / 180 : 0, y = effects ? r->rotation[1] * PI / 180 : 0,
          z = effects ? (r->rotation[2] + r->auto_z) * PI / 180 : 0;
    float cx = cosf(x), sx = sinf(x), cy = cosf(y), sy = sinf(y), cz = cosf(z), sz = sinf(z);
    double vw = r->disp_w > 0 ? r->disp_w : r->width, vh = r->disp_h > 0 ? r->disp_h : r->height;
    if (r->sar_num > 0 && r->sar_den > 0)
        vw = vw * r->sar_num / r->sar_den;
    if (vw <= 0 || vh <= 0) {
        memcpy(m, identity, sizeof(identity));
        return;
    }
    /* Fit/fill the Z-rotated display aspect; X/Y stay orthographic effects. */
    double rw = fabs(cos(z)) * vw + fabs(sin(z)) * vh, rh = fabs(sin(z)) * vw + fabs(cos(z)) * vh;
    double k = r->mode == FS_SCALING_MODE_ASPECT_FILL ? fmax(w / rw, h / rh) : fmin(w / rw, h / rh);
    double kx = r->mode == FS_SCALING_MODE_FILL ? 1 / rw : k / w;
    double ky = r->mode == FS_SCALING_MODE_FILL ? 1 / rh : k / h;
    /* Rz*Ry*Rx in physical pixels, projected orthographically. */
    m[0] = (float)(cz * cy * vw * kx);
    m[1] = (float)(sz * cy * vw * ky);
    m[2] = 0;
    m[3] = (float)((cz * sy * sx - sz * cx) * vh * kx);
    m[4] = (float)((sz * sy * sx + cz * cx) * vh * ky);
    m[5] = 0;
    m[6] = m[7] = 0;
    m[8] = 1;
}
static void background_update(FSGLESRenderer *r)
{
    if (!r->bg_dirty)
        return;
    r->bg_dirty = 0;
    glDeleteTextures(1, &r->bg_src);
    glDeleteTextures(2, r->bg_tex);
    r->bg_src = 0;
    memset(r->bg_tex, 0, sizeof(r->bg_tex));
    if (!r->bg_pixels)
        return;
    r->bg_src = texture(r->bg_w, r->bg_h, GL_RGBA8, GL_LINEAR);
    r->bg_tex[0] = texture(r->bg_w, r->bg_h, GL_RGBA8, GL_LINEAR);
    r->bg_tex[1] = texture(r->bg_w, r->bg_h, GL_RGBA8, GL_LINEAR);
    if (!r->bg_src || !r->bg_tex[0] || !r->bg_tex[1]) {
        r->bg_dirty = 1;
        return;
    }
    glBindTexture(GL_TEXTURE_2D, r->bg_src);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, r->bg_w, r->bg_h, GL_RGBA, GL_UNSIGNED_BYTE,
                    r->bg_pixels);
    if (!r->bg_fbo)
        glGenFramebuffers(1, &r->bg_fbo);
    GLuint src = r->bg_src;
    glDisable(GL_BLEND);
    glViewport(0, 0, r->bg_w, r->bg_h);
    for (int i = 0; i < r->iterations * 2; i++) {
        glBindFramebuffer(GL_FRAMEBUFFER, r->bg_fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                               r->bg_tex[i % 2], 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            r->bg_dirty = 1;
            break;
        }
        /* Render into GL bottom-up FBO, but treat coordinates as image top-down. */
        quad(r, r->blur, NULL, full_rect, i ? 1 : 0);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, src);
        glUniform1i(U(r->blur, "image"), 0);
        glUniform2f(U(r->blur, "stepUV"), i % 2 ? 0 : 1.f / r->bg_w, i % 2 ? 1.f / r->bg_h : 0);
        glUniform1f(U(r->blur, "sigma"), r->sigma);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        src = r->bg_tex[i % 2];
    }
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
}
static void scene(FSGLESRenderer *r, GLuint fbo, int w, int h, int type)
{
    int screen = type == FS_SNAPSHOT_TYPE_SCREEN,
        effects = screen || type == FS_SNAPSHOT_TYPE_EFFECT_SUBTITLE_ORIGIN;
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glViewport(0, 0, w, h);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);
    glDisable(GL_BLEND);
    glClearColor(r->background[0], r->background[1], r->background[2], 1);
    glClear(GL_COLOR_BUFFER_BIT);
    if (screen && r->bg_tex[1] && !r->bg_dirty)
        draw_rgba(r, r->bg_tex[1], NULL, full_rect, 1);
    float m[9];
    if (effects)
        transform(r, w, h, 1, m);
    else
        memcpy(m, identity, sizeof(m));
    if (r->have_frame && r->format == AV_PIX_FMT_MEDIACODEC) {
        quad(r, r->oes, m, full_rect, 0);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_EXTERNAL_OES, r->external);
        glUniform1i(U(r->oes, "image"), 0);
        glUniformMatrix4fv(U(r->oes, "texMatrix"), 1, GL_FALSE, r->tex_matrix);
        const float neutral[3] = {1, 1, 1};
        glUniform3fv(U(r->oes, "adjust"), 1, effects ? r->adjust : neutral);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    } else if (r->have_frame) {
        GLuint p = r->video;
        quad(r, p, m, full_rect, 0);
        int ten = r->format == AV_PIX_FMT_YUV420P10LE;
        /* Integer and normalized samplers MUST use disjoint texture units even
         * for dynamically untaken branches (ES sampler validation). */
        const char *samplers[] = {"Y", "U", "V", "Y10", "U10", "V10"};
        for (int i = 0; i < 6; i++) {
            glActiveTexture(GL_TEXTURE0 + i);
            glBindTexture(GL_TEXTURE_2D, (i / 3 == ten) ? r->planes[i % 3] : 0);
            glUniform1i(U(p, samplers[i]), i);
        }
        glUniform1i(U(p, "bits"), ten ? 10 : 8);
        glUniform1i(U(p, "nv12"), r->format == AV_PIX_FMT_NV12);
        glUniform1i(U(p, "hdr"), r->hdr);
        glUniform1i(U(p, "tf"), r->tf);
        glUniformMatrix3fv(U(p, "matrix"), 1, GL_FALSE, r->matrix);
        glUniform3fv(U(p, "offset"), 1, r->offset);
        glUniform3fv(U(p, "rangeScale"), 1, r->scale);
        const float neutral[3] = {1, 1, 1};
        glUniform3fv(U(p, "adjust"), 1, effects ? r->adjust : neutral);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
    if (type != FS_SNAPSHOT_TYPE_ORIGIN && r->subtitle) {
        Tex *t = r->subtitle->opaque;
        if (t && t->r == r) {
            glEnable(GL_BLEND);
            glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
            draw_rgba(r, t->id, m, full_rect, t->flipped);
            glDisable(GL_BLEND);
        }
    }
}
static void snapshot_process(FSGLESRenderer *r)
{
    if (!r->snap_pending)
        return;
    int w = r->width, h = r->height;
    if (r->snap_type == FS_SNAPSHOT_TYPE_EFFECT_SUBTITLE_ORIGIN) {
        int quadrants = (int)(fabsf(fmodf(r->rotation[2] + r->auto_z, 360.f)) / 90.f);
        if (quadrants % 2) {
            int swap = w;
            w = h;
            h = swap;
        }
    }
    if (r->snap_type == FS_SNAPSHOT_TYPE_SCREEN && r->surface != EGL_NO_SURFACE) {
        eglQuerySurface(r->display, r->surface, EGL_WIDTH, &w);
        eglQuerySurface(r->display, r->surface, EGL_HEIGHT, &h);
    }
    GLuint tex = 0, fbo = 0;
    uint8_t *pixels = NULL, *row = NULL;
    int result = -1;
    if (!dimensions(w, h))
        goto done;
    /* Explicit readback targets are infrequent, unlike streaming video planes.
     * Older ES3 Android drivers can report immutable RGBA8 attachments incomplete;
     * use mutable RGBA storage for this temporary FBO, keeping video storage immutable. */
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    if (!tex || glGetError() != GL_NO_ERROR)
        goto done;
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    GLenum framebuffer_status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (framebuffer_status != GL_FRAMEBUFFER_COMPLETE) {
        LOGE("snapshot framebuffer incomplete: 0x%x", framebuffer_status);
        goto done;
    }
    pixels = malloc((size_t)w * h * 4);
    row = malloc((size_t)w * 4);
    if (!pixels || !row)
        goto done;
    scene(r, fbo, w, h, r->snap_type);
    GLenum scene_error = glGetError();
    if (scene_error != GL_NO_ERROR) {
        LOGE("snapshot scene failed: GL 0x%x format=%d", scene_error, r->format);
        goto done;
    }
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    GLenum read_error = glGetError();
    if (read_error != GL_NO_ERROR) {
        LOGE("snapshot readback failed: GL 0x%x format=%d", read_error, r->format);
        goto done;
    }
    for (int y = 0; y < h / 2; y++) {
        uint8_t *a = pixels + (size_t)y * w * 4, *b = pixels + (size_t)(h - 1 - y) * w * 4;
        memcpy(row, a, (size_t)w * 4);
        memcpy(a, b, (size_t)w * 4);
        memcpy(b, row, (size_t)w * 4);
    }
    result = 0;
    r->snap_pixels = pixels;
    pixels = NULL;
    r->snap_w = w;
    r->snap_h = h;
done:
    free(row);
    free(pixels);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (fbo)
        glDeleteFramebuffers(1, &fbo);
    if (tex)
        glDeleteTextures(1, &tex);
    r->snap_result = result;
    r->snap_pending = 0;
    pthread_cond_broadcast(&r->cond);
}
static void surface_failed(FSGLESRenderer *r, EGLint error)
{
    LOGE("window EGL failure: 0x%x", error);
    if (error == EGL_BAD_SURFACE || error == EGL_BAD_NATIVE_WINDOW) {
        eglDestroySurface(r->display, r->surface);
        r->surface = EGL_NO_SURFACE;
    }
}
static int present(FSGLESRenderer *r)
{
    background_update(r);
    snapshot_process(r);
    if (r->surface == EGL_NO_SURFACE)
        return 0;
    if (!eglMakeCurrent(r->display, r->surface, r->surface, r->context)) {
        surface_failed(r, eglGetError());
        return -1;
    }
    EGLint w = 0, h = 0, error = EGL_SUCCESS;
    int queried = eglQuerySurface(r->display, r->surface, EGL_WIDTH, &w) &&
                  eglQuerySurface(r->display, r->surface, EGL_HEIGHT, &h);
    if (!queried)
        error = eglGetError();
    int result = -1;
    if (queried && w > 0 && h > 0) {
        scene(r, 0, w, h, FS_SNAPSHOT_TYPE_SCREEN);
        GLenum draw_error = glGetError();
        if (draw_error == GL_NO_ERROR) {
            if (eglSwapBuffers(r->display, r->surface))
                result = 0;
            else
                error = eglGetError();
        } else {
            LOGE("scene draw failed: GL 0x%x format=%d", draw_error, r->format);
            if (r->format == AV_PIX_FMT_MEDIACODEC)
                r->mc_failed = 1;
        }
    }
    if (!eglMakeCurrent(r->display, r->pbuffer, r->pbuffer, r->context))
        result = -1;
    if (error != EGL_SUCCESS)
        surface_failed(r, error);
    return result;
}
int fs_gles_renderer_display(FSGLESRenderer *r, const AVFrame *frame, int dw, int dh, int rotate,
                             int sn, int sd)
{
    if (!frame || !dimensions(frame->width, frame->height) || !enter(r))
        return -1;
    const AVFrame *f = frame;
    int ret = -1;
    if (f->format == AV_PIX_FMT_MEDIACODEC) {
        if (mc_upload(r, f))
            goto done;
        r->hdr = r->tf = 0; /* Android converts SDR YUV -> RGB while sampling OES. */
        goto uploaded;
    }
    if (f->format != AV_PIX_FMT_YUV420P && f->format != AV_PIX_FMT_YUVJ420P &&
        f->format != AV_PIX_FMT_YUV420P10LE && f->format != AV_PIX_FMT_NV12) {
        /* Hardware AVFrames cannot be dereferenced by swscale. */
        if (f->hw_frames_ctx)
            goto done;
        if (!r->converted)
            r->converted = av_frame_alloc();
        if (!r->converted)
            goto done;
        av_frame_unref(r->converted);
        r->converted->format = AV_PIX_FMT_YUV420P;
        r->converted->width = f->width;
        r->converted->height = f->height;
        if (av_frame_get_buffer(r->converted, 32) < 0)
            goto done;
        r->sws = sws_getCachedContext(r->sws, f->width, f->height, f->format, f->width, f->height,
                                      AV_PIX_FMT_YUV420P, SWS_BILINEAR, NULL, NULL, NULL);
        if (!r->sws)
            goto done;
        int cs = f->colorspace == AVCOL_SPC_BT709
                     ? SWS_CS_ITU709
                     : (f->colorspace == AVCOL_SPC_BT2020_NCL ? SWS_CS_BT2020 : SWS_CS_ITU601);
        const int *coeff = sws_getCoefficients(cs);
        int full = f->color_range == AVCOL_RANGE_JPEG;
        sws_setColorspaceDetails(r->sws, coeff, full, coeff, full, 0, 1 << 16, 1 << 16);
        if (sws_scale(r->sws, (const uint8_t *const *)f->data, f->linesize, 0, f->height,
                      r->converted->data, r->converted->linesize) != f->height)
            goto done;
        if (av_frame_copy_props(r->converted, f) < 0)
            goto done;
        f = r->converted;
    }
    if (upload(r, f))
        goto done;
    color_metadata(r, f);
uploaded:
    r->disp_w = dw;
    r->disp_h = dh;
    r->auto_z = rotate % 360;
    r->sar_num = sn;
    r->sar_den = sd;
    ret = present(r);
done:
    leave(r);
    return ret;
}
int fs_gles_renderer_display_sub_overlay(FSGLESRenderer *r)
{
    if (!enter(r))
        return -1;
    int ret = present(r);
    leave(r);
    return ret;
}
void fs_gles_renderer_set_sub_overlay(FSGLESRenderer *r, SDL_TextureOverlay *o)
{
    if (!r)
        return;
    pthread_mutex_lock(&r->mutex);
    if (!r->dead && (!o || (o->getTexture == tex_get && o->opaque && ((Tex *)o->opaque)->r == r))) {
        SDL_TextureOverlay *old = r->subtitle;
        r->subtitle = SDL_TextureOverlay_Retain(o);
        SDL_TextureOverlay_Release(&old);
    }
    pthread_mutex_unlock(&r->mutex);
}
SDL_TextureOverlay *fs_gles_renderer_get_sub_overlay(FSGLESRenderer *r)
{
    if (!r)
        return NULL;
    pthread_mutex_lock(&r->mutex);
    SDL_TextureOverlay *o = SDL_TextureOverlay_Retain(r->subtitle);
    pthread_mutex_unlock(&r->mutex);
    return o;
}
int fs_gles_renderer_take_snapshot(FSGLESRenderer *r, int type, int *w, int *h, void **pixels)
{
    if (!r || !w || !h || !pixels || type < 0 || type > 3)
        return -1;
    *pixels = NULL;
    *w = *h = 0;
    pthread_mutex_lock(&r->mutex);
    if (r->dead || r->snap_busy || !r->have_frame) {
        pthread_mutex_unlock(&r->mutex);
        return -1;
    }
    ref(r);
    r->snap_busy = 1;
    r->snap_type = type;
    r->snap_pending = 1;
    r->snap_result = -1;
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_sec += 3;
    while (r->snap_pending && !r->dead) {
        int e = pthread_cond_timedwait(&r->cond, &r->mutex, &until);
        if (e == ETIMEDOUT) {
            r->snap_pending = 0;
            break;
        }
    }
    int ret = r->snap_result;
    if (!ret) {
        *pixels = r->snap_pixels;
        *w = r->snap_w;
        *h = r->snap_h;
        r->snap_pixels = NULL;
    }
    r->snap_busy = 0;
    pthread_mutex_unlock(&r->mutex);
    unref(r);
    return ret;
}
void fs_gles_renderer_set_background_image(FSGLESRenderer *r, const void *p, int w, int h)
{
    if (!r)
        return;
    uint8_t *copy = NULL;
    if (p) {
        if (!dimensions(w, h))
            return;
        copy = malloc((size_t)w * h * 4);
        if (!copy)
            return;
        memcpy(copy, p, (size_t)w * h * 4);
    }
    pthread_mutex_lock(&r->mutex);
    free(r->bg_pixels);
    r->bg_pixels = copy;
    r->bg_w = w;
    r->bg_h = h;
    r->bg_dirty = 1;
    pthread_mutex_unlock(&r->mutex);
}
void fs_gles_renderer_set_background_blur(FSGLESRenderer *r, int count, float sigma)
{
    if (!r)
        return;
    pthread_mutex_lock(&r->mutex);
    r->iterations = count < 1 ? 1 : (count > 32 ? 32 : count);
    r->sigma = isfinite(sigma) && sigma > 0 ? fminf(sigma, 64) : 30;
    r->bg_dirty = 1;
    pthread_mutex_unlock(&r->mutex);
}
void fs_gles_renderer_set_color_adjust(FSGLESRenderer *r, float b, float s, float c)
{
    if (!r || !isfinite(b) || !isfinite(s) || !isfinite(c))
        return;
    pthread_mutex_lock(&r->mutex);
    r->adjust[0] = b;
    r->adjust[1] = s;
    r->adjust[2] = c;
    pthread_mutex_unlock(&r->mutex);
}
void fs_gles_renderer_set_background_color(FSGLESRenderer *r, int red, int green, int blue)
{
    if (!r)
        return;
    int v[3] = {red, green, blue};
    pthread_mutex_lock(&r->mutex);
    for (int i = 0; i < 3; i++)
        r->background[i] = (v[i] < 0 ? 0 : (v[i] > 255 ? 255 : v[i])) / 255.f;
    pthread_mutex_unlock(&r->mutex);
}
void fs_gles_renderer_set_scaling_mode(FSGLESRenderer *r, int mode)
{
    if (!r)
        return;
    pthread_mutex_lock(&r->mutex);
    r->mode = mode >= 0 && mode <= 2 ? mode : 0;
    pthread_mutex_unlock(&r->mutex);
}
int fs_gles_renderer_get_scaling_mode(FSGLESRenderer *r)
{
    if (!r)
        return 0;
    pthread_mutex_lock(&r->mutex);
    int mode = r->mode;
    pthread_mutex_unlock(&r->mutex);
    return mode;
}
void fs_gles_renderer_set_rotate_degrees(FSGLESRenderer *r, float x, float y, float z)
{
    if (!r || !isfinite(x) || !isfinite(y) || !isfinite(z))
        return;
    pthread_mutex_lock(&r->mutex);
    r->rotation[0] = fmodf(x, 360.f);
    r->rotation[1] = fmodf(y, 360.f);
    r->rotation[2] = fmodf(z, 360.f);
    pthread_mutex_unlock(&r->mutex);
}
void fs_gles_renderer_set_allow_hdr_display(FSGLESRenderer *r, int allow)
{
    if (!r)
        return;
    pthread_mutex_lock(&r->mutex);
    r->allow_hdr = !!allow;
    pthread_mutex_unlock(&r->mutex);
}
int fs_gles_renderer_is_hdr_content(FSGLESRenderer *r)
{
    if (!r)
        return 0;
    pthread_mutex_lock(&r->mutex);
    int hdr = r->hdr;
    pthread_mutex_unlock(&r->mutex);
    return hdr;
}
int fs_gles_renderer_is_hdr_display_active(FSGLESRenderer *r)
{
    (void)r;
    return 0;
}
int fs_gles_renderer_is_mediacodec_supported(FSGLESRenderer *r)
{
    int supported = 0;
    if (!r) return 0;
    pthread_mutex_lock(&r->mutex);
#ifdef FS_GLES_ANDROID_CODEC
    supported = !r->dead && !r->mc_failed && r->oes && r->mc_surface;
#endif
    pthread_mutex_unlock(&r->mutex);
    return supported;
}
jobject fs_gles_renderer_get_mediacodec_surface(JNIEnv *env, FSGLESRenderer *r)
{
    if (!env || !r) return NULL;
    jobject surface = NULL;
    pthread_mutex_lock(&r->mutex);
#ifdef FS_GLES_ANDROID_CODEC
    if (!r->dead && !r->mc_failed && r->mc_surface) {
        surface = (*env)->NewLocalRef(env, r->mc_surface);
        if (mc_exception(env, "surface local ref")) surface = NULL;
    }
#endif
    pthread_mutex_unlock(&r->mutex);
    return surface;
}
void fs_gles_renderer_destroy(FSGLESRenderer *r)
{
    if (!r)
        return;
    pthread_mutex_lock(&r->mutex);
    if (r->dead) {
        pthread_mutex_unlock(&r->mutex);
        return;
    }
    SDL_TextureOverlay_Release(&r->subtitle);
    fs_gles_renderer_detach_gpu(r);
    LOGI("renderer totals: oes_frames=%lu cpu_uploads=%lu", r->oes_frames, r->cpu_uploads);
    av_frame_free(&r->mc_last);
    mc_cleanup(r);
    if (r->context != EGL_NO_CONTEXT && r->pbuffer != EGL_NO_SURFACE &&
        eglMakeCurrent(r->display, r->pbuffer, r->pbuffer, r->context)) {
        for (int i = 0; i < RING; i++)
            if (r->fences[i])
                glDeleteSync(r->fences[i]);
        glDeleteBuffers(RING, r->pbo);
        glDeleteBuffers(1, &r->vbo);
        glDeleteVertexArrays(1, &r->vao);
        glDeleteTextures(3, r->planes);
        glDeleteTextures(1, &r->external);
        if (r->oes)
            glDeleteProgram(r->oes);
        glDeleteTextures(1, &r->bg_src);
        glDeleteTextures(2, r->bg_tex);
        glDeleteFramebuffers(1, &r->bg_fbo);
        if (r->video)
            glDeleteProgram(r->video);
        if (r->rgba)
            glDeleteProgram(r->rgba);
        if (r->blur)
            glDeleteProgram(r->blur);
        eglMakeCurrent(r->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
    if (r->surface != EGL_NO_SURFACE)
        eglDestroySurface(r->display, r->surface);
    if (r->pbuffer != EGL_NO_SURFACE)
        eglDestroySurface(r->display, r->pbuffer);
    if (r->context != EGL_NO_CONTEXT)
        eglDestroyContext(r->display, r->context);
    display_release(r->display);
    if (r->window)
        ANativeWindow_release(r->window);
    r->dead = 1;
    r->context = EGL_NO_CONTEXT;
    r->snap_pending = 0;
    r->snap_result = -1;
    pthread_cond_broadcast(&r->cond);
    free(r->bg_pixels);
    free(r->snap_pixels);
    r->snap_pixels = NULL;
    sws_freeContext(r->sws);
    av_frame_free(&r->converted);
    pthread_mutex_unlock(&r->mutex);
    unref(r);
}
