/*
 *  ff_subtitle.c
 *
 * Copyright (c) 2022 debugly <qianlongxu@gmail.com>
 *
 * This file is part of FSPlayer.
 *
 * FSPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * FSPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include "ff_subtitle.h"
#include "ff_frame_queue.h"
#include "ff_packet_list.h"
#include "ff_subtitle_ex.h"
#include "ff_sub_component.h"
#include "ff_ffplay_debug.h"
#include "ijksdl_gpu.h"
#include "ijksdl/ijksdl_gpu.h"
#include "ff_subtitle_def_internal.h"

#define FS_SUBTITLE_STREAM_UNDEF -2
#define FS_SUBTITLE_STREAM_NONE -1

#define FS_EX_SUBTITLE_STREAM_MAX_COUNT    512
#define FS_EX_SUBTITLE_STREAM_MIN_OFFSET   1000
#define FS_EX_SUBTITLE_STREAM_MAX_OFFSET   (FS_EX_SUBTITLE_STREAM_MIN_OFFSET + FS_EX_SUBTITLE_STREAM_MAX_COUNT)

static const char * ff_sub_backup_charenc[] = {"GBK","BIG5-2003"};//没有使用GB18030，否则会把BIG5编码显示成乱码
static const int ff_sub_backup_charenc_len = 2;

typedef struct FFSubtitle {
    SDL_mutex* mutex;
    int need_update_stream;
    int last_stream;
    int need_update_preference;
    
    FFSubComponent* com;
    
    PacketQueue packetq;
    PacketQueue packetq2;
    FrameQueue frameq;
    float delay;
    float current_pts;
    AVFormatContext* ic_internal;
    int maxStream_internal;
    float streamStartTime;//ic start_time (s)
    
    FFExSubtitle* exSub;
    char* pathArr[FS_EX_SUBTITLE_STREAM_MAX_COUNT];
    int next_idx;
    
    int video_w, video_h;
    FSSubtitlePreference sp;
    SDL_TextureOverlay *assTexture;
    SDL_FBOOverlay *fbo;
    SDL_TextureOverlay *preTexture;
    
    //当前使用的哪个备选字符
    int backup_charenc_idx;
    SDL_Thread tmp_retry_thread;
    
    AVDictionary *opts;
}FFSubtitle;

//---------------------------Public Common Functions--------------------------------------------------//

int ff_sub_init(FFSubtitle **subp, AVDictionary *opts)
{
    int r = 0;
    if (!subp) {
        return -1;
    }
    FFSubtitle *sub = av_mallocz(sizeof(FFSubtitle));
    
    if (!sub) {
        r = -2;
        goto fail;
    }
    
    sub->mutex = SDL_CreateMutex();
    
    if (NULL == sub->mutex) {
        r = -3;
        goto fail;
    }
    
    if (packet_queue_init(&sub->packetq) < 0) {
        r = -4;
        goto fail;
    }
    
    if (packet_queue_init(&sub->packetq2) < 0) {
        r = -4;
        goto fail;
    }
    
    packet_queue_start(&sub->packetq2);
    if (frame_queue_init(&sub->frameq, &sub->packetq, SUBPICTURE_QUEUE_SIZE, 0) < 0) {
        packet_queue_destroy(&sub->packetq);
        r = -5;
        goto fail;
    }
    
    sub->delay = 0.0f;
    sub->current_pts = 0.0f;
    sub->maxStream_internal = -1;
    sub->need_update_stream = FS_SUBTITLE_STREAM_UNDEF;
    sub->last_stream = FS_SUBTITLE_STREAM_UNDEF;
    sub->need_update_preference = 0;
    sub->sp = ijk_subtitle_default_preference();
    av_dict_copy(&sub->opts, opts, 0);
    
    *subp = sub;
    
    return 0;
fail:
    if (sub && sub->mutex) {
        SDL_DestroyMutex(sub->mutex);
    }
    if (sub) {
        av_free(sub);
    }
    return r;
}

void ff_sub_desctoy_objs(FFSubtitle *sub)
{
    SDL_TextureOverlay_Release(&sub->assTexture);
    SDL_TextureOverlay_Release(&sub->preTexture);
    SDL_FBOOverlayFreeP(&sub->fbo);
    av_dict_free(&sub->opts);
}

void ff_sub_abort(FFSubtitle *sub)
{
    if (!sub) {
        return;
    }
    packet_queue_abort(&sub->packetq);
}

int ff_sub_destroy(FFSubtitle **subp)
{
    if (!subp) {
        return -1;
    }
    FFSubtitle *sub = *subp;
    
    if (!sub) {
        return -2;
    }
    
    SDL_LockMutex(sub->mutex);
    if (sub->com) {
        subComponent_close(&sub->com);
    }
    if (sub->exSub) {
        exSub_close_input(&sub->exSub);
    }
    SDL_UnlockMutex(sub->mutex);
    
    packet_queue_destroy(&sub->packetq);
    packet_queue_destroy(&sub->packetq2);
    frame_queue_destory(&sub->frameq);
    
    sub->delay = 0.0f;
    sub->current_pts = 0.0f;
    sub->maxStream_internal = -1;
    
    SDL_LockMutex(sub->mutex);
    for (int i = 0; i < sub->next_idx; i++) {
        if (sub->pathArr[i]) {
            av_free(sub->pathArr[i]);
        }
    }
    SDL_UnlockMutex(sub->mutex);
    
    SDL_DestroyMutex(sub->mutex);
    av_freep(subp);
    return 0;
}

int ff_sub_drop_old_frames(FFSubtitle *sub)
{
    int count = 0;
    int serial = sub->packetq.serial;
    while (frame_queue_nb_remaining(&sub->frameq) > 0) {
        Frame *sp = frame_queue_peek(&sub->frameq);
        if (sp->serial != serial) {
            frame_queue_next(&sub->frameq);
            count++;
            continue;
        } else {
            break;
        }
    }
    return count;
}

static int ff_sub_upload_buffer(FFSubtitle *sub, float pts, FFSubtitleBufferPacket *packet)
{
    if (!sub || !packet) {
        return -1;
    }
    SDL_LockMutex(sub->mutex);
    sub->current_pts = pts;
    pts -= (sub ? sub->delay : 0.0);
    int err = -20;
    if (sub->com) {
        if (subComponent_get_stream(sub->com) >= 0) {
            err = subComponent_upload_buffer(sub->com, pts, packet);
        }
    }
    SDL_UnlockMutex(sub->mutex);
    return err;
}

static SDL_TextureOverlay * subtitle_ass_upload_texture(SDL_TextureOverlay *texture, FFSubtitleBufferPacket *packet)
{
    texture->clearDirtyRect(texture);
    for (int i = 0; i < packet->len; i++) {
        FFSubtitleBuffer *buffer = packet->e[i];
        texture->replaceRegion(texture, buffer->rect, buffer->data);
    }
    return SDL_TextureOverlay_Retain(texture);
}

static SDL_TextureOverlay * subtitle_upload_fbo(SDL_GPU *gpu, SDL_FBOOverlay *fbo, FFSubtitleBufferPacket *packet)
{
    //macOS 10.15及以下系统，创建纹理和绘制到FBO需要分开；否者导致出现下一次的纹理，上一次的顶点坐标的奇怪bug。
    
    //1. upload texture
    SDL_TextureOverlay *textures[SUB_REF_MAX_LEN] = {0};
    int tlen = 0;
    for (int i = 0; i < packet->len; i++) {
        FFSubtitleBuffer *sub = packet->e[i];
        SDL_TextureOverlay *texture = gpu->createTexture(gpu, sub->rect.w, sub->rect.h, SDL_TEXTURE_FMT_A8, sub->data);
        texture->scale = packet->scale;
        memcpy(texture->palette, sub->palette, sizeof(sub->palette));
        textures[tlen++] = texture;
    }
    
    //2.draw texture to fbo
    fbo->beginDraw(gpu, fbo, 0);
    fbo->clear(fbo);
    int water_mark = fbo->h * SUBTITLE_MOVE_WATERMARK;
    int bottom_offset = packet->bottom_margin;
    
    for (int i = 0; i < packet->len; i++) {
        SDL_TextureOverlay *texture = textures[i];
        FFSubtitleBuffer *sub = packet->e[i];
        int offset = sub->rect.y > water_mark ? bottom_offset : 0;
        SDL_Rectangle frame = sub->rect;
        frame.y -= offset;
        fbo->drawTexture(gpu, fbo, texture, frame);
    }
    fbo->endDraw(gpu, fbo);
    
    //3.release texture
    for (int i = 0; i < packet->len; i++) {
        SDL_TextureOverlay *texture = textures[i];
        SDL_TextureOverlay_Release(&texture);
    }
    
    return fbo->getTexture(fbo);
}

//if *texture is not NULL, it was retained
static int ff_sub_upload_texture(FFSubtitle *sub, float pts, SDL_GPU *gpu, SDL_TextureOverlay **texture)
{
    if (!sub || !texture) {
        return -1;
    }
    
    FFSubtitleBufferPacket packet = {0};
    int r = ff_sub_upload_buffer(sub, pts, &packet);
    //if has no pre texture,need build texture!
    if (r < 0 || (r == 0 && sub->preTexture != NULL)) {
        *texture = NULL;
        goto end;
    }

    if (packet.isAss) {
        if (sub->assTexture && (sub->assTexture->w != packet.width || sub->assTexture->h != packet.height)) {
            SDL_TextureOverlay_Release(&sub->assTexture);
        }
        if (!sub->assTexture) {
            sub->assTexture = gpu->createTexture(gpu, packet.width, packet.height, SDL_TEXTURE_FMT_BRGA, NULL);
        }
        if (!sub->assTexture) {
            r = -1;
            goto end;
        }
        
        *texture = subtitle_ass_upload_texture(sub->assTexture, &packet);
    } else {
        if (sub->fbo && (sub->fbo->w != packet.width || sub->fbo->h != packet.height)) {
            SDL_FBOOverlayFreeP(&sub->fbo);
        }
        if (!sub->fbo) {
            sub->fbo = gpu->createFBO(gpu, packet.width, packet.height);
        }
        if (!sub->fbo) {
            r = -1;
            goto end;
        }
        
        *texture = subtitle_upload_fbo(gpu, sub->fbo, &packet);
    }
end:
    FreeSubtitleBufferArray(&packet);
    return r;
}

int ff_sub_get_texture(FFSubtitle *sub, float pts, SDL_GPU *gpu, SDL_TextureOverlay **texture)
{
    if (!texture) {
        return -1;
    }
    
    SDL_TextureOverlay *sub_overlay = NULL;
    int r = ff_sub_upload_texture(sub, pts, gpu, &sub_overlay);
    if (r > 0) {
        //replace
        SDL_TextureOverlay_Release(&sub->preTexture);
        sub->preTexture = sub_overlay;
    } else if (r < 0) {
        //clean
        SDL_TextureOverlay_Release(&sub->preTexture);
    } else {
        //keep current
        if (!sub->preTexture) {
            sub->preTexture = sub_overlay;
        }
    }
    
    *texture = SDL_TextureOverlay_Retain(sub->preTexture);
    return r;
}

void ff_sub_stream_ic_ready(FFSubtitle *sub, AVFormatContext* ic, int video_w, int video_h)
{
    if (!sub) {
        return;
    }
    sub->video_w = video_w;
    sub->video_h = video_h;
    sub->streamStartTime = fftime_to_milliseconds(ic->start_time)/1000.0;
    sub->maxStream_internal = ic->nb_streams;
    sub->ic_internal = ic;
}

int ff_sub_is_need_update_stream(FFSubtitle *sub)
{
    int r;
    SDL_LockMutex(sub->mutex);
    r = sub->need_update_stream != FS_SUBTITLE_STREAM_UNDEF;
    SDL_UnlockMutex(sub->mutex);
    return r;
}

//when close current stream "st_idx" is -1
int ff_sub_record_need_select_stream(FFSubtitle *sub, int st_idx)
{
    int r;
    SDL_LockMutex(sub->mutex);
    if (sub->last_stream == st_idx) {
        r = 0;
    } else {
        sub->need_update_stream = st_idx;
        r = 1;
    }
    SDL_UnlockMutex(sub->mutex);
    return r;
}

int ff_sub_is_need_update_preference(FFSubtitle *sub)
{
    int r;
    SDL_LockMutex(sub->mutex);
    r = sub->need_update_preference;
    SDL_UnlockMutex(sub->mutex);
    return r;
}

static int convert_ext_idx_to_fileIdx(int idx)
{
    int arr_idx = -1;
    if (idx >= FS_EX_SUBTITLE_STREAM_MIN_OFFSET && idx < FS_EX_SUBTITLE_STREAM_MAX_OFFSET) {
        arr_idx = (idx - FS_EX_SUBTITLE_STREAM_MIN_OFFSET) % FS_EX_SUBTITLE_STREAM_MAX_COUNT;
    }
    return arr_idx;
}

static const char * ext_file_path_for_idx(FFSubtitle *sub, int idx)
{
    int arr_idx = convert_ext_idx_to_fileIdx(idx);
    if (arr_idx != -1) {
        return sub->pathArr[arr_idx];
    }
    return NULL;
}

static int do_retry_next_charenc(void *opaque);

static void retry_callback(void *opaque)
{
    FFSubtitle *sub = opaque;
    if (!sub) {
        return;
    }
    //fix "Use of deallocated memory" crash
    //in other thread close this ex subtitle stream is necessory:because when destroy decoder,will join this thread,but join self won't join anything,then freed SDL_Thread struct,and func return value can't assign to retval! (thread->retval = thread->func(thread->data);)
    //if you want reproduce the crash,may need open "Address Sanitizer" option
    SDL_CreateThreadEx(&sub->tmp_retry_thread, do_retry_next_charenc, opaque, "tmp_retry");
}

static void move_backup_to_normal(FFSubtitle *sub, int stream)
{
    AVPacket pkt;
    while (1) {
        int get_pkt = packet_queue_get(&sub->packetq2, &pkt, 0, NULL);
        if (get_pkt > 0) {
            if (pkt.stream_index == stream) {
                av_log(NULL, AV_LOG_INFO,"sub move backup to normal:%d,%lld\n", pkt.stream_index, pkt.pts/1000);
                packet_queue_put(&sub->packetq, &pkt);
            } else {
                av_packet_unref(&pkt);
            }
            continue;
        }
        break;
    }
}

static int open_any_stream(FFSubtitle *sub, int stream, const char *enc)
{
    if (stream < 0) {
        return -2;
    }
    if (stream < sub->ic_internal->nb_streams) {
        //open internal
        AVStream *st = sub->ic_internal->streams[sub->need_update_stream];
        int r = subComponent_open(&sub->com, stream, st, &sub->packetq, &sub->frameq, enc, &retry_callback, (void *)sub, sub->video_w, sub->video_h, 0.0);
        if (!r) {
            subComponent_update_preference(sub->com, &sub->sp);
            move_backup_to_normal(sub, stream);
        }
        return r;
    } else {
        const char *file = ext_file_path_for_idx(sub, stream);
        if (file) {
            if (!exSub_open_input(&sub->exSub, &sub->packetq, file, sub->streamStartTime, sub->opts)) {
                AVStream *st = exSub_get_stream(sub->exSub);
                int st_id = exSub_get_stream_id(sub->exSub);
                int r = subComponent_open(&sub->com, st_id, st, &sub->packetq, &sub->frameq, enc, &retry_callback, (void *)sub, sub->video_w, sub->video_h, sub->streamStartTime);
                if (!r) {
                    subComponent_update_preference(sub->com, &sub->sp);
                    exSub_start_read(sub->exSub);
                    return 0;
                } else {
                    exSub_close_input(&sub->exSub);
                    return r;
                }
            } else {
                return -2;
            }
        } else {
            return -3;
        }
    }
}

static int do_retry_next_charenc(void *opaque)
{
    FFSubtitle *sub = opaque;
    if (!sub) {
        return -1;
    }
    
    SDL_LockMutex(sub->mutex);
    
    int st_id = sub->last_stream;
    if (st_id < 0) {
        SDL_UnlockMutex(sub->mutex);
        return -2;
    }
    
    if (sub->backup_charenc_idx >= ff_sub_backup_charenc_len) {
        SDL_UnlockMutex(sub->mutex);
        return -3;
    }
    
    const char *enc = ff_sub_backup_charenc[sub->backup_charenc_idx];
    sub->backup_charenc_idx++;
    //close old
    packet_queue_abort(&sub->packetq);
    if (sub->exSub) {
        exSub_close_input(&sub->exSub);
    }
    subComponent_close(&sub->com);
    //open new
    open_any_stream(sub, st_id, enc);
    SDL_UnlockMutex(sub->mutex);
    return 0;
}

static int ff_sub_close_current(FFSubtitle *sub)
{
    if (!sub) {
        return -1;
    }
    sub->last_stream = FS_SUBTITLE_STREAM_UNDEF;
    
    int r = 0;
    
    ff_sub_abort(sub);
    
    if (sub->exSub) {
        exSub_close_input(&sub->exSub);
    }
    
    if (sub->com) {
        r = subComponent_close(&sub->com);
    }
    //clean frame queue right now.
    ff_sub_drop_old_frames(sub);
    return r;
}

//-1: no change. 0:close current. 1:opened new, less than -1 means open failed
int ff_sub_update_stream_if_need(FFSubtitle *sub, int *update_stream, int *pre_stream)
{
    int r = -1;
    SDL_LockMutex(sub->mutex);
    if (update_stream) {
        *update_stream = FS_SUBTITLE_STREAM_NONE;
    }
    if (pre_stream) {
        *pre_stream = FS_SUBTITLE_STREAM_NONE;
    }
    if (sub->need_update_stream != FS_SUBTITLE_STREAM_UNDEF) {
        //close current
        if (sub->last_stream != FS_SUBTITLE_STREAM_UNDEF) {
            if (pre_stream) {
                *pre_stream = sub->last_stream;
            }
            //close
            ff_sub_close_current(sub);
            r = 0;
        }
        
        //open new
        if (sub->need_update_stream != FS_SUBTITLE_STREAM_NONE) {
            if (update_stream) {
                *update_stream = sub->need_update_stream;
            }
            //reset to 0
            sub->backup_charenc_idx = 0;
            int err = open_any_stream(sub, sub->need_update_stream, NULL);
            if (err) {
                r = err;
                sub->last_stream = FS_SUBTITLE_STREAM_UNDEF;
            } else {
                sub->last_stream = sub->need_update_stream;
                r = 1;
            }
        }
        sub->need_update_stream = FS_SUBTITLE_STREAM_UNDEF;
    }
    SDL_UnlockMutex(sub->mutex);
    return r;
}

AVCodecContext * ff_sub_get_avctx(FFSubtitle *sub)
{
    if (!sub || !sub->com) {
        return NULL;
    }
    
    return subComponent_get_avctx(sub->com);
}

int ff_sub_get_current_stream(FFSubtitle *sub, int *pending)
{
    int r;
    SDL_LockMutex(sub->mutex);
    r = sub->last_stream;
    if (pending) {
        *pending = sub->need_update_stream;
    }
    SDL_UnlockMutex(sub->mutex);
    return r;
}

//0 means has no sub;1 means internal sub;2 means external sub;
int ff_sub_current_stream_type(FFSubtitle *sub)
{
    int r = 0;
    if (sub) {
        SDL_LockMutex(sub->mutex);
        if (sub->last_stream < 0) {
            r = 0;
        } else if (sub->last_stream < sub->ic_internal->nb_streams) {
            r = 1;
        } else if (sub->exSub) {
            r = 2;
        }
        SDL_UnlockMutex(sub->mutex);
    }
    return r;
}

int ff_sub_frame_cache_remaining(FFSubtitle *sub)
{
    if (sub) {
        return frame_queue_nb_remaining(&sub->frameq);
    }
    return 0;
}

int ff_sub_has_enough_packets(FFSubtitle *sub, int min_frames)
{
    if (sub) {
        return sub->packetq.abort_request || sub->packetq.nb_packets > min_frames;
    }
    return 1;
}

int ff_sub_put_null_packet(FFSubtitle *sub, AVPacket *pkt, int st_idx)
{
    if (sub) {
        return packet_queue_put_nullpacket(&sub->packetq, pkt, st_idx);
    }
    return -1;
}

int ff_sub_put_packet(FFSubtitle *sub, AVPacket *pkt)
{
    if (sub) {
        move_backup_to_normal(sub, pkt->stream_index);
        //av_log(NULL, AV_LOG_INFO,"sub put pkt:%lld\n",pkt->pts/1000);
        return packet_queue_put(&sub->packetq, pkt);
    }
    return -1;
}

int ff_sub_put_packet_backup(FFSubtitle *sub, AVPacket *pkt)
{
    if (sub) {
        //av_log(NULL, AV_LOG_INFO,"sub put pkt to backup:%lld\n",pkt->pts/1000);
        return packet_queue_put(&sub->packetq2, pkt);
    }
    return -1;
}

void ff_sub_seek_to(FFSubtitle *sub, float delay, float v_pts)
{
    if (ff_sub_current_stream_type(sub) == 2) {
        float wantDisplay = v_pts - delay;
        SDL_LockMutex(sub->mutex);
        exSub_seek_to(sub->exSub, wantDisplay);
        SDL_UnlockMutex(sub->mutex);
    }
}

int ff_sub_set_delay(FFSubtitle *sub, float delay, float v_pts)
{
    if (!sub) {
        return -1;
    }
    
    float wantDisplay = v_pts - delay;
    //subtile's frame queue greater than can display pts
    if (sub->current_pts > wantDisplay) {
        float diff = fabsf(delay - sub->delay);
        sub->delay = delay;
        //need seek to wantDisplay;
        int type = ff_sub_current_stream_type(sub);
        if (type == 1) {
            //after seek maybe can display want sub,but can't seek every delay change,so when diff greater than 2s do seek.
            if (diff > 2) {
                //return 1 means need seek.
                return 1;
            }
            return -2;
        } else if (type == 2) {
            SDL_LockMutex(sub->mutex);
            exSub_seek_to(sub->exSub, wantDisplay-2);
            SDL_UnlockMutex(sub->mutex);
            return 0;
        } else {
            return -3;
        }
    } else {
        //when no need seek,just apply the diff to output frame's pts
        sub->delay = delay;
        return 0;
    }
}

float ff_sub_get_delay(FFSubtitle *sub)
{
    return sub ? sub->delay : 0.0;
}

int ff_sub_packet_queue_flush(FFSubtitle *sub)
{
    if (sub) {
        packet_queue_flush(&sub->packetq);
        packet_queue_flush(&sub->packetq2);
        return 0;
    }
    return -1;
}

int ff_update_sub_preference(FFSubtitle *sub, FSSubtitlePreference* sp)
{
    int r = 0;
    if (sub) {
        SDL_LockMutex(sub->mutex);
        sub->sp = *sp;
        if (sub->com) {
            subComponent_update_preference(sub->com, sp);
            r = 1;
        }
        SDL_UnlockMutex(sub->mutex);
    }
    return r;
}

//---------------------------External Subtitle Functions--------------------------------------------------//
static void create_meta(IjkMediaMeta **out_meta, int idx, const char *url)
{
    if (!out_meta)
        return;

    IjkMediaMeta *stream_meta = ijkmeta_create();
    if (!stream_meta)
        return;
    
    int stream_idx = idx + FS_EX_SUBTITLE_STREAM_MIN_OFFSET;
    ijkmeta_set_int64_l(stream_meta, FSM_KEY_STREAM_IDX, stream_idx);
    ijkmeta_set_string_l(stream_meta, FSM_KEY_TYPE, FSM_VAL_TYPE__TIMEDTEXT);
    ijkmeta_set_string_l(stream_meta, FSM_KEY_EX_SUBTITLE_URL, url);
    char title[16] = {0};
    snprintf(title, 16, "Track%d", idx + 1);
    ijkmeta_set_string_l(stream_meta, FSM_KEY_TITLE, title);
    
    *out_meta = stream_meta;
}

int ff_sub_add_ex_subtitle(FFSubtitle *sub, const char *file_name, IjkMediaMeta **out_meta, int *out_idx)
{
    if (!sub) {
        return -1;
    }

    int already_added = 0;
    //maybe already added.
    SDL_LockMutex(sub->mutex);
    for (int i = 0; i < sub->next_idx; i++) {
        char* next = sub->pathArr[i];
        if (next && (0 == av_strcasecmp(next, file_name))) {
            already_added = 1;
            break;
        }
    }
    SDL_UnlockMutex(sub->mutex);
    
    if (already_added) {
        if (out_idx) {
            *out_idx = -1;
        }
        return 1;
    }
    
    int r;
    SDL_LockMutex(sub->mutex);
    if (sub->next_idx < FS_EX_SUBTITLE_STREAM_MAX_COUNT) {
        int idx = sub->next_idx;
        sub->pathArr[idx] = av_strdup(file_name);
        sub->next_idx++;
        create_meta(out_meta, idx, sub->pathArr[idx]);
        if (out_idx) {
            *out_idx = idx + FS_EX_SUBTITLE_STREAM_MIN_OFFSET;
        }
        r = 0;
    } else {
        r = -2;
    }
    SDL_UnlockMutex(sub->mutex);
    return r;
}
