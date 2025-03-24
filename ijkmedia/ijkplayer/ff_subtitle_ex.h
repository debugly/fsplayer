//
//  ff_subtitle_ex.h
//  FSMediaPlayerKit
//
//  Created by Reach Matt on 2022/5/16.
//

#ifndef ff_subtitle_ex_h
#define ff_subtitle_ex_h

#include <stdio.h>

typedef struct FFExSubtitle FFExSubtitle;
typedef struct PacketQueue PacketQueue;
typedef struct AVStream AVStream;
typedef struct AVDictionary AVDictionary;

int exSub_open_input(FFExSubtitle **subp, PacketQueue * pktq, const char *file_name, float startTime, AVDictionary *opts);
void exSub_start_read(FFExSubtitle *sub);
void exSub_close_input(FFExSubtitle **sub);
AVStream * exSub_get_stream(FFExSubtitle *sub);
int exSub_get_stream_id(FFExSubtitle *sub);
//when return zero means succ;
int exSub_seek_to(FFExSubtitle *sub, float sec);

#endif /* ff_subtitle_ex_h */
