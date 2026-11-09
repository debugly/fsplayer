#!/usr/bin/env python3
"""Host-native tests of the REAL Android vout wrapper, with stub GPU/JNI APIs.

Run: python3 ijkmedia/wrapper/android/tests/test_video_renderer_native.py
No emulator/Gradle needed. This is not a real EGL/Vulkan integration test.
The production C body is compiled unchanged except for platform includes;
backend prototypes come from the real headers. Stub backends let us inject
creation/surface errors and observe lazy creation and cached setter replay.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
SDL = ROOT / "ijkmedia/ijksdl/android"
PRELUDE = r'''
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#define PROP_VALUE_MAX 92
#define IS_TILEGRID_HEIC_ENABLED 0
#define ALOGI(...) ((void)0)
#define ALOGE(...) ((void)0)
#define ALOGW(...) ((void)0)
#define ALOGV(...) ((void)0)
#define AVERROR(e) (-(e))
typedef void JNIEnv;
typedef void *jobject;
typedef struct ANativeWindow { int refs; } ANativeWindow;
typedef struct SDL_GPU { int detached; } SDL_GPU;
typedef struct SDL_TextureOverlay { int unused; } SDL_TextureOverlay;
typedef struct FSVulkanContext { int unused; } FSVulkanContext;
typedef struct Backend {
    int scale, bg[3], hdr, iterations, image_byte, image_w, image_h;
    float x,y,z,brightness,saturation,contrast,sigma;
    ANativeWindow *window;
} Backend;
typedef Backend FSGLESRenderer;
typedef Backend FSVulkanRenderer;
typedef struct AVFrame { int width,height; } AVFrame;
typedef struct SDL_VoutOverlay { int unused; } SDL_VoutOverlay;
typedef struct Frame { AVFrame *frame; int disp_w,disp_h,auto_z_rotate_degrees;
    struct { int num,den; } sar; } Frame;
typedef struct SDL_Vout_Opaque SDL_Vout_Opaque;
typedef struct SDL_Vout SDL_Vout;
struct SDL_Vout {
    SDL_Vout_Opaque *opaque; void *mutex;
    SDL_VoutOverlay *(*create_overlay)(int,int,int,SDL_Vout*);
    void (*free_l)(SDL_Vout*);
    int (*display_overlay)(SDL_Vout*,const Frame*,SDL_TextureOverlay*);
};
static int gles_creates, vk_creates, fail_gles, fail_vk, fail_surface, fail_vk_surface;
static int gpu_shells, gpu_detaches, destroys;
static int has_ahb = 1;
static char debug_backend[92] = "", sdk[92] = "28";
static SDL_GPU gpu_pool[128];
static int __system_property_get(const char *key,char *out) {
    strcpy(out,!strcmp(key,"ro.build.version.sdk")?sdk:debug_backend);
    return (int)strlen(out);
}
static void SDL_LockMutex(void *m) {(void)m;}
static void SDL_UnlockMutex(void *m) {(void)m;}
static SDL_Vout *SDL_Vout_CreateInternal(size_t size) {
    SDL_Vout *v=calloc(1,sizeof(*v)); v->opaque=calloc(1,size); return v;
}
static void SDL_Vout_FreeInternal(SDL_Vout *v) {free(v->opaque);free(v);}
static void ANativeWindow_release(ANativeWindow *w) {assert(w->refs>0);w->refs--;}
static ANativeWindow *ANativeWindow_fromSurface(JNIEnv *e,jobject s) {
    (void)e; ANativeWindow *w=s; if(w)w->refs++;return w;
}
static SDL_VoutOverlay *SDL_VoutFFmpeg_CreateOverlay(int a,int b,int c,SDL_Vout *v) {
    (void)a;(void)b;(void)c;(void)v;return NULL;
}
static SDL_GPU *SDL_VulkanGPU_Create(const FSVulkanContext *c) {
    (void)c; return &gpu_pool[gpu_shells++];
}
static void SDL_VulkanGPU_DetachDevice(SDL_GPU *g) {g->detached++;gpu_detaches++;}
static void SDL_GPUFreeP(SDL_GPU **g) { *g = NULL; }
'''


def backend_stubs():
    result = []
    for header, backend in [(SDL / "gles3/fs_gles_renderer.h", "gles"),
                            (SDL / "vulkan/fs_vulkan_renderer.h", "vulkan")]:
        text = re.sub(r"/\*.*?\*/", "", header.read_text(), flags=re.S)
        for m in re.finditer(r"([\w\s*]+\b(fs_(?:gles|vulkan)_renderer_\w+)\s*\([^;{}]*\));", text):
            proto, name = m.group(1).strip(), m.group(2)
            proto = proto[proto.rfind("\n#endif") + len("\n#endif"):] if "\n#endif" in proto else proto
            suffix = name.split("_renderer_")[1]
            body = "return 0;" if not proto.startswith("void ") else ""
            if suffix == "create":
                body = ("gles_creates++; if(fail_gles)return NULL;" if backend == "gles" else
                        "vk_creates++; if(fail_vk)return NULL;") + "return calloc(1,sizeof(Backend));"
            elif suffix == "destroy": body = "if(r){destroys++;free(r);}"
            elif suffix == "is_ahb_supported": body = "return r && has_ahb;"
            elif suffix == "get_gpu": body = "(void)r;return &gpu_pool[gpu_shells++];"
            elif suffix == "detach_gpu": body = "(void)r;gpu_detaches++;"
            elif suffix == "context": body = "(void)r;return NULL;"
            elif suffix == "set_surface":
                body = "assert(r);r->window=window;return (fail_surface" + (
                    "||fail_vk_surface" if backend == "vulkan" else "") + ")?-EIO:0;"
            elif suffix == "set_scaling_mode": body = "r->scale=mode;"
            elif suffix == "set_rotate_degrees": body = "r->x=x;r->y=y;r->z=z;"
            elif suffix == "set_color_adjust": body = "r->brightness=brightness;r->saturation=saturation;r->contrast=contrast;"
            elif suffix == "set_background_color": body = "r->bg[0]=red;r->bg[1]=green;r->bg[2]=blue;"
            elif suffix == "set_background_blur": body = "r->iterations=iterations;r->sigma=sigma;"
            elif suffix == "set_allow_hdr_display": body = "r->hdr=allow;"
            elif suffix == "set_background_image": body = "r->image_byte=pixels?*(const unsigned char*)pixels:-1;r->image_w=width;r->image_h=height;"
            result.append(proto + " {" + body + "}\n")
    return "\n".join(result)


TESTS = r'''
int main(void) {
    SDL_Vout *v = SDL_VoutAndroid_CreateForAndroid();
    assert(v);
    /* Regression: old constructor eagerly chose a global backend. */
    assert(gles_creates == 0 && vk_creates == 0);
    v->free_l(v);
    puts("PASS: inert constructor/release before prepare");

    strcpy(debug_backend, "vulkan");
    v = SDL_VoutAndroid_CreateForAndroid();
    ANativeWindow window = {0};
    SDL_VoutAndroid_SetAndroidSurface(NULL, v, &window);
    SDL_VoutAndroid_SetScalingMode(v, 2);
    SDL_VoutAndroid_SetRotateDegrees(v, 12, 23, 34);
    SDL_VoutAndroid_SetColorAdjust(v, .8f, .7f, .6f);
    SDL_VoutAndroid_SetBackgroundColor(v, 10, 20, 30);
    SDL_VoutAndroid_SetBackgroundBlur(v, 4, 12);
    SDL_VoutAndroid_SetAllowHDRDirectDisplay(v, 0);
    unsigned char pixel[4] = {19, 2, 3, 4};
    SDL_VoutAndroid_SetBackgroundImage(v, pixel, 1, 1);
    pixel[0] = 99;
    assert(SDL_VoutAndroid_GetRendererType(v) == 0);
    int old_vk = vk_creates;
    assert(SDL_VoutAndroid_PrepareRenderer(v, SDL_ANDROID_RENDERER_OPENGL) == 0);
    assert(vk_creates == old_vk); /* Explicit player option beats debug property. */
    assert(SDL_VoutAndroid_GetRendererType(v) == 1);
    Backend *gl = v->opaque->gles;
    assert(gl && gl->scale == 2 && gl->x == 12 && gl->y == 23 && gl->z == 34);
    assert(gl->brightness == .8f && gl->saturation == .7f && gl->contrast == .6f);
    assert(gl->bg[0] == 10 && gl->bg[1] == 20 && gl->bg[2] == 30);
    assert(gl->iterations == 4 && gl->sigma == 12 && gl->hdr == 0);
    assert(gl->image_byte == 19 && gl->image_w == 1 && gl->image_h == 1);
    assert(gl->window == &window && window.refs == 1);
    int old_gl = gles_creates;
    assert(SDL_VoutAndroid_PrepareRenderer(v, 0) == 0);
    assert(gles_creates == old_gl); /* Reset/stop does not recreate a context. */
    assert(SDL_VoutAndroid_PrepareRenderer(v, 2) < 0);
    assert(SDL_VoutAndroid_GetRendererType(v) == 1);
    v->free_l(v);
    assert(window.refs == 0);
    puts("PASS: per-player override, cached setters/image copy/surface replay, reset retention");

    debug_backend[0] = 0;
    strcpy(sdk, "28");
    v = SDL_VoutAndroid_CreateForAndroid();
    assert(SDL_VoutAndroid_PrepareRenderer(v, 0) == 0);
    assert(SDL_VoutAndroid_GetRendererType(v) == 2);
    SDL_Vout *other = SDL_VoutAndroid_CreateForAndroid();
    assert(SDL_VoutAndroid_PrepareRenderer(other, 1) == 0);
    assert(SDL_VoutAndroid_GetRendererType(other) == 1);
    assert(SDL_VoutAndroid_GetRendererType(v) == 2);
    other->free_l(other); v->free_l(v);
    puts("PASS: auto Vulkan policy and simultaneous per-instance isolation");

    has_ahb = 0;
    v = SDL_VoutAndroid_CreateForAndroid();
    SDL_VoutAndroid_SetAndroidSurface(NULL, v, &window);
    SDL_VoutAndroid_SetScalingMode(v, 2);
    int before_destroy = destroys;
    assert(SDL_VoutAndroid_PrepareRenderer(v, 0) == 0);
    assert(SDL_VoutAndroid_GetRendererType(v) == 1);
    assert(!v->opaque->renderer && v->opaque->gles->window == &window);
    assert(v->opaque->gles->scale == 2 && destroys == before_destroy + 1);
    v->free_l(v); assert(window.refs == 0);
    v = SDL_VoutAndroid_CreateForAndroid();
    assert(SDL_VoutAndroid_PrepareRenderer(v, 2) == 0);
    assert(SDL_VoutAndroid_GetRendererType(v) == 2); /* Explicit Vulkan may upload software frames. */
    v->free_l(v);
    strcpy(debug_backend, "vulkan");
    v = SDL_VoutAndroid_CreateForAndroid();
    assert(SDL_VoutAndroid_PrepareRenderer(v, 0) == 0);
    assert(SDL_VoutAndroid_GetRendererType(v) == 1); /* Request is still auto, even with a diagnostic override. */
    v->free_l(v); debug_backend[0] = 0; has_ahb = 1;
    puts("PASS: auto without AHB rolls Vulkan back to ES3; explicit Vulkan remains Vulkan");

    fail_vk = 1;
    v = SDL_VoutAndroid_CreateForAndroid();
    assert(SDL_VoutAndroid_PrepareRenderer(v, 0) == 0);
    assert(SDL_VoutAndroid_GetRendererType(v) == 1);
    v->free_l(v);
    v = SDL_VoutAndroid_CreateForAndroid(); old_gl = gles_creates;
    assert(SDL_VoutAndroid_PrepareRenderer(v, 2) == 0);
    assert(SDL_VoutAndroid_GetRendererType(v) == 1 && gles_creates == old_gl + 1);
    old_gl = gles_creates;
    assert(SDL_VoutAndroid_PrepareRenderer(v, 2) == 0);
    assert(gles_creates == old_gl); /* Retain the successful fallback for reprepare. */
    v->free_l(v); fail_vk = 0;
    strcpy(sdk, "21");
    v = SDL_VoutAndroid_CreateForAndroid(); old_vk = vk_creates;
    assert(SDL_VoutAndroid_PrepareRenderer(v, 2) == 0);
    assert(vk_creates == old_vk && SDL_VoutAndroid_GetRendererType(v) == 1);
    assert(SDL_VoutAndroid_PrepareRenderer(v, 0) == 0);
    assert(SDL_VoutAndroid_GetRendererType(v) == 1);
    v->free_l(v);
    puts("PASS: explicit Vulkan and auto fall back to ES3; fallback survives reprepare");

    strcpy(sdk, "28"); fail_vk_surface = 1;
    v = SDL_VoutAndroid_CreateForAndroid();
    SDL_VoutAndroid_SetAndroidSurface(NULL, v, &window);
    SDL_VoutAndroid_SetScalingMode(v, 2);
    pixel[0] = 17;
    SDL_VoutAndroid_SetBackgroundImage(v, pixel, 1, 1);
    pixel[0] = 99;
    int old_detaches = gpu_detaches;
    assert(SDL_VoutAndroid_PrepareRenderer(v, 2) == 0);
    assert(!v->opaque->renderer && v->opaque->gles);
    assert(v->opaque->gles->window == &window && window.refs == 1);
    assert(v->opaque->gles->scale == 2 && v->opaque->gles->image_byte == 17);
    assert(gpu_detaches == old_detaches + 1);
    v->free_l(v); fail_vk_surface = 0;
    assert(window.refs == 0);
    fail_gles = fail_vk = 1;
    v = SDL_VoutAndroid_CreateForAndroid();
    assert(SDL_VoutAndroid_PrepareRenderer(v, 2) < 0);
    assert(SDL_VoutAndroid_GetRendererType(v) == 0 && !v->opaque->gpu);
    v->free_l(v); fail_gles = fail_vk = 0;
    puts("PASS: partial Vulkan surface/GPU rollback and cached-state replay to ES3; total failure stays unknown");

    v = SDL_VoutAndroid_CreateForAndroid(); fail_surface = 1;
    assert(SDL_VoutAndroid_PrepareRenderer(v, 1) < 0);
    assert(SDL_VoutAndroid_GetRendererType(v) == 0 && !v->opaque->gpu);
    fail_surface = 0;
    assert(SDL_VoutAndroid_PrepareRenderer(v, 1) == 0);
    assert(SDL_VoutAndroid_GetRendererType(v) == 1);
    v->free_l(v);
    v = SDL_VoutAndroid_CreateForAndroid();
    old_gl = gles_creates; old_vk = vk_creates;
    assert(SDL_VoutAndroid_PrepareRenderer(v, -1) < 0);
    assert(SDL_VoutAndroid_PrepareRenderer(v, 3) < 0);
    assert(gles_creates == old_gl && vk_creates == old_vk);
    v->free_l(v);
    puts("PASS: failed surface rollback/retry and invalid enum rejection");
    return 0;
}
'''


def main():
    source = (SDL / "ijksdl_vout_android_vulkan.c").read_text()
    source = re.sub(r'^\s*#include[^\n]*', '', source, flags=re.M)
    header = (SDL / "ijksdl_vout_android_vulkan.h").read_text()
    header = re.sub(r'^\s*#include[^\n]*', '', header, flags=re.M)
    scratch = Path(os.environ.get("TMPDIR", str(Path.home() / ".hermes/cache/scratch")))
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="renderer-native-", dir=scratch) as tmp:
        c = Path(tmp) / "test.c"
        c.write_text(PRELUDE + backend_stubs() + header + source + TESTS)
        exe = Path(tmp) / "test"
        subprocess.run(["cc", "-std=c11", "-g", "-fsanitize=address,undefined", str(c), "-o", str(exe)], check=True)
        subprocess.run([str(exe)], check=True)


if __name__ == "__main__":
    main()
