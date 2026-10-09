/*
 * Copyright (C) 2015 Bilibili
 * Copyright (C) 2015 Zhang Rui <bbcallen@gmail.com>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.debugly.fsplayer.demo.widget.media;

import com.debugly.fsplayer.player.IMediaPlayer;
import com.debugly.fsplayer.player.IjkMediaPlayer;
import com.debugly.fsplayer.player.MediaPlayerProxy;
import com.debugly.fsplayer.player.TextureMediaPlayer;
import com.debugly.fsplayer.demo.player.Media3MediaPlayer;
import com.debugly.fsplayer.demo.player.Media3TrackInfo;

public class MediaPlayerCompat {

    /** 取出当前实例（可能是 TextureMediaPlayer 代理）背后的 Media3 播放器。 */
    public static Media3MediaPlayer getMedia3MediaPlayer(IMediaPlayer mp) {
        if (mp == null) {
            return null;
        }
        if (mp instanceof Media3MediaPlayer) {
            return (Media3MediaPlayer) mp;
        }
        if (mp instanceof MediaPlayerProxy
                && ((MediaPlayerProxy) mp).getInternalMediaPlayer() instanceof Media3MediaPlayer) {
            return (Media3MediaPlayer) ((MediaPlayerProxy) mp).getInternalMediaPlayer();
        }
        return null;
    }
    public static String getName(IMediaPlayer mp) {
        if (mp == null) {
            return "null";
        } else if (mp instanceof TextureMediaPlayer) {
            StringBuilder sb = new StringBuilder("TextureMediaPlayer <");
            IMediaPlayer internalMediaPlayer = ((TextureMediaPlayer) mp).getInternalMediaPlayer();
            if (internalMediaPlayer == null) {
                sb.append("null>");
            } else {
                sb.append(internalMediaPlayer.getClass().getSimpleName());
                sb.append(">");
            }
            return sb.toString();
        } else {
            return mp.getClass().getSimpleName();
        }
    }

    public static IjkMediaPlayer getIjkMediaPlayer(IMediaPlayer mp) {
        IjkMediaPlayer ijkMediaPlayer = null;
        if (mp == null) {
            return null;
        } if (mp instanceof IjkMediaPlayer) {
            ijkMediaPlayer = (IjkMediaPlayer) mp;
        } else if (mp instanceof MediaPlayerProxy && ((MediaPlayerProxy) mp).getInternalMediaPlayer() instanceof IjkMediaPlayer) {
            ijkMediaPlayer = (IjkMediaPlayer) ((MediaPlayerProxy) mp).getInternalMediaPlayer();
        }
        return ijkMediaPlayer;
    }

    public static void selectTrack(IMediaPlayer mp, int stream) {
        IjkMediaPlayer ijkMediaPlayer = getIjkMediaPlayer(mp);
        if (ijkMediaPlayer != null) {
            ijkMediaPlayer.selectTrack(stream);
            return;
        }
        Media3MediaPlayer media3 = getMedia3MediaPlayer(mp);
        if (media3 != null)
            media3.selectTrack(stream);
    }

    public static void deselectTrack(IMediaPlayer mp, int stream) {
        IjkMediaPlayer ijkMediaPlayer = getIjkMediaPlayer(mp);
        if (ijkMediaPlayer != null) {
            ijkMediaPlayer.deselectTrack(stream);
            return;
        }
        Media3MediaPlayer media3 = getMedia3MediaPlayer(mp);
        if (media3 != null)
            media3.deselectTrack(stream);
    }

    public static int getSelectedTrack(IMediaPlayer mp, int trackType) {
        IjkMediaPlayer ijkMediaPlayer = getIjkMediaPlayer(mp);
        if (ijkMediaPlayer != null)
            return ijkMediaPlayer.getSelectedTrack(trackType);

        // Media3 没有「按 type 返回流下标」这回事：选中与否由
        // TrackSelectionOverride / 自适应选择决定，下标取当前选中组的下标。
        Media3MediaPlayer media3 = getMedia3MediaPlayer(mp);
        if (media3 == null)
            return -1;
        int[] trackTypes = Media3TrackInfo.media3TrackTypeOf(trackType);
        for (int i = 0; i < trackTypes.length; i++) {
            int index = media3.getSelectedTrackIndex(trackTypes[i]);
            if (index >= 0)
                return index;
        }
        return -1;
    }
}
