//
//  mr_stream_component.h
//
// FSPlayer not use the file, but the file will be used by other module in app.
//
//  Created by debugly on 2023/9/7.
//

#ifndef mr_stream_component_h
#define mr_stream_component_h

#include <stdio.h>

typedef struct MRStreamComponent MRStreamComponent;
typedef struct AVStream AVStream;
typedef struct AVCodecContext AVCodecContext;
typedef struct PacketQueue PacketQueue;
typedef struct FrameQueue FrameQueue;
typedef struct AVFormatContext AVFormatContext;

//when hasn't ic, not support seek;
int streamComponent_open(MRStreamComponent **scp, int stream_index, AVFormatContext* ic, AVCodecContext *avctx, PacketQueue* packetq, FrameQueue* frameq);
int streamComponent_close(MRStreamComponent **scp);
int streamComponent_get_stream(MRStreamComponent *sc);
int streamComponent_seek_to(MRStreamComponent *sc, int sec);
int streamComponent_get_pkt_serial(MRStreamComponent *sc);
int streamComponent_eof_and_pkt_empty(MRStreamComponent *sc);

#endif /* mr_stream_component_h */
