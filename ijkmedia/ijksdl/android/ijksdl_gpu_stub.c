/*****************************************************************************
 * ijksdl_gpu_stub.c
 *****************************************************************************
 *
 * Android Vulkan 构建的 SDL_GPU 层桩实现。
 *
 * fsplayer 的 SDL_GPU（SDL_TextureOverlay / SDL_FBOOverlay / SDL_GPU）是
 * 字幕渲染用的 OpenGL 纹理层，实现位于 apple/ijksdl_vout_ios_gles2.m，
 * 安卓 Vulkan 渲染器不包含 OpenGL，故 ffp->gpu 保持为 NULL，字幕功能静默
 * 禁用（ff_sub_upload_texture 在 gpu 为 NULL 时直接返回 -1）。
 *
 * 这里只提供引用计数与释放函数的最小实现，保证链接通过且对 NULL 安全。
 *****************************************************************************/

#include "ijksdl/ijksdl_gpu.h"
#include <stdlib.h>

SDL_TextureOverlay *SDL_TextureOverlay_Retain(SDL_TextureOverlay *t)
{
    if (t)
        t->refCount++;
    return t;
}

void SDL_TextureOverlay_Release(SDL_TextureOverlay **tp)
{
    if (!tp || !*tp)
        return;

    SDL_TextureOverlay *t = *tp;
    if (--t->refCount <= 0) {
        if (t->dealloc)
            t->dealloc(t);
        free(t);
    }
    *tp = NULL;
}

void SDL_FBOOverlayFreeP(SDL_FBOOverlay **poverlay)
{
    if (!poverlay || !*poverlay)
        return;

    SDL_FBOOverlay *o = *poverlay;
    if (o->dealloc)
        o->dealloc(o);
    free(o);
    *poverlay = NULL;
}

void SDL_GPUFreeP(SDL_GPU **pgpu)
{
    if (!pgpu || !*pgpu)
        return;

    SDL_GPU *g = *pgpu;
    if (g->dealloc)
        g->dealloc(g);
    free(g);
    *pgpu = NULL;
}

void SaveIMGToFile(uint8_t *data, int width, int height, IMG_FORMAT format, char *tag, int pts)
{
    (void)data; (void)width; (void)height; (void)format; (void)tag; (void)pts;
}

// gprof 性能分析（ijkplayer-cmake 的 prof.c），安卓最小可播放不需要，空实现
void monstartup(const char *libname)
{
    (void)libname;
}

void moncleanup(void)
{
}
