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

package com.debugly.aura.player;

import android.text.TextUtils;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.Tracks;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

import com.debugly.fsplayer.player.misc.IMediaFormat;
import com.debugly.fsplayer.player.misc.ITrackInfo;

/**
 * 把 Media3 的 {@link Tracks} 摊平成 {@link ITrackInfo}。
 *
 * Media3 的模型比 ijk 的两层（stream / track）多一层 group：一个 group 里
 * 可以有多条同类型轨道（自适应码率就是每档码率一个 group）。轨道面板要的是
 * 扁平列表，所以这里把每个 group 里被选中的那条轨道（或第一条）取出来，
 * 按 group 顺序拼成一个数组——下标和 {@link #selectTrack} 里用的下标一致。
 *
 * 另一边的不对称：Media3 没有「按流 id 选轨」，自适应轨道要换档得改
 * TrackSelectionParameters（按语言/偏好），所以 selectTrack 对自适应轨道是空操作，
 * 见 Media3MediaPlayer#selectTrack。
 */
public class Media3TrackInfo {

    /** 把 Tracks 摊平成轨道列表；没有任何轨道时返回空数组而不是 null。 */
    static ITrackInfo[] fromTracks(@Nullable Tracks tracks) {
        if (tracks == null || tracks.isEmpty())
            return new ITrackInfo[0];

        List<ITrackInfo> result = new ArrayList<>();
        for (Tracks.Group group : tracks.getGroups()) {
            int type = mapTrackType(group.getType());
            // 一个 group 里挑一条：优先选中的，没有就第一条。
            int pick = -1;
            for (int i = 0; i < group.length; i++) {
                if (group.isTrackSelected(i)) {
                    pick = i;
                    break;
                }
            }
            if (pick < 0 && group.length > 0)
                pick = 0;
            if (pick < 0)
                continue;

            // 自适应组（ABR ladder）里的每条轨道都是同 type 的一个档位，
            // 逐条摊平出来，面板里才看得到每一档的分辨率/码率。
            boolean adaptive = group.isAdaptiveSupported() && group.length > 1;
            for (int i = 0; i < group.length; i++) {
                Format format = group.getTrackFormat(i);
                boolean selected = group.isTrackSelected(i);
                if (adaptive) {
                    result.add(new Track(format, type, selected,
                            group.getMediaTrackGroup().id, i, group.length));
                } else {
                    result.add(new Track(format, type, selected,
                            group.getMediaTrackGroup().id, -1, -1));
                }
            }
        }
        return result.toArray(new ITrackInfo[0]);
    }

    /** Media3 的 track type 常量 → ijk 侧的 MEDIA_TRACK_TYPE_*。 */
    private static int mapTrackType(int media3Type) {
        switch (media3Type) {
            case C.TRACK_TYPE_AUDIO:
                return ITrackInfo.MEDIA_TRACK_TYPE_AUDIO;
            case C.TRACK_TYPE_VIDEO:
                return ITrackInfo.MEDIA_TRACK_TYPE_VIDEO;
            case C.TRACK_TYPE_TEXT:
                // Media3 只有「文本」一类，字幕和 timedtext 归到一起。
                return ITrackInfo.MEDIA_TRACK_TYPE_SUBTITLE;
            case C.TRACK_TYPE_METADATA:
                return ITrackInfo.MEDIA_TRACK_TYPE_METADATA;
            default:
                return ITrackInfo.MEDIA_TRACK_TYPE_UNKNOWN;
        }
    }

    /** ijk 的 MEDIA_TRACK_TYPE_* → 对应的 Media3 track type 列表。 */
    public static int[] media3TrackTypeOf(int ijkTrackType) {
        switch (ijkTrackType) {
            case ITrackInfo.MEDIA_TRACK_TYPE_AUDIO:
                return new int[]{C.TRACK_TYPE_AUDIO};
            case ITrackInfo.MEDIA_TRACK_TYPE_VIDEO:
                return new int[]{C.TRACK_TYPE_VIDEO};
            case ITrackInfo.MEDIA_TRACK_TYPE_SUBTITLE:
            case ITrackInfo.MEDIA_TRACK_TYPE_TIMEDTEXT:
                return new int[]{C.TRACK_TYPE_TEXT};
            default:
                return new int[0];
        }
    }

    private static final class Track implements ITrackInfo {
        private final Format mFormat;
        private final int mTrackType;
        private final boolean mSelected;
        private final String mGroupId;
        /** 自适应组内的下标；非自适应轨道为 -1。 */
        private final int mTrackIndexInGroup;
        private final int mTrackCountInGroup;

        Track(Format format, int trackType, boolean selected, String groupId,
              int trackIndexInGroup, int trackCountInGroup) {
            mFormat = format;
            mTrackType = trackType;
            mSelected = selected;
            mGroupId = groupId;
            mTrackIndexInGroup = trackIndexInGroup;
            mTrackCountInGroup = trackCountInGroup;
        }

        @Nullable
        @Override
        public IMediaFormat getFormat() {
            return new FormatAdapter(mFormat);
        }

        @Override
        public String getLanguage() {
            return TextUtils.isEmpty(mFormat.language) ? "und" : mFormat.language;
        }

        @Override
        public int getTrackType() {
            return mTrackType;
        }

        @Override
        public String getInfoInline() {
            StringBuilder out = new StringBuilder(192);
            out.append("mime=").append(mFormat.sampleMimeType);
            if (!TextUtils.isEmpty(mFormat.id))
                out.append(", id=").append(mFormat.id);
            if (!TextUtils.isEmpty(mFormat.language))
                out.append(", lang=").append(mFormat.language);
            if (mTrackType == ITrackInfo.MEDIA_TRACK_TYPE_VIDEO) {
                if (mFormat.width > 0 && mFormat.height > 0)
                    out.append(", ").append(mFormat.width).append('x').append(mFormat.height);
                if (mFormat.bitrate > 0)
                    out.append(", ").append(mFormat.bitrate / 1000).append("kbps");
                if (mFormat.frameRate > 0)
                    out.append(String.format(Locale.US, ", fps=%.3f", mFormat.frameRate));
                if (mTrackCountInGroup > 1)
                    out.append(String.format(Locale.US, ", ladder %d/%d",
                            mTrackIndexInGroup + 1, mTrackCountInGroup));
            } else if (mTrackType == ITrackInfo.MEDIA_TRACK_TYPE_AUDIO) {
                if (mFormat.bitrate > 0)
                    out.append(", ").append(mFormat.bitrate / 1000).append("kbps");
                // Format.NO_VALUE 是 -1，未知时别把 -1 印出来。
                if (mFormat.channelCount != Format.NO_VALUE)
                    out.append(String.format(Locale.US, ", channels=%d", mFormat.channelCount));
                if (mFormat.sampleRate != Format.NO_VALUE && mFormat.sampleRate > 0)
                    out.append(", ").append(mFormat.sampleRate).append("Hz");
            }
            if (mTrackType != ITrackInfo.MEDIA_TRACK_TYPE_UNKNOWN
                    && mFormat.roleFlags != 0) {
                out.append(", roleFlags=0x").append(Integer.toHexString(mFormat.roleFlags));
            }
            if (mSelected)
                out.append(" [selected]");
            return out.toString();
        }

        @Override
        public String toString() {
            return "Media3TrackInfo{" + getInfoInline() + "}";
        }
    }

    /**
     * Media3 的 Format → ijk 侧的 IMediaFormat。
     *
     * IMediaFormat 只有 getString/getInteger 两个方法，媒体专用字段拿不到，
     * 所以这里只映射公共的 mime/width/height——轨道面板只用 getInfoInline()，
     * 那条路径是完整的。
     */
    private static final class FormatAdapter implements IMediaFormat {
        private final Format mFormat;

        FormatAdapter(Format format) {
            mFormat = format;
        }

        @Override
        public String getString(String name) {
            if (KEY_MIME.equals(name))
                return mFormat.sampleMimeType;
            return null;
        }

        @Override
        public int getInteger(String name) {
            if (KEY_WIDTH.equals(name))
                return mFormat.width;
            if (KEY_HEIGHT.equals(name))
                return mFormat.height;
            return 0;
        }
    }
}