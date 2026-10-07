/*****************************************************************************
 * ijksdl_gpu_stub.c
 *****************************************************************************
 *
 * Android 构建剩下的零碎桩函数。
 *
 * SDL_GPU（SDL_TextureOverlay / SDL_FBOOverlay / SDL_GPU）的真正实现是
 * vulkan/ijksdl_gpu_vulkan.c（apple 侧是 ijksdl_gpu_metal.m），
 * 引用计数与释放函数也在那里，这里只留保存图片与 gprof 的空实现。
 *****************************************************************************/

#include "ijksdl/ijksdl_gpu.h"
#include <stdlib.h>

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
