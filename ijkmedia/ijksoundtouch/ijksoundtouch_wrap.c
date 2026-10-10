/*
 * ijksoundtouch_wrap.c  —— 安卓最小可播放存根
 *
 * fsplayer 删除了 SoundTouch 库，但 FFPlayer 仍保留 soundtouch_enable 字段
 * 和音频变速调用点。这里提供空实现：create 返回 NULL，使 ff_ffplay.c 里
 * "is->handle != NULL" 的判断自然失效，变速播放功能禁用（默认 soundtouch_enable=0）。
 */

#include "ijksoundtouch_wrap.h"

#include <stddef.h>

void* ijk_soundtouch_create()
{
    return NULL;
}

int ijk_soundtouch_translate(void *handle, short* data, float speed, float pitch,
                             int len, int bytes_per_sample, int n_channel, int n_sampleRate)
{
    (void)handle;
    (void)data;
    (void)speed;
    (void)pitch;
    (void)len;
    (void)bytes_per_sample;
    (void)n_channel;
    (void)n_sampleRate;
    return 0;
}

void ijk_soundtouch_destroy(void *handle)
{
    (void)handle;
}
