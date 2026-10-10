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

package com.debugly.fsplayer.player.misc;

import android.text.TextUtils;

import com.debugly.fsplayer.player.FSMeta;

public class FSTrackInfo implements ITrackInfo {
    private int mTrackType = MEDIA_TRACK_TYPE_UNKNOWN;
    private FSMeta.FSStreamMeta mStreamMeta;

    public FSTrackInfo(FSMeta.FSStreamMeta streamMeta) {
        mStreamMeta = streamMeta;
    }

    public void setMediaMeta(FSMeta.FSStreamMeta streamMeta) {
        mStreamMeta = streamMeta;
    }

    @Override
    public IMediaFormat getFormat() {
        return new FSFormat(mStreamMeta);
    }

    @Override
    public String getLanguage() {
        if (mStreamMeta == null || TextUtils.isEmpty(mStreamMeta.mLanguage))
            return "und";

        return mStreamMeta.mLanguage;
    }

    @Override
    public int getTrackType() {
        return mTrackType;
    }

    public void setTrackType(int trackType) {
        mTrackType = trackType;
    }

    @Override
    public String toString() {
        return getClass().getSimpleName() + '{' + getInfoInline() + "}";
    }

    @Override
    public String getInfoInline() {
        StringBuilder out = new StringBuilder(128);
        switch (mTrackType) {
            case MEDIA_TRACK_TYPE_VIDEO:
                out.append("VIDEO");
                out.append(", ");
                out.append(mStreamMeta.getCodecShortNameInline());
                out.append(", ");
                out.append(mStreamMeta.getBitrateInline());
                out.append(", ");
                out.append(mStreamMeta.getResolutionInline());
                break;
            case MEDIA_TRACK_TYPE_AUDIO:
                out.append("AUDIO");
                out.append(", ");
                out.append(mStreamMeta.getCodecShortNameInline());
                out.append(", ");
                out.append(mStreamMeta.getBitrateInline());
                out.append(", ");
                out.append(mStreamMeta.getSampleRateInline());
                break;
            case MEDIA_TRACK_TYPE_TIMEDTEXT:
                out.append("TIMEDTEXT");
                out.append(", ");
                out.append(mStreamMeta.mLanguage);
                break;
            case MEDIA_TRACK_TYPE_SUBTITLE:
                out.append("SUBTITLE");
                break;
            default:
                out.append("UNKNOWN");
                break;
        }
        return out.toString();
    }
}
