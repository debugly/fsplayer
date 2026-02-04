#include "libavutil/opt.h"
#include "libavutil/time.h"
#include "libavutil/avstring.h"
#include "libavutil/mem.h"
#include "libavformat/url.h"
#include <libavutil/thread.h>

//情况通常下音视频数据是交织（Interleaving）排列的。但是个别视频从 Range 请求看，FFmpeg 正在 19MB 和 28MB 两个地址段之间疯狂“横跳”。
//因此在 FFmpeg/http 层面实现一个针对「横跳」优化的缓存层，核心思路是实现一个 Read-Ahead Sliding Window（预读滑动窗口）。
//当 FFmpeg 请求 Offset A 时，底层实际驱动 HTTP 请求 A 到 A + 4x 的数据并缓存在内存中。
//当 FFmpeg 请求 Offset B 时，底层实际驱动 HTTP 请求 B 到 B + 4x 的数据并缓存在内存中。

#define BLOCK_SIZE (200 * 1024)      // 每块 200 KB
#define MAX_BLOCKS 10                // 总缓存块数 10 * 200KB
#define PREFETCH_DEPTH 4             // 空闲时往后预加载 4 个块

#define HPL_LOG(fmt,...) do { av_log(NULL, AV_LOG_DEBUG, fmt,__VA_ARGS__);  }while(0)

typedef struct HttpPreload {
    uint8_t *data;
    int size;            // 块内当前有效数据长度
    int64_t range_start; // 块在文件中的起始字节位置
    int64_t last_used;   // 用于 LRU 的时间戳
} HttpPreload;

typedef struct HttpPreloadContext {
    const AVClass *class;
    URLContext *inner;
    HttpPreload blocks[MAX_BLOCKS];
    int64_t logical_pos;
    int64_t total_size;
    
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    pthread_t worker_thread;
    int eof;             // 是否触发文件末尾
    int abort_request;
} HttpPreloadContext;

// 查找命中的缓存块
static HttpPreload* find_hit_block(HttpPreloadContext *c, int64_t pos) {
    for (int i = 0; i < MAX_BLOCKS; i++) {
        HttpPreload *b = &c->blocks[i];
        // 判断逻辑位置是否落在 [range_start, range_start + size) 区间
        if (b->size > 0 && pos >= b->range_start && pos < b->range_start + b->size) {
            return b;
        }
    }
    return NULL;
}

// 查找 LRU 块用于替换
static HttpPreload* find_lru_block(HttpPreloadContext *c) {
    HttpPreload *lru_block = &c->blocks[0];
    for (int i = 0; i < MAX_BLOCKS; i++) {
        // 只要发现任何一个块是空的，立刻返回并使用它
        if (c->blocks[i].size == 0) return &c->blocks[i];
        
        // 否则寻找时间戳最小（最久未访问）的块
        if (c->blocks[i].last_used < lru_block->last_used) {
            lru_block = &c->blocks[i];
        }
    }
    return lru_block;
}

static void *worker_thread(void *arg) {
    URLContext *h = arg;
    HttpPreloadContext *c = h->priv_data;

    while (1) {
        pthread_mutex_lock(&c->mutex);
        while (!c->abort_request) {
            HttpPreload *target = NULL;
            int64_t fetch_pos = -1;
            
            // 1. 永远优先处理 Reader 当前正在等待的位置
            int64_t cur_pos = c->logical_pos;
            target = find_hit_block(c, cur_pos);
            
            if (!target) {
                // 情况 A: 当前位置完全没缓存，强制分配 LRU 块并从对齐位开始读
                target = find_lru_block(c);
                target->range_start = cur_pos;
                target->size = 0;
                fetch_pos = cur_pos;
                HPL_LOG("Preload:no cache,fetching from %lld\n", fetch_pos);
            } else if (!c->eof && target->size < BLOCK_SIZE) {
                // 情况 B: 块存在但没填满
                fetch_pos = target->range_start + target->size;
                HPL_LOG("Preload:%lld block not full, fetching from %lld\n", cur_pos, fetch_pos);
            } else {
                HPL_LOG("Preload:%lld block is full\n", cur_pos);
                // 情况 C: 当前块满了，尝试预加载后续块
                for (int i = 1; i <= PREFETCH_DEPTH; i++) {
                    int64_t next_pos = cur_pos + (i * BLOCK_SIZE);
                    if (c->total_size > 0 && next_pos >= c->total_size) break;
                    if (!find_hit_block(c, next_pos)) {
                        target = find_lru_block(c);
                        target->range_start = next_pos;
                        target->size = 0;
                        fetch_pos = next_pos;
                        HPL_LOG("Preload:perfetch %lld block, fetching from %lld\n", next_pos, fetch_pos);
                        break;
                    }
                }
            }

            // 检查 fetch_pos 有效性
            if (fetch_pos != -1 && (c->total_size <= 0 || fetch_pos < c->total_size)) {
                // 释放锁进行 IO
                int write_offset = target->size;
                int max_read = BLOCK_SIZE - target->size;
               
                pthread_mutex_unlock(&c->mutex);
                
                // ！！注意：ffurl_seek 必须在无锁下执行
                ffurl_seek(c->inner, fetch_pos, SEEK_SET);
                int ret = ffurl_read(c->inner, target->data + write_offset, max_read);
                HPL_LOG("Preload:ffurl want read: %d,real read: %d\n", max_read, ret);
                pthread_mutex_lock(&c->mutex);
                if (ret > 0) {
                    target->size += ret;
                    target->last_used = av_gettime();
                    pthread_cond_broadcast(&c->cond); // 唤醒 Reader
                } else if (ret == AVERROR_EOF || ret == 0) {
                    c->eof = 1;
                    pthread_cond_broadcast(&c->cond);
                }
                // 填充完一次后，不 wait，直接进入下一轮检查（可能还要填当前块或预加载）
                continue;
            }

            // 真的没事干了，睡吧
            pthread_cond_wait(&c->cond, &c->mutex);
        }
        if (c->abort_request) {
            pthread_mutex_unlock(&c->mutex);
            break;
        }
    }
    return NULL;
}

static int read(URLContext *h, unsigned char *buf, int size) {
    HttpPreloadContext *c = h->priv_data;
    pthread_mutex_lock(&c->mutex);

    if (c->total_size > 0 && c->logical_pos >= c->total_size) {
        HPL_LOG("Preload:Reader reached EOF at pos %lld\n", c->logical_pos);
        pthread_mutex_unlock(&c->mutex);
        return AVERROR_EOF;
    }

    while (1) {
        HttpPreload *b = find_hit_block(c, c->logical_pos);
        
        if (b) {
            int64_t relative_offset = c->logical_pos - b->range_start;
            int avail = b->size - (int)relative_offset;
            
            int copy_size = FFMIN(size, avail);
            memcpy(buf, b->data + relative_offset, copy_size);
            
            HPL_LOG("Preload:c->logical_pos:%lld,want %d, read %d\n", c->logical_pos, size, copy_size);
            
            c->logical_pos += copy_size;
            b->last_used = av_gettime();
            
            // 唤醒 worker 检查是否需要填充下一个块
            pthread_cond_signal(&c->cond);
            pthread_mutex_unlock(&c->mutex);
            return copy_size;
        }

        if (c->abort_request) {
            pthread_mutex_unlock(&c->mutex);
            return AVERROR_EXIT;
        }

        // 运行到这里说明缓存里没数据，需要等待
        HPL_LOG("Preload:Buffer empty at pos %lld, waiting for worker...\n", c->logical_pos);
        
        // 唤醒 worker 赶紧干活
        pthread_cond_signal(&c->cond);
        
        // 等待数据填充的信号
        pthread_cond_wait(&c->cond, &c->mutex);
    }
}

static int64_t seek(URLContext *h, int64_t pos, int whence) {
    HttpPreloadContext *c = h->priv_data;
    if (whence == AVSEEK_SIZE) return c->total_size;

    pthread_mutex_lock(&c->mutex);
    if (whence == SEEK_SET) c->logical_pos = pos;
    else if (whence == SEEK_CUR) c->logical_pos += pos;
    
    pthread_cond_signal(&c->cond);
    pthread_mutex_unlock(&c->mutex);
    return c->logical_pos;
}

static int open(URLContext *h, const char *uri, int flags, AVDictionary **options) {
    HttpPreloadContext *c = h->priv_data;
    av_strstart(uri, "ijkhttp2:", &uri);

    // break recursion
    av_dict_set(options, "selected_http", NULL, 0);

    int ret = ffurl_open_whitelist(&c->inner, uri, flags, &h->interrupt_callback, options, h->protocol_whitelist, h->protocol_blacklist, h);
    if (ret < 0) return ret;

    c->total_size = ffurl_size(c->inner);
    for (int i = 0; i < MAX_BLOCKS; i++) {
        c->blocks[i].data = av_malloc(BLOCK_SIZE);
        c->blocks[i].size = 0;
        c->blocks[i].last_used = av_gettime();
    }

    pthread_mutex_init(&c->mutex, NULL);
    pthread_cond_init(&c->cond, NULL);
    pthread_create(&c->worker_thread, NULL, worker_thread, h);

    return 0;
}

static int close(URLContext *h) {
    HttpPreloadContext *c = h->priv_data;
    c->abort_request = 1;
    pthread_mutex_lock(&c->mutex);
    pthread_cond_signal(&c->cond);
    pthread_mutex_unlock(&c->mutex);
    pthread_join(c->worker_thread, NULL);

    for (int i = 0; i < MAX_BLOCKS; i++) av_free(c->blocks[i].data);
    ffurl_close(c->inner);
    pthread_mutex_destroy(&c->mutex);
    pthread_cond_destroy(&c->cond);
    return 0;
}

const URLProtocol ijkimp_ff_ijkhttp2_protocol = {
    .name                = "ijkhttp2",
    .url_open2           = open,
    .url_read            = read,
    .url_seek            = seek,
    .url_close           = close,
    .priv_data_size      = sizeof(HttpPreloadContext),
    .flags               = URL_PROTOCOL_FLAG_NETWORK,
    .default_whitelist = "https,http,tls",
};
