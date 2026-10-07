/*
 * Copyright (C) 2013-2014 Bilibili
 * Copyright (C) 2013-2014 Zhang Rui <bbcallen@gmail.com>
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

package tv.danmaku.ijk.media.player;

import android.text.TextUtils;

import java.util.ArrayList;
import java.util.Locale;

/**
 * Fills a {@link FSHudView} from the player, the Android counterpart of the
 * iOS player's refreshHudView. Keys, value strings and the number formatting
 * follow the iOS implementation so the two HUDs read the same.
 *
 * The network timing rows the iOS player shows (tcp-info / http-code /
 * t-http-open / t-http-seek / t-preroll) come from the Apple wrapper's own
 * open delegates and have no source on Android, so they are not filled here.
 */
public final class FSHudPresenter {
    private final IjkMediaPlayer mPlayer;
    private final FSHudView mHud;
    /** 媒体 meta 在一次播放里不变，取到就留着（iOS 也存在 monitor 里） */
    private IjkMediaMeta mMeta;

    public FSHudPresenter(IjkMediaPlayer player, FSHudView hud) {
        mPlayer = player;
        mHud = hud;
    }

    public void refresh() {
        if (mPlayer == null || mHud == null) {
            return;
        }

        mHud.setHudValue(mPlayer.getDataSource(), "path");
        mHud.setHudValue("Vulkan", "v-renderer");

        if (mMeta == null) {
            MediaInfo info = mPlayer.getMediaInfo();
            if (info != null && info.mMeta != null && info.mMeta.mVideoStream != null) {
                mMeta = info.mMeta;
            }
        }
        IjkMediaMeta.IjkStreamMeta video = mMeta != null ? mMeta.mVideoStream : null;
        IjkMediaMeta.IjkStreamMeta audio = mMeta != null ? mMeta.mAudioStream : null;

        refreshResolution(video);

        if (video != null) {
            String profile = video.mCodecProfile;
            String codec = video.mCodecName;
            if (codec == null) {
                codec = "";
            }
            String withProfile = TextUtils.isEmpty(profile) ? codec
                    : String.format(Locale.US, "%s [%s]", codec, profile);
            mHud.setHudValue(String.format(Locale.US, "%s (%s)", withProfile, decoderName()),
                    "vdec");

            mHud.setHudValue(String.format(Locale.US, "%s levels: %s chroma: %s",
                            emptyIfNull(video.mCodecPixelFormat), emptyIfNull(video.mColorRange),
                            emptyIfNull(video.mChromaLocation)),
                    "v-format");

            ArrayList<String> colorParts = new ArrayList<String>();
            if (!TextUtils.isEmpty(video.mColorSpace)) {
                colorParts.add(String.format(Locale.US, "matrix: %s", video.mColorSpace));
            }
            if (!TextUtils.isEmpty(video.mColorPrimaries)) {
                colorParts.add(String.format(Locale.US, "prim: %s", video.mColorPrimaries));
            }
            if (!TextUtils.isEmpty(video.mColorTransfer)) {
                colorParts.add(String.format(Locale.US, "trc: %s", video.mColorTransfer));
            }
            if (!colorParts.isEmpty()) {
                mHud.setHudValue(TextUtils.join(" ", colorParts), "v-color");
            }
        }

        if (audio != null) {
            ArrayList<String> audioParts = new ArrayList<String>();
            String audioCodec = !TextUtils.isEmpty(audio.mCodecName)
                    ? audio.mCodecName : audio.mCodecLongName;
            if (!TextUtils.isEmpty(audioCodec)) {
                audioParts.add(audioCodec);
            }
            if (audio.mSampleRate > 0) {
                audioParts.add(String.format(Locale.US, "%dHz", audio.mSampleRate));
            }
            String audioFormat = TextUtils
                    .join(" ", new String[] { emptyIfNull(audio.mDescribe), emptyIfNull(audio.mCodecPixelFormat) })
                    .trim();
            if (!TextUtils.isEmpty(audioFormat)) {
                audioParts.add(audioFormat);
            }
            if (audio.mBitrate > 0) {
                audioParts.add(String.format(Locale.US, "%d kbps", audio.mBitrate / 1000));
            }
            if (!audioParts.isEmpty()) {
                mHud.setHudValue(TextUtils.join(" ", audioParts), "a-codec");
            }
        }

        mHud.setHudValue(String.format(Locale.US, "prepared: %s",
                formatedDurationMilli(mPlayer.getPrepareLatency())), "prepared");
        mHud.setHudValue(String.format(Locale.US, "first-frame: %s",
                formatedDurationMilli(mPlayer.getFirstFrameLatency())), "first-frame");
        if (mPlayer.getLastSeekFrameLatency() > 0) {
            mHud.setHudValue(String.format(Locale.US, "seek-frame: %s",
                    formatedDurationMilli(mPlayer.getLastSeekFrameLatency())), "seek-frame");
        }

        mHud.setHudValue(String.format(Locale.US, "drop count/rate: %d / %.2f",
                mPlayer.getDropFrameCount(), mPlayer.getDropFrameRate()), "drop-frame(c/r)");

        mHud.setHudValue(String.format(Locale.US, "fps(d/o/c): %.2f / %.2f / %.2f",
                        mPlayer.getVideoDecodeFramesPerSecond(),
                        mPlayer.getVideoOutputFramesPerSecond(),
                        fpsInMeta(video)),
                "fps(d/o/c)");

        mHud.setHudValue(String.format(Locale.US, "frames(a,v,s): %d,%d,%d",
                        mPlayer.getFrameCacheRemaining(1),
                        mPlayer.getFrameCacheRemaining(2),
                        mPlayer.getFrameCacheRemaining(3)),
                "frames(a,v,s)");

        long videoCachedDuration = mPlayer.getPropertyLong(
                IjkMediaPlayer.FFP_PROP_INT64_VIDEO_CACHED_DURATION, 0);
        long videoCachedBytes = mPlayer.getPropertyLong(
                IjkMediaPlayer.FFP_PROP_INT64_VIDEO_CACHED_BYTES, 0);
        long videoCachedPackets = mPlayer.getPropertyLong(
                IjkMediaPlayer.FFP_PROP_INT64_VIDEO_CACHED_PACKETS, 0);
        mHud.setHudValue(String.format(Locale.US, "v-cache: %s, %s, %d packets",
                        formatedDurationMilli(videoCachedDuration),
                        formatedSize(videoCachedBytes),
                        videoCachedPackets),
                "v-cache");

        long audioCachedDuration = mPlayer.getPropertyLong(
                IjkMediaPlayer.FFP_PROP_INT64_AUDIO_CACHED_DURATION, 0);
        long audioCachedBytes = mPlayer.getPropertyLong(
                IjkMediaPlayer.FFP_PROP_INT64_AUDIO_CACHED_BYTES, 0);
        long audioCachedPackets = mPlayer.getPropertyLong(
                IjkMediaPlayer.FFP_PROP_INT64_AUDIO_CACHED_PACKETS, 0);
        mHud.setHudValue(String.format(Locale.US, "a-cache: %s, %s, %d packets",
                        formatedDurationMilli(audioCachedDuration),
                        formatedSize(audioCachedBytes),
                        audioCachedPackets),
                "a-cache");

        mHud.setHudValue(String.format(Locale.US, "delay: %.3f  a-v: %.3f",
                        mPlayer.getAVDelay(), -mPlayer.getVMDiff()),
                "delay-avdiff");

        mHud.setHudValue(String.format(Locale.US, "tcp-spd: %s",
                formatedSpeed(mPlayer.getTcpSpeed(), 1000)), "tcp-spd");
    }

    private void refreshResolution(IjkMediaMeta.IjkStreamMeta video) {
        int width = mPlayer.getVideoWidth();
        int height = mPlayer.getVideoHeight();
        if (width <= 0 || height <= 0) {
            return;
        }

        long sarNum = mPlayer.getVideoSarNum();
        long sarDen = mPlayer.getVideoSarDen();
        if (sarNum <= 0 || sarDen <= 0) {
            sarNum = mPlayer.getPropertyLong(IjkMediaPlayer.FFP_PROP_INT64_VIDEO_SAR_NUM, 0);
            sarDen = mPlayer.getPropertyLong(IjkMediaPlayer.FFP_PROP_INT64_VIDEO_SAR_DEN, 0);
        }
        if ((sarNum <= 0 || sarDen <= 0) && video != null) {
            sarNum = video.mSarNum;
            sarDen = video.mSarDen;
        }
        if (sarNum <= 0 || sarDen <= 0) {
            sarNum = 1;
            sarDen = 1;
        }

        long darWidth = width * sarNum;
        long darHeight = height * sarDen;
        long gcd = gcd(darWidth, darHeight);
        long simplifiedWidth = gcd > 0 ? darWidth / gcd : darWidth;
        long simplifiedHeight = gcd > 0 ? darHeight / gcd : darHeight;

        if (sarNum != 1 || sarDen != 1) {
            mHud.setHudValue(String.format(Locale.US, "%dx%d (%d:%d) [SAR %d:%d]",
                            width, height, simplifiedWidth, simplifiedHeight, sarNum, sarDen),
                    "resolution");
        } else {
            mHud.setHudValue(String.format(Locale.US, "%dx%d (%d:%d)",
                            width, height, simplifiedWidth, simplifiedHeight),
                    "resolution");
        }
    }

    /** FFP_PROP_INT64_VIDEO_DECODER 到名字，对齐 iOS 的 coderNameWithVdecType: */
    private String decoderName() {
        int decoder = (int) mPlayer.getPropertyLong(
                IjkMediaPlayer.FFP_PROP_INT64_VIDEO_DECODER, 0);
        switch (decoder) {
            case IjkMediaPlayer.FFP_PROPV_DECODER_AVCODEC:
                return "avcodec";
            case IjkMediaPlayer.FFP_PROPV_DECODER_MEDIACODEC:
                return "mediacodec";
            case IjkMediaPlayer.FFP_PROPV_DECODER_AVCODEC_HW:
                return "avcodec-hw";
            default:
                return "N/A";
        }
    }

    private static double fpsInMeta(IjkMediaMeta.IjkStreamMeta video) {
        if (video == null || video.mFpsDen == 0) {
            return 0;
        }
        return (double) video.mFpsNum / video.mFpsDen;
    }

    private static long gcd(long a, long b) {
        while (b > 0) {
            long t = a % b;
            a = b;
            b = t;
        }
        return a;
    }

    private static String emptyIfNull(String value) {
        return value == null ? "" : value;
    }

    /** 对齐 iOS 的 formatedDurationMilli */
    private static String formatedDurationMilli(long duration) {
        if (duration == 0) {
            return "0 s";
        } else if (Math.abs(duration) >= 1000) {
            return String.format(Locale.US, "%.2f s", (float) duration / 1000);
        } else {
            return String.format(Locale.US, "%d ms", duration);
        }
    }

    /** 对齐 iOS 的 formatedSize */
    private static String formatedSize(long bytes) {
        bytes = Math.abs(bytes);
        if (bytes >= 100 * 1024) {
            return String.format(Locale.US, "%.2f MB", (float) bytes / 1000 / 1024);
        } else if (bytes >= 100) {
            return String.format(Locale.US, "%.1f KB", (float) bytes / 1000);
        } else {
            return String.format(Locale.US, "%d B", bytes);
        }
    }

    /** 对齐 iOS 的 formatedSpeed */
    private static String formatedSpeed(long bytes, long elapsedMilli) {
        if (elapsedMilli <= 0) {
            return "N/A";
        }
        if (bytes <= 0) {
            return "0";
        }
        float bytesPerSec = (float) bytes * 1000.f / elapsedMilli;
        if (bytesPerSec >= 1000 * 1000) {
            return String.format(Locale.US, "%.2f MB/s", bytesPerSec / 1000 / 1000);
        } else if (bytesPerSec >= 1000) {
            return String.format(Locale.US, "%.1f KB/s", bytesPerSec / 1000);
        } else {
            return String.format(Locale.US, "%d B/s", (long) bytesPerSec);
        }
    }
}
