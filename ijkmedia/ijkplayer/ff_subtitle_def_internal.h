//
//  ff_subtitle_def_internal.h
//  FSMediaPlayerKit
//
//  Created by Reach Matt on 2024/3/28.
//

#ifndef ff_subtitle_def_internal_hpp
#define ff_subtitle_def_internal_hpp

#include "ff_subtitle_def.h"
//忽略向上移动的字幕范围 [0-0.75]
#define SUBTITLE_MOVE_WATERMARK 0.75

FFSubtitleBuffer *ff_subtitle_buffer_alloc_rgba32(SDL_Rectangle rect);
FFSubtitleBuffer *ff_subtitle_buffer_alloc_r8(SDL_Rectangle rect);

#endif /* ff_subtitle_def_internal_hpp */
