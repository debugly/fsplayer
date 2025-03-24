//
//  ff_sub_component.h
//  FSMediaPlayerKit
//
//  Created by Reach Matt on 2022/5/20.
//

#ifndef ff_sub_component_h
#define ff_sub_component_h

#include <stdio.h>

typedef void (*subComponent_retry_callback)(void *opaque);

typedef struct FFSubComponent FFSubComponent;
typedef struct AVStream AVStream;
typedef struct AVCodecContext AVCodecContext;
typedef struct PacketQueue PacketQueue;
typedef struct FrameQueue FrameQueue;
typedef struct FSSDLSubtitlePreference FSSDLSubtitlePreference;
typedef struct FFSubtitleBufferPacket FFSubtitleBufferPacket;
//when hasn't ic, not support seek;
int subComponent_open(FFSubComponent **cp, int stream_index, AVStream* stream, PacketQueue* packetq, FrameQueue* frameq, const char *enc, subComponent_retry_callback callback, void *opaque, int vw, int vh, float startTime);
int subComponent_close(FFSubComponent **cp);
int subComponent_get_stream(FFSubComponent *com);
AVCodecContext * subComponent_get_avctx(FFSubComponent *com);
int subComponent_upload_buffer(FFSubComponent *com, float pts, FFSubtitleBufferPacket *buffer_array);
void subComponent_update_preference(FFSubComponent *com, FSSDLSubtitlePreference* sp);

#endif /* ff_sub_component_h */
