//
//  mr_stream_peek.h
//
// FSPlayer not use the file, but the file will be used by other module in app.
//
//  Created by debugly on 2023/9/7.
//

#ifndef mr_stream_peek_h
#define mr_stream_peek_h

#include <stdio.h>
typedef struct MRStreamPeeker MRStreamPeeker;

int mr_stream_peek_create(MRStreamPeeker **peeker_out,int frameCacheCount);
int mr_stream_peek_open_filepath(MRStreamPeeker *peeker, const char *file_name, int idx);

int mr_stream_peek_get_opened_stream_idx(MRStreamPeeker *peeker);
int mr_stream_peek_seek_to(MRStreamPeeker *peeker, float sec);
int mr_stream_peek_get_data(MRStreamPeeker *peeker, unsigned char *buffer, int len, double * pts_begin, double * pts_end);
int mr_stream_peek_close(MRStreamPeeker *peeker);
void mr_stream_peek_destroy(MRStreamPeeker **peeker_out);
int mr_stream_peek_get_buffer_size(int millisecond);
int mr_stream_duration(MRStreamPeeker *peeker);

#endif /* mr_stream_peek_h */
