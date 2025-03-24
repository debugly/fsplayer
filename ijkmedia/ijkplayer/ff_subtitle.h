//
//  ff_subtitle.h
//  FSMediaPlayerKit
//
//  Created by Reach Matt on 2022/5/23.
//

#ifndef ff_subtitle_h
#define ff_subtitle_h

#include "ff_subtitle_def.h"

typedef struct FFSubtitle FFSubtitle;
typedef struct AVCodecContext AVCodecContext;
typedef struct AVPacket AVPacket;
typedef struct IjkMediaMeta IjkMediaMeta;
typedef struct AVFormatContext AVFormatContext;
typedef struct SDL_TextureOverlay SDL_TextureOverlay;
typedef struct SDL_GPU SDL_GPU;
typedef struct AVDictionary AVDictionary;
// lifecycle
int ff_sub_init(FFSubtitle **subp, AVDictionary *opts);
//call in vout thread,because internal fbo and texture were created in vout thread!
void ff_sub_desctoy_objs(FFSubtitle *sub);
void ff_sub_abort(FFSubtitle *sub);
int ff_sub_destroy(FFSubtitle **subp);

//when video steam ic ready,call me.
void ff_sub_stream_ic_ready(FFSubtitle *sub, AVFormatContext* ic, int video_w, int video_h);
int ff_sub_is_need_update_stream(FFSubtitle *sub);
int ff_sub_record_need_select_stream(FFSubtitle *sub, int st_idx);
int ff_sub_is_need_update_preference(FFSubtitle *sub);
//-1: no change. 0:close current. 1:opened new, less than -1 means open failed
int ff_sub_update_stream_if_need(FFSubtitle *sub, int *update_stream, int *pre_stream);
AVCodecContext * ff_sub_get_avctx(FFSubtitle *sub);
//less than 0 means none opened stream,pending is will use stream id
int ff_sub_get_current_stream(FFSubtitle *sub, int *pending);
//0 means has no sub;1 means internal sub;2 means external sub;
int ff_sub_current_stream_type(FFSubtitle *sub);

int ff_sub_get_texture(FFSubtitle *sub, float pts, SDL_GPU *gpu, SDL_TextureOverlay **texture);
int ff_sub_drop_old_frames(FFSubtitle *sub);
int ff_sub_frame_cache_remaining(FFSubtitle *sub);

int ff_sub_has_enough_packets(FFSubtitle *sub, int min_frames);
int ff_sub_put_null_packet(FFSubtitle *sub, AVPacket *pkt, int st_idx);
int ff_sub_put_packet(FFSubtitle *sub, AVPacket *pkt);
int ff_sub_put_packet_backup(FFSubtitle *sub, AVPacket *pkt);
int ff_sub_packet_queue_flush(FFSubtitle *sub);

int ff_sub_set_delay(FFSubtitle *sub, float delay, float cp);
float ff_sub_get_delay(FFSubtitle *sub);

//return 1 means need refresh display
int ff_update_sub_preference(FFSubtitle *sub, FSSDLSubtitlePreference* sp);

//for external subtitle.
int ff_sub_add_ex_subtitle(FFSubtitle *sub, const char *file_name, IjkMediaMeta **out_meta, int *out_idx);
//only effect on external subtitle
void ff_sub_seek_to(FFSubtitle *sub, float delay, float v_pts);

#endif /* ff_subtitle_h */
