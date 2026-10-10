/*
 * Copyright (C) 2006 Bilibili
 * Copyright (C) 2006 The Android Open Source Project
 * Copyright (C) 2013 Zhang Rui <bbcallen@gmail.com>
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

package com.debugly.fsplayer.player;

import android.annotation.SuppressLint;
import android.annotation.TargetApi;
import android.content.ContentResolver;
import android.content.Context;
import android.content.res.AssetFileDescriptor;
import android.graphics.Bitmap;
import android.graphics.SurfaceTexture;
import android.graphics.Rect;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Message;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import android.os.PowerManager;
import android.provider.Settings;
import android.text.TextUtils;

import java.nio.ByteBuffer;
import java.util.LinkedHashMap;
import java.util.Map;
import android.util.Log;
import android.view.Surface;
import android.view.SurfaceHolder;

import java.io.FileDescriptor;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.lang.ref.WeakReference;
import java.lang.reflect.Field;
import java.security.InvalidParameterException;
import java.util.ArrayList;
import java.util.Locale;
import java.util.Map;

import com.debugly.fsplayer.player.annotations.AccessedByNative;
import com.debugly.fsplayer.player.annotations.CalledByNative;
import com.debugly.fsplayer.player.misc.IAndroidIO;
import com.debugly.fsplayer.player.misc.IMediaDataSource;
import com.debugly.fsplayer.player.misc.ITrackInfo;
import com.debugly.fsplayer.player.misc.FSTrackInfo;
import com.debugly.fsplayer.player.pragma.DebugLog;

/**
 * @author bbcallen
 *
 *         Java wrapper of ffplay.
 */
public final class FSPlayer extends AbstractMediaPlayer {
    private final static String TAG = FSPlayer.class.getName();

    private static final int MEDIA_NOP = 0; // interface test message
    private static final int MEDIA_PREPARED = 1;
    private static final int MEDIA_PLAYBACK_COMPLETE = 2;
    private static final int MEDIA_BUFFERING_UPDATE = 3;
    private static final int MEDIA_SEEK_COMPLETE = 4;
    private static final int MEDIA_SET_VIDEO_SIZE = 5;
    private static final int MEDIA_TIMED_TEXT = 99;
    private static final int MEDIA_ERROR = 100;
    private static final int MEDIA_INFO = 200;

    protected static final int MEDIA_SET_VIDEO_SAR = 10001;

    //----------------------------------------
    // options
    public static final int IJK_LOG_UNKNOWN = 0;
    public static final int IJK_LOG_DEFAULT = 1;

    public static final int IJK_LOG_VERBOSE = 2;
    public static final int IJK_LOG_DEBUG = 3;
    public static final int IJK_LOG_INFO = 4;
    public static final int IJK_LOG_WARN = 5;
    public static final int IJK_LOG_ERROR = 6;
    public static final int IJK_LOG_FATAL = 7;
    public static final int IJK_LOG_SILENT = 8;

    public static final int OPT_CATEGORY_FORMAT     = 1;
    public static final int OPT_CATEGORY_CODEC      = 2;
    public static final int OPT_CATEGORY_SWS        = 3;
    public static final int OPT_CATEGORY_PLAYER     = 4;

    public static final int SDL_FCC_YV12 = 0x32315659; // YV12
    public static final int SDL_FCC_RV16 = 0x36315652; // RGB565
    public static final int SDL_FCC_RV32 = 0x32335652; // RGBX8888
    //----------------------------------------

    //----------------------------------------
    // properties
    public static final int PROP_FLOAT_VIDEO_DECODE_FRAMES_PER_SECOND       = 10001;
    public static final int PROP_FLOAT_VIDEO_OUTPUT_FRAMES_PER_SECOND       = 10002;
    public static final int FFP_PROP_FLOAT_PLAYBACK_RATE                    = 10003;
    public static final int FFP_PROP_FLOAT_DROP_FRAME_RATE                  = 10007;

    /**
     * 音频声道选择（对应 iOS 的 FSAudioChannel / setAudioChannel:）。
     * 取值见 {@link #AUDIO_CHANNEL_STEREO}；只在输出为双声道时生效，
     * 由共享核心在音频重采样阶段强制只输出其中一个声道。
     */
    public static final int FFP_PROP_INT64_CHANNEL_CONFIG                   = 30000;

    public static final int AUDIO_CHANNEL_STEREO = 0;
    public static final int AUDIO_CHANNEL_RIGHT  = 1;
    public static final int AUDIO_CHANNEL_LEFT   = 2;

    /* ---- 播放状态机（对应 iOS 的 FSPlayerPlaybackSchedule / FSPlayerLoadState）---- */

    /** 核心 mp_state（ijkplayer.h 的 MP_STATE_*），由 FFP_MSG_PLAYBACK_STATE_CHANGED 上报。 */
    public static final int MP_STATE_IDLE            = 0;
    public static final int MP_STATE_INITIALIZED     = 1;
    public static final int MP_STATE_ASYNC_PREPARING = 2;
    public static final int MP_STATE_PREPARED        = 3;
    public static final int MP_STATE_STARTED         = 4;
    public static final int MP_STATE_PAUSED          = 5;
    public static final int MP_STATE_COMPLETED       = 6;
    public static final int MP_STATE_STOPPED         = 7;
    public static final int MP_STATE_ERROR           = 8;
    public static final int MP_STATE_END             = 9;

    /** 与 iOS FSPlayerPlaybackSchedule 一一对应。 */
    public static final int PLAYBACK_SCHEDULE_IDLE        = 0;
    public static final int PLAYBACK_SCHEDULE_INITIALIZED = 1;
    public static final int PLAYBACK_SCHEDULE_PREPARING   = 2;
    public static final int PLAYBACK_SCHEDULE_PREPARED    = 3;
    public static final int PLAYBACK_SCHEDULE_STARTED     = 4;
    public static final int PLAYBACK_SCHEDULE_PAUSED      = 5;
    public static final int PLAYBACK_SCHEDULE_COMPLETED   = 6;
    public static final int PLAYBACK_SCHEDULE_STOPPED     = 7;
    public static final int PLAYBACK_SCHEDULE_ERROR        = 8;

    /** 与 iOS FSPlayerLoadState 一一对应（位掩码）。 */
    public static final int LOAD_STATE_UNKNOWN        = 0;
    public static final int LOAD_STATE_PLAYABLE       = 1 << 0;
    public static final int LOAD_STATE_PLAYTHROUGH_OK = 1 << 1;
    public static final int LOAD_STATE_STALLED        = 1 << 2;

    public static final int FFP_PROP_INT64_SELECTED_VIDEO_STREAM            = 20001;
    public static final int FFP_PROP_INT64_SELECTED_AUDIO_STREAM            = 20002;
    public static final int FFP_PROP_INT64_SELECTED_TIMEDTEXT_STREAM        = 20011;

    public static final int FFP_PROP_INT64_VIDEO_DECODER                    = 20003;
    public static final int FFP_PROP_INT64_AUDIO_DECODER                    = 20004;
    public static final int     FFP_PROPV_DECODER_UNKNOWN                   = 0;
    public static final int     FFP_PROPV_DECODER_AVCODEC                   = 1;
    public static final int     FFP_PROPV_DECODER_MEDIACODEC                = 2;
    public static final int     FFP_PROPV_DECODER_VIDEOTOOLBOX              = 3;
    public static final int FFP_PROP_INT64_VIDEO_CACHED_DURATION            = 20005;
    public static final int FFP_PROP_INT64_AUDIO_CACHED_DURATION            = 20006;
    public static final int FFP_PROP_INT64_VIDEO_CACHED_BYTES               = 20007;
    public static final int FFP_PROP_INT64_AUDIO_CACHED_BYTES               = 20008;
    public static final int FFP_PROP_INT64_VIDEO_CACHED_PACKETS             = 20009;
    public static final int FFP_PROP_INT64_AUDIO_CACHED_PACKETS             = 20010;
    public static final int FFP_PROP_INT64_ASYNC_STATISTIC_BUF_BACKWARDS    = 20201;
    public static final int FFP_PROP_INT64_ASYNC_STATISTIC_BUF_FORWARDS     = 20202;
    public static final int FFP_PROP_INT64_ASYNC_STATISTIC_BUF_CAPACITY     = 20203;
    public static final int FFP_PROP_INT64_TRAFFIC_STATISTIC_BYTE_COUNT     = 20204;
    public static final int FFP_PROP_INT64_CACHE_STATISTIC_PHYSICAL_POS     = 20205;
    public static final int FFP_PROP_INT64_CACHE_STATISTIC_FILE_FORWARDS    = 20206;
    public static final int FFP_PROP_INT64_CACHE_STATISTIC_FILE_POS         = 20207;
    public static final int FFP_PROP_INT64_CACHE_STATISTIC_COUNT_BYTES      = 20208;
    public static final int FFP_PROP_INT64_LOGICAL_FILE_SIZE                = 20209;
    public static final int FFP_PROP_INT64_SHARE_CACHE_DATA                 = 20210;
    public static final int FFP_PROP_INT64_BIT_RATE                         = 20100;
    public static final int FFP_PROP_INT64_TCP_SPEED                        = 20200;
    public static final int FFP_PROP_INT64_LATEST_SEEK_LOAD_DURATION        = 20300;
    public static final int FFP_PROP_INT64_IMMEDIATE_RECONNECT              = 20211;
    public static final int FFP_PROP_INT64_VIDEO_SCALING_MODE               = 20023;
    public static final int FFP_PROP_FLOAT_AVDELAY                          = 10004;
    public static final int FFP_PROP_FLOAT_VMDIFF                           = 10005;
    public static final int FFP_PROP_FLOAT_DROP_FRAME_COUNT                 = 10008;
    /** 画面手动三轴旋转（度），语义对齐 iOS 的 xRotateDegrees/yRotateDegrees/zRotateDegrees */
    public static final int FFP_PROP_FLOAT_VIDEO_X_ROTATE_DEGREES           = 10009;
    public static final int FFP_PROP_FLOAT_VIDEO_Y_ROTATE_DEGREES           = 10010;
    public static final int FFP_PROP_FLOAT_VIDEO_Z_ROTATE_DEGREES           = 10011;
    public static final int FFP_PROP_INT64_VIDEO_SAR_NUM                    = 20021;
    public static final int FFP_PROP_INT64_VIDEO_SAR_DEN                    = 20022;

    /* ff_ffmsg.h 的 FFP_PROPV_DECODER_* 里 Java 侧原先缺的一个 */
    public static final int FFP_PROPV_DECODER_AVCODEC_HW                    = 4;

    // 画面缩放模式，语义对齐 iOS 的 FSScalingMode
    public static final int FS_SCALING_MODE_ASPECT_FIT  = 0;   // 等比缩放，完整显示（默认）
    public static final int FS_SCALING_MODE_ASPECT_FILL = 1;   // 等比缩放，铺满显示区
    public static final int FS_SCALING_MODE_FILL        = 2;   // 非等比拉伸，铺满显示区

    // 背景图降采样后的最长边，和 iOS FSMetalBlurFilter 保持一致
    public static final int FS_BACKGROUND_MAX_SIDE = 400;
    // 高斯模糊默认参数，和 iOS 的 backgroundBlurIterations/backgroundBlurSigma 一致
    public static final int FS_BACKGROUND_BLUR_ITERATIONS = 3;
    public static final float FS_BACKGROUND_BLUR_SIGMA = 30.0f;

    /** 色彩调整的默认值（亮度/饱和度/对比度），1.0 表示原样输出，对齐 iOS 的 colorPreference */
    public static final float FS_COLOR_DEFAULT = 1.0f;

    // 快照类型，语义对齐 iOS 的 FSSnapshotType
    public static final int FS_SNAPSHOT_TYPE_ORIGIN                 = 0; // 原始尺寸，无字幕无效果
    public static final int FS_SNAPSHOT_TYPE_SCREEN                 = 1; // 屏幕上所见（含缩放/letterbox/旋转/字幕）
    public static final int FS_SNAPSHOT_TYPE_EFFECT_ORIGIN          = 2; // 原始尺寸 + 字幕
    public static final int FS_SNAPSHOT_TYPE_EFFECT_SUBTITLE_ORIGIN = 3; // 原始尺寸 + 字幕 + 效果（旋转）
    //----------------------------------------

    @AccessedByNative
    private long mNativeMediaPlayer;
    @AccessedByNative
    private long mNativeMediaDataSource;

    @AccessedByNative
    private long mNativeAndroidIO;

    @AccessedByNative
    private int mNativeSurfaceTexture;

    @AccessedByNative
    private int mListenerContext;

    private SurfaceHolder mSurfaceHolder;

    /** 高斯模糊背景（对齐 iOS 的 backgroundImage/backgroundBlurIterations/backgroundBlurSigma） */
    private Bitmap mBackgroundImage;
    private byte[] mBackgroundPixels;      // 降采样后的 RGBA8888
    private int mBackgroundWidth;
    private int mBackgroundHeight;
    private int mBackgroundBlurIterations = FS_BACKGROUND_BLUR_ITERATIONS;
    private float mBackgroundBlurSigma = FS_BACKGROUND_BLUR_SIGMA;

    private float mColorBrightness = FS_COLOR_DEFAULT;
    private float mColorSaturation = FS_COLOR_DEFAULT;
    private float mColorContrast = FS_COLOR_DEFAULT;
    private boolean mAllowHDRDirectDisplay = true;   /* iOS 的默认值是 YES */
    private int mBackgroundColorR = 0;
    private int mBackgroundColorG = 0;
    private int mBackgroundColorB = 0;
    private EventHandler mEventHandler;
    private PowerManager.WakeLock mWakeLock = null;
    private boolean mScreenOnWhilePlaying;
    private boolean mStayAwake;

    private int mVideoWidth;
    private int mVideoHeight;
    private int mVideoSarNum;
    private int mVideoSarDen;

    private String mDataSource;

    /* HUD 用的计时（对齐 iOS FSPlayer.monitor 的那几个 latency） */
    /*
     * HUD 刷新周期。iOS 的 HUD 挂在 playbackTimeNotifiTimer 上刷新（该 interval 默认是 0，
     * 也就是跟着播放事件刷），安卓这边没有等价的播放时间通知定时器，固定 500ms 一刷。
     */
    private static final int HUD_REFRESH_INTERVAL_MS = 500;

    private FSHudView mHudView;
    private FSHudPresenter mHudPresenter;
    private boolean mShouldShowHudView;
    private final Runnable mHudRefresh = new Runnable() {
        @Override
        public void run() {
            if (!mShouldShowHudView || mHudPresenter == null) {
                return;
            }
            mHudPresenter.refresh();
            mEventHandler.postDelayed(this, HUD_REFRESH_INTERVAL_MS);
        }
    };

    private long mPrepareStartMs;
    private long mPrepareLatencyMs;
    private long mFirstFrameLatencyMs;
    private long mLastSeekFrameLatencyMs;
    private boolean mFirstFrameMeasured;
    private int mPlaybackSchedule = PLAYBACK_SCHEDULE_IDLE;
    private int mLoadState = LOAD_STATE_UNKNOWN;
    private OnPlaybackScheduleChangedListener mOnPlaybackScheduleChangedListener;
    private OnLoadStateChangedListener mOnLoadStateChangedListener;
    private Map<String, String> mHudItems;

    /**
     * Default library loader
     * Load them by yourself, if your libraries are not installed at default place.
     */
    private static final FSLibLoader sLocalLibLoader = new FSLibLoader() {
        @Override
        public void loadLibrary(String libName) throws UnsatisfiedLinkError, SecurityException {
            System.loadLibrary(libName);
        }
    };

    private static volatile boolean mIsLibLoaded = false;
    public static void loadLibrariesOnce(FSLibLoader libLoader) {
        synchronized (FSPlayer.class) {
            if (!mIsLibLoaded) {
                if (libLoader == null)
                    libLoader = sLocalLibLoader;

                libLoader.loadLibrary("fsplayer");
                mIsLibLoaded = true;
            }
        }
    }

    private static volatile boolean mIsNativeInitialized = false;
    private static void initNativeOnce() {
        synchronized (FSPlayer.class) {
            if (!mIsNativeInitialized) {
                native_init();
                mIsNativeInitialized = true;
            }
        }
    }

    /**
     * Default constructor. Consider using one of the create() methods for
     * synchronously instantiating a FSPlayer from a Uri or resource.
     * <p>
     * When done with the FSPlayer, you should call {@link #release()}, to
     * free the resources. If not released, too many FSPlayer instances
     * may result in an exception.
     * </p>
     */
    public FSPlayer() {
        this(sLocalLibLoader);
    }

    /**
     * do not loadLibaray
     * @param libLoader
     *              custom library loader, can be null.
     */
    public FSPlayer(FSLibLoader libLoader) {
        initPlayer(libLoader);
    }

    private void initPlayer(FSLibLoader libLoader) {
        loadLibrariesOnce(libLoader);
        initNativeOnce();

        Looper looper;
        if ((looper = Looper.myLooper()) != null) {
            mEventHandler = new EventHandler(this, looper);
        } else if ((looper = Looper.getMainLooper()) != null) {
            mEventHandler = new EventHandler(this, looper);
        } else {
            mEventHandler = null;
        }

        /*
         * Native setup requires a weak reference to our object. It's easier to
         * create it here than in C++.
         */
        native_setup(new WeakReference<FSPlayer>(this));
    }

    private native void _setFrameAtTime(String imgCachePath, long startTime, long endTime, int num, int imgDefinition)
            throws IllegalArgumentException, IllegalStateException;

    /*
     * Update the FSPlayer SurfaceTexture. Call after setting a new
     * display surface.
     */
    private native void _setVideoSurface(Surface surface);

    /**
     * Sets the {@link SurfaceHolder} to use for displaying the video portion of
     * the media.
     *
     * Either a surface holder or surface must be set if a display or video sink
     * is needed. Not calling this method or {@link #setSurface(Surface)} when
     * playing back a video will result in only the audio track being played. A
     * null surface holder or surface will result in only the audio track being
     * played.
     *
     * @param sh
     *            the SurfaceHolder to use for video display
     */
    @Override
    public void setDisplay(SurfaceHolder sh) {
        mSurfaceHolder = sh;
        Surface surface;
        if (sh != null) {
            surface = sh.getSurface();
        } else {
            surface = null;
        }
        _setVideoSurface(surface);
        updateSurfaceScreenOn();
        applyBackgroundSettings();
    }

    /**
     * Sets the {@link Surface} to be used as the sink for the video portion of
     * the media. This is similar to {@link #setDisplay(SurfaceHolder)}, but
     * does not support {@link #setScreenOnWhilePlaying(boolean)}. Setting a
     * Surface will un-set any Surface or SurfaceHolder that was previously set.
     * A null surface will result in only the audio track being played.
     *
     * If the Surface sends frames to a {@link SurfaceTexture}, the timestamps
     * returned from {@link SurfaceTexture#getTimestamp()} will have an
     * unspecified zero point. These timestamps cannot be directly compared
     * between different media sources, different instances of the same media
     * source, or multiple runs of the same program. The timestamp is normally
     * monotonically increasing and is unaffected by time-of-day adjustments,
     * but it is reset when the position is set.
     *
     * @param surface
     *            The {@link Surface} to be used for the video portion of the
     *            media.
     */
    @Override
    public void setSurface(Surface surface) {
        if (mScreenOnWhilePlaying && surface != null) {
            DebugLog.w(TAG,
                    "setScreenOnWhilePlaying(true) is ineffective for Surface");
        }
        mSurfaceHolder = null;
        _setVideoSurface(surface);
        updateSurfaceScreenOn();
        applyBackgroundSettings();
    }

    /**
     * Sets the data source as a content Uri.
     *
     * @param context the Context to use when resolving the Uri
     * @param uri the Content URI of the data you want to play
     * @throws IllegalStateException if it is called in an invalid state
     */
    @Override
    public void setDataSource(Context context, Uri uri)
            throws IOException, IllegalArgumentException, SecurityException, IllegalStateException {
        setDataSource(context, uri, null);
    }

    /**
     * Sets the data source as a content Uri.
     *
     * @param context the Context to use when resolving the Uri
     * @param uri the Content URI of the data you want to play
     * @param headers the headers to be sent together with the request for the data
     *                Note that the cross domain redirection is allowed by default, but that can be
     *                changed with key/value pairs through the headers parameter with
     *                "android-allow-cross-domain-redirect" as the key and "0" or "1" as the value
     *                to disallow or allow cross domain redirection.
     * @throws IllegalStateException if it is called in an invalid state
     */
    @TargetApi(Build.VERSION_CODES.ICE_CREAM_SANDWICH)
    @Override
    public void setDataSource(Context context, Uri uri, Map<String, String> headers)
            throws IOException, IllegalArgumentException, SecurityException, IllegalStateException {
        final String scheme = uri.getScheme();
        if (ContentResolver.SCHEME_FILE.equals(scheme)) {
            setDataSource(uri.getPath());
            return;
        } else if (ContentResolver.SCHEME_CONTENT.equals(scheme)
                && Settings.AUTHORITY.equals(uri.getAuthority())) {
            // Redirect ringtones to go directly to underlying provider
            uri = RingtoneManager.getActualDefaultRingtoneUri(context,
                    RingtoneManager.getDefaultType(uri));
            if (uri == null) {
                throw new FileNotFoundException("Failed to resolve default ringtone");
            }
        }

        AssetFileDescriptor fd = null;
        try {
            ContentResolver resolver = context.getContentResolver();
            fd = resolver.openAssetFileDescriptor(uri, "r");
            if (fd == null) {
                return;
            }
            // Note: using getDeclaredLength so that our behavior is the same
            // as previous versions when the content provider is returning
            // a full file.
            if (fd.getDeclaredLength() < 0) {
                setDataSource(fd.getFileDescriptor());
            } else {
                setDataSource(fd.getFileDescriptor(), fd.getStartOffset(), fd.getDeclaredLength());
            }
            return;
        } catch (SecurityException ignored) {
        } catch (IOException ignored) {
        } finally {
            if (fd != null) {
                fd.close();
            }
        }

        Log.d(TAG, "Couldn't open file on client side, trying server side");

        setDataSource(uri.toString(), headers);
    }

    /**
     * Sets the data source (file-path or http/rtsp URL) to use.
     *
     * @param path
     *            the path of the file, or the http/rtsp URL of the stream you
     *            want to play
     * @throws IllegalStateException
     *             if it is called in an invalid state
     *
     *             <p>
     *             When <code>path</code> refers to a local file, the file may
     *             actually be opened by a process other than the calling
     *             application. This implies that the pathname should be an
     *             absolute path (as any other process runs with unspecified
     *             current working directory), and that the pathname should
     *             reference a world-readable file.
     */
    @Override
    public void setDataSource(String path)
            throws IOException, IllegalArgumentException, SecurityException, IllegalStateException {
        mDataSource = path;
        _setDataSource(path, null, null);
    }

    /**
     * Sets the data source (file-path or http/rtsp URL) to use.
     *
     * @param path the path of the file, or the http/rtsp URL of the stream you want to play
     * @param headers the headers associated with the http request for the stream you want to play
     * @throws IllegalStateException if it is called in an invalid state
     */
    public void setDataSource(String path, Map<String, String> headers)
            throws IOException, IllegalArgumentException, SecurityException, IllegalStateException
    {
        if (headers != null && !headers.isEmpty()) {
            StringBuilder sb = new StringBuilder();
            for(Map.Entry<String, String> entry: headers.entrySet()) {
                sb.append(entry.getKey());
                sb.append(":");
                String value = entry.getValue();
                if (!TextUtils.isEmpty(value))
                    sb.append(entry.getValue());
                sb.append("\r\n");
                setOption(OPT_CATEGORY_FORMAT, "headers", sb.toString());
                setOption(FSPlayer.OPT_CATEGORY_FORMAT, "protocol_whitelist", "async,cache,crypto,file,http,https,ijkhttphook,ijkinject,ijklivehook,ijklongurl,ijksegment,ijktcphook,pipe,rtp,tcp,tls,udp,ijkurlhook,data");
            }
        }
        setDataSource(path);
    }

    /**
     * Sets the data source (FileDescriptor) to use. It is the caller's responsibility
     * to close the file descriptor. It is safe to do so as soon as this call returns.
     *
     * @param fd the FileDescriptor for the file you want to play
     * @throws IllegalStateException if it is called in an invalid state
     */
    @TargetApi(Build.VERSION_CODES.HONEYCOMB_MR2)
    @Override
    public void setDataSource(FileDescriptor fd)
            throws IOException, IllegalArgumentException, IllegalStateException {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.HONEYCOMB_MR1) {
            int native_fd = -1;
            try {
                Field f = fd.getClass().getDeclaredField("descriptor"); //NoSuchFieldException
                f.setAccessible(true);
                native_fd = f.getInt(fd); //IllegalAccessException
            } catch (NoSuchFieldException e) {
                throw new RuntimeException(e);
            } catch (IllegalAccessException e) {
                throw new RuntimeException(e);
            }
            _setDataSourceFd(native_fd);
        } else {
            ParcelFileDescriptor pfd = ParcelFileDescriptor.dup(fd);
            try {
                _setDataSourceFd(pfd.getFd());
            } finally {
                pfd.close();
            }
        }
    }

    /**
     * Sets the data source (FileDescriptor) to use.  The FileDescriptor must be
     * seekable (N.B. a LocalSocket is not seekable). It is the caller's responsibility
     * to close the file descriptor. It is safe to do so as soon as this call returns.
     *
     * @param fd the FileDescriptor for the file you want to play
     * @param offset the offset into the file where the data to be played starts, in bytes
     * @param length the length in bytes of the data to be played
     * @throws IllegalStateException if it is called in an invalid state
     */
    private void setDataSource(FileDescriptor fd, long offset, long length)
            throws IOException, IllegalArgumentException, IllegalStateException {
        // FIXME: handle offset, length
        setDataSource(fd);
    }

    public void setDataSource(IMediaDataSource mediaDataSource)
            throws IllegalArgumentException, SecurityException, IllegalStateException {
        _setDataSource(mediaDataSource);
    }

    public void setAndroidIOCallback(IAndroidIO androidIO)
            throws IllegalArgumentException, SecurityException, IllegalStateException {
        _setAndroidIOCallback(androidIO);
    }

    private native void _setDataSource(String path, String[] keys, String[] values)
            throws IOException, IllegalArgumentException, SecurityException, IllegalStateException;

    private native void _setDataSourceFd(int fd)
            throws IOException, IllegalArgumentException, SecurityException, IllegalStateException;

    private native void _setDataSource(IMediaDataSource mediaDataSource)
            throws IllegalArgumentException, SecurityException, IllegalStateException;

    private native void _setAndroidIOCallback(IAndroidIO androidIO)
            throws IllegalArgumentException, SecurityException, IllegalStateException;

    @Override
    public String getDataSource() {
        return mDataSource;
    }

    @Override
    public void prepareAsync() throws IllegalStateException {
        mPrepareStartMs = SystemClock.elapsedRealtime();
        mFirstFrameMeasured = false;
        mFirstFrameLatencyMs = 0;
        _prepareAsync();
    }

    public native void _prepareAsync() throws IllegalStateException;

    @Override
    public void start() throws IllegalStateException {
        stayAwake(true);
        _start();
    }

    private native void _start() throws IllegalStateException;

    @Override
    public void stop() throws IllegalStateException {
        stayAwake(false);
        _stop();
    }

    private native void _stop() throws IllegalStateException;

    @Override
    public void pause() throws IllegalStateException {
        stayAwake(false);
        _pause();
    }

    private native void _pause() throws IllegalStateException;

    @SuppressLint("Wakelock")
    @Override
    public void setWakeMode(Context context, int mode) {
        boolean washeld = false;
        if (mWakeLock != null) {
            if (mWakeLock.isHeld()) {
                washeld = true;
                mWakeLock.release();
            }
            mWakeLock = null;
        }

        PowerManager pm = (PowerManager) context
                .getSystemService(Context.POWER_SERVICE);
        mWakeLock = pm.newWakeLock(mode | PowerManager.ON_AFTER_RELEASE,
                FSPlayer.class.getName());
        mWakeLock.setReferenceCounted(false);
        if (washeld) {
            mWakeLock.acquire();
        }
    }

    @Override
    public void setScreenOnWhilePlaying(boolean screenOn) {
        if (mScreenOnWhilePlaying != screenOn) {
            if (screenOn && mSurfaceHolder == null) {
                DebugLog.w(TAG,
                        "setScreenOnWhilePlaying(true) is ineffective without a SurfaceHolder");
            }
            mScreenOnWhilePlaying = screenOn;
            updateSurfaceScreenOn();
        }
    }

    @SuppressLint("Wakelock")
    private void stayAwake(boolean awake) {
        if (mWakeLock != null) {
            if (awake && !mWakeLock.isHeld()) {
                mWakeLock.acquire();
            } else if (!awake && mWakeLock.isHeld()) {
                mWakeLock.release();
            }
        }
        mStayAwake = awake;
        updateSurfaceScreenOn();
    }

    private void updateSurfaceScreenOn() {
        if (mSurfaceHolder != null) {
            mSurfaceHolder.setKeepScreenOn(mScreenOnWhilePlaying && mStayAwake);
        }
    }

    @Override
    public FSTrackInfo[] getTrackInfo() {
        Bundle bundle = getMediaMeta();
        if (bundle == null)
            return null;

        FSMeta mediaMeta = FSMeta.parse(bundle);
        if (mediaMeta == null || mediaMeta.mStreams == null)
            return null;

        ArrayList<FSTrackInfo> trackInfos = new ArrayList<FSTrackInfo>();
        for (FSMeta.FSStreamMeta streamMeta: mediaMeta.mStreams) {
            FSTrackInfo trackInfo = new FSTrackInfo(streamMeta);
            if (streamMeta.mType.equalsIgnoreCase(FSMeta.IJKM_VAL_TYPE__VIDEO)) {
                trackInfo.setTrackType(ITrackInfo.MEDIA_TRACK_TYPE_VIDEO);
            } else if (streamMeta.mType.equalsIgnoreCase(FSMeta.IJKM_VAL_TYPE__AUDIO)) {
                trackInfo.setTrackType(ITrackInfo.MEDIA_TRACK_TYPE_AUDIO);
            } else if (streamMeta.mType.equalsIgnoreCase(FSMeta.IJKM_VAL_TYPE__TIMEDTEXT)) {
                trackInfo.setTrackType(ITrackInfo.MEDIA_TRACK_TYPE_TIMEDTEXT);
            }
            trackInfos.add(trackInfo);
        }

        return trackInfos.toArray(new FSTrackInfo[trackInfos.size()]);
    }

    // TODO: @Override
    public int getSelectedTrack(int trackType) {
        switch (trackType) {
            case ITrackInfo.MEDIA_TRACK_TYPE_VIDEO:
                return (int)_getPropertyLong(FFP_PROP_INT64_SELECTED_VIDEO_STREAM, -1);
            case ITrackInfo.MEDIA_TRACK_TYPE_AUDIO:
                return (int)_getPropertyLong(FFP_PROP_INT64_SELECTED_AUDIO_STREAM, -1);
            case ITrackInfo.MEDIA_TRACK_TYPE_TIMEDTEXT:
                return (int)_getPropertyLong(FFP_PROP_INT64_SELECTED_TIMEDTEXT_STREAM, -1);
            default:
                return -1;
        }
    }

    // experimental, should set DEFAULT_MIN_FRAMES and MAX_MIN_FRAMES to 25
    // TODO: @Override
    public void selectTrack(int track) {
        _setStreamSelected(track, true);
    }

    // experimental, should set DEFAULT_MIN_FRAMES and MAX_MIN_FRAMES to 25
    // TODO: @Override
    public void deselectTrack(int track) {
        _setStreamSelected(track, false);
    }

    private native void _setStreamSelected(int stream, boolean select);

    @Override
    public int getVideoWidth() {
        return mVideoWidth;
    }

    @Override
    public int getVideoHeight() {
        return mVideoHeight;
    }

    @Override
    public int getVideoSarNum() {
        return mVideoSarNum;
    }

    @Override
    public int getVideoSarDen() {
        return mVideoSarDen;
    }

    @Override
    public native boolean isPlaying();

    @Override
    public native void seekTo(long msec) throws IllegalStateException;

    @Override
    public native long getCurrentPosition();

    @Override
    public native long getDuration();

    /**
     * Releases resources associated with this FSPlayer object. It is
     * considered good practice to call this method when you're done using the
     * FSPlayer. In particular, whenever an Activity of an application is
     * paused (its onPause() method is called), or stopped (its onStop() method
     * is called), this method should be invoked to release the FSPlayer
     * object, unless the application has a special need to keep the object
     * around. In addition to unnecessary resources (such as memory and
     * instances of codecs) being held, failure to call this method immediately
     * if a FSPlayer object is no longer needed may also lead to
     * continuous battery consumption for mobile devices, and playback failure
     * for other applications if no multiple instances of the same codec are
     * supported on a device. Even if multiple instances of the same codec are
     * supported, some performance degradation may be expected when unnecessary
     * multiple instances are used at the same time.
     */
    @Override
    public void release() {
        stayAwake(false);
        stopHudTimer();
        updateSurfaceScreenOn();
        resetListeners();
        _release();
    }

    private native void _release();

    @Override
    public void reset() {
        stayAwake(false);
        _reset();
        // make sure none of the listeners get called anymore
        mEventHandler.removeCallbacksAndMessages(null);

        mVideoWidth = 0;
        mVideoHeight = 0;
    }

    private native void _reset();

    /**
     * Sets the player to be looping or non-looping.
     *
     * @param looping whether to loop or not
     */
    @Override
    public void setLooping(boolean looping) {
        int loopCount = looping ? 0 : 1;
        setOption(OPT_CATEGORY_PLAYER, "loop", loopCount);
        _setLoopCount(loopCount);
    }

    private native void _setLoopCount(int loopCount);

    /**
     * Checks whether the MediaPlayer is looping or non-looping.
     *
     * @return true if the MediaPlayer is currently looping, false otherwise
     */
    @Override
    public boolean isLooping() {
        int loopCount = _getLoopCount();
        return loopCount != 1;
    }

    private native int _getLoopCount();

    public void setSpeed(float speed) {
        _setPropertyFloat(FFP_PROP_FLOAT_PLAYBACK_RATE, speed);
    }

    /** @deprecated 历史笔误：getter 不该带参数，请用 {@link #getSpeed()}。 */
    @Deprecated
    public float getSpeed(float speed) {
        return _getPropertyFloat(FFP_PROP_FLOAT_PLAYBACK_RATE, .0f);
    }

    public float getSpeed() {
        return _getPropertyFloat(FFP_PROP_FLOAT_PLAYBACK_RATE, .0f);
    }

    /**
     * 只输出其中一个声道（例如双音轨语言分左右声道时选语言），
     * 与 iOS 的 {@code -setAudioChannel:} 行为一致。
     *
     * @param channel {@link #AUDIO_CHANNEL_STEREO} / {@link #AUDIO_CHANNEL_LEFT} / {@link #AUDIO_CHANNEL_RIGHT}
     */
    public void setAudioChannel(int channel) {
        _setPropertyLong(FFP_PROP_INT64_CHANNEL_CONFIG, channel);
    }

    /** @see #setAudioChannel(int) */
    public int getAudioChannel() {
        return (int) _getPropertyLong(FFP_PROP_INT64_CHANNEL_CONFIG, AUDIO_CHANNEL_STEREO);
    }

    /** 对应 iOS 的 FSPlayerPlaybackScheduleDidChange 通知。 */
    public interface OnPlaybackScheduleChangedListener {
        void onPlaybackScheduleChanged(FSPlayer mp, int schedule);
    }

    /** 对应 iOS 的 FSPlayerLoadStateDidChangeNotification。 */
    public interface OnLoadStateChangedListener {
        void onLoadStateChanged(FSPlayer mp, int loadState);
    }

    public void setOnPlaybackScheduleChangedListener(OnPlaybackScheduleChangedListener listener) {
        mOnPlaybackScheduleChangedListener = listener;
    }

    /** @return {@link #PLAYBACK_SCHEDULE_IDLE} 等，与 iOS playbackSchedule 取值一致 */
    public int getPlaybackSchedule() {
        return mPlaybackSchedule;
    }

    public void setOnLoadStateChangedListener(OnLoadStateChangedListener listener) {
        mOnLoadStateChangedListener = listener;
    }

    /** @return {@link #LOAD_STATE_PLAYABLE} 等位掩码，与 iOS loadState 取值一致 */
    public int getLoadState() {
        return mLoadState;
    }

    private static int playbackScheduleFromState(int mpState) {
        switch (mpState) {
            case MP_STATE_IDLE:            return PLAYBACK_SCHEDULE_IDLE;
            case MP_STATE_INITIALIZED:     return PLAYBACK_SCHEDULE_INITIALIZED;
            case MP_STATE_ASYNC_PREPARING: return PLAYBACK_SCHEDULE_PREPARING;
            case MP_STATE_PREPARED:        return PLAYBACK_SCHEDULE_PREPARED;
            case MP_STATE_STARTED:         return PLAYBACK_SCHEDULE_STARTED;
            case MP_STATE_PAUSED:          return PLAYBACK_SCHEDULE_PAUSED;
            case MP_STATE_COMPLETED:       return PLAYBACK_SCHEDULE_COMPLETED;
            case MP_STATE_STOPPED:         return PLAYBACK_SCHEDULE_STOPPED;
            case MP_STATE_ERROR:           return PLAYBACK_SCHEDULE_ERROR;
            case MP_STATE_END:             return PLAYBACK_SCHEDULE_STOPPED;
            default:                       return PLAYBACK_SCHEDULE_IDLE;
        }
    }

    private void updatePlaybackSchedule(int mpState) {
        int schedule = playbackScheduleFromState(mpState);
        if (schedule == mPlaybackSchedule) {
            return;
        }
        mPlaybackSchedule = schedule;
        OnPlaybackScheduleChangedListener listener = mOnPlaybackScheduleChangedListener;
        if (listener != null) {
            listener.onPlaybackScheduleChanged(this, schedule);
        }
    }

    private void updateLoadState(int loadState) {
        if (loadState == mLoadState) {
            return;
        }
        mLoadState = loadState;
        OnLoadStateChangedListener listener = mOnLoadStateChangedListener;
        if (listener != null) {
            listener.onLoadStateChanged(this, loadState);
        }
    }

    public int getVideoDecoder() {
        return (int)_getPropertyLong(FFP_PROP_INT64_VIDEO_DECODER, FFP_PROPV_DECODER_UNKNOWN);
    }

    public float getVideoOutputFramesPerSecond() {
        return _getPropertyFloat(PROP_FLOAT_VIDEO_OUTPUT_FRAMES_PER_SECOND, 0.0f);
    }

    public float getVideoDecodeFramesPerSecond() {
        return _getPropertyFloat(PROP_FLOAT_VIDEO_DECODE_FRAMES_PER_SECOND, 0.0f);
    }

    public long getVideoCachedDuration() {
        return _getPropertyLong(FFP_PROP_INT64_VIDEO_CACHED_DURATION, 0);
    }

    public long getAudioCachedDuration() {
        return _getPropertyLong(FFP_PROP_INT64_AUDIO_CACHED_DURATION, 0);
    }

    public long getVideoCachedBytes() {
        return _getPropertyLong(FFP_PROP_INT64_VIDEO_CACHED_BYTES, 0);
    }

    public long getAudioCachedBytes() {
        return _getPropertyLong(FFP_PROP_INT64_AUDIO_CACHED_BYTES, 0);
    }

    public long getVideoCachedPackets() {
        return _getPropertyLong(FFP_PROP_INT64_VIDEO_CACHED_PACKETS, 0);
    }

    public long getAudioCachedPackets() {
        return _getPropertyLong(FFP_PROP_INT64_AUDIO_CACHED_PACKETS, 0);
    }

    public long getAsyncStatisticBufBackwards() {
        return _getPropertyLong(FFP_PROP_INT64_ASYNC_STATISTIC_BUF_BACKWARDS, 0);
    }

    public long getAsyncStatisticBufForwards() {
        return _getPropertyLong(FFP_PROP_INT64_ASYNC_STATISTIC_BUF_FORWARDS, 0);
    }

    public long getAsyncStatisticBufCapacity() {
        return _getPropertyLong(FFP_PROP_INT64_ASYNC_STATISTIC_BUF_CAPACITY, 0);
    }

    public long getTrafficStatisticByteCount() {
        return _getPropertyLong(FFP_PROP_INT64_TRAFFIC_STATISTIC_BYTE_COUNT, 0);
    }

    public long getCacheStatisticPhysicalPos() {
        return _getPropertyLong(FFP_PROP_INT64_CACHE_STATISTIC_PHYSICAL_POS, 0);
    }

    public long getCacheStatisticFileForwards() {
        return _getPropertyLong(FFP_PROP_INT64_CACHE_STATISTIC_FILE_FORWARDS, 0);
    }

    public long getCacheStatisticFilePos() {
        return _getPropertyLong(FFP_PROP_INT64_CACHE_STATISTIC_FILE_POS, 0);
    }

    public long getCacheStatisticCountBytes() {
        return _getPropertyLong(FFP_PROP_INT64_CACHE_STATISTIC_COUNT_BYTES, 0);
    }

    public long getFileSize() {
        return _getPropertyLong(FFP_PROP_INT64_LOGICAL_FILE_SIZE, 0);
    }

    public long getBitRate() {
        return _getPropertyLong(FFP_PROP_INT64_BIT_RATE, 0);
    }

    public long getTcpSpeed() {
        return _getPropertyLong(FFP_PROP_INT64_TCP_SPEED, 0);
    }

    public long getSeekLoadDuration() {
        return _getPropertyLong(FFP_PROP_INT64_LATEST_SEEK_LOAD_DURATION, 0);
    }

    private native float _getPropertyFloat(int property, float defaultValue);
    private native void  _setPropertyFloat(int property, float value);
    private native long  _getPropertyLong(int property, long defaultValue);
    private native void  _setPropertyLong(int property, long value);

    public float getDropFrameRate() {
        return _getPropertyFloat(FFP_PROP_FLOAT_DROP_FRAME_RATE, .0f);
    }

    public int getDropFrameCount() {
        return (int) _getPropertyLong(FFP_PROP_FLOAT_DROP_FRAME_COUNT, 0);
    }

    public float getAVDelay() {
        return _getPropertyFloat(FFP_PROP_FLOAT_AVDELAY, .0f);
    }

    public float getVMDiff() {
        return _getPropertyFloat(FFP_PROP_FLOAT_VMDIFF, .0f);
    }

    /** HUD 用：直接读 HUD 需要的那些属性（iOS 也是这么读的） */
    public float getPropertyFloat(int property, float defaultValue) {
        return _getPropertyFloat(property, defaultValue);
    }

    public long getPropertyLong(int property, long defaultValue) {
        return _getPropertyLong(property, defaultValue);
    }

    public long getPrepareLatency() {
        return mPrepareLatencyMs;
    }

    public long getFirstFrameLatency() {
        return mFirstFrameLatencyMs;
    }

    public long getLastSeekFrameLatency() {
        return mLastSeekFrameLatencyMs;
    }

    /* ---- HUD：对齐 iOS 的 shouldShowHudView / FSHudController ---- */

    /** 绑定一个 HUD 卡片视图（iOS 由 player 自己建，安卓侧视图归 App 管） */
    public void attachHudView(FSHudView hudView) {
        mHudView = hudView;
        mHudPresenter = hudView != null ? new FSHudPresenter(this, hudView) : null;
        if (hudView != null) {
            hudView.setHudVisible(mShouldShowHudView);
        }
        if (mShouldShowHudView) {
            startHudTimerIfNeed();
        }
    }

    public FSHudView getHudView() {
        return mHudView;
    }

    public void setShouldShowHudView(boolean shouldShowHudView) {
        if (shouldShowHudView == mShouldShowHudView) {
            return;
        }
        mShouldShowHudView = shouldShowHudView;
        if (mHudView != null) {
            mHudView.setHudVisible(shouldShowHudView);
        }
        if (shouldShowHudView) {
            startHudTimerIfNeed();
        } else {
            stopHudTimer();
        }
    }

    public boolean shouldShowHudView() {
        return mShouldShowHudView;
    }

    public void setHudValue(String value, String key) {
        if (mHudView != null) {
            mHudView.setHudValue(value, key);
        } else {
            if (mHudItems == null) {
                mHudItems = new LinkedHashMap<String, String>();
            }
            mHudItems.put(key, value);
        }
    }

    public Map<String, String> allHudItem() {
        if (mHudView != null) {
            return mHudView.allHudItem();
        }
        return mHudItems != null ? mHudItems : new LinkedHashMap<String, String>();
    }

    private void startHudTimerIfNeed() {
        if (!mShouldShowHudView || mHudView == null) {
            return;
        }
        mEventHandler.removeCallbacks(mHudRefresh);
        mEventHandler.post(mHudRefresh);
    }

    private void stopHudTimer() {
        mEventHandler.removeCallbacks(mHudRefresh);
    }

    @Override
    public native void setVolume(float leftVolume, float rightVolume);

    @Override
    public native int getAudioSessionId();

    @Override
    public MediaInfo getMediaInfo() {
        MediaInfo mediaInfo = new MediaInfo();
        mediaInfo.mMediaPlayerName = "ijkplayer";

        String videoCodecInfo = _getVideoCodecInfo();
        if (!TextUtils.isEmpty(videoCodecInfo)) {
            String nodes[] = videoCodecInfo.split(",");
            if (nodes.length >= 2) {
                mediaInfo.mVideoDecoder = nodes[0];
                mediaInfo.mVideoDecoderImpl = nodes[1];
            } else if (nodes.length >= 1) {
                mediaInfo.mVideoDecoder = nodes[0];
                mediaInfo.mVideoDecoderImpl = "";
            }
        }

        String audioCodecInfo = _getAudioCodecInfo();
        if (!TextUtils.isEmpty(audioCodecInfo)) {
            String nodes[] = audioCodecInfo.split(",");
            if (nodes.length >= 2) {
                mediaInfo.mAudioDecoder = nodes[0];
                mediaInfo.mAudioDecoderImpl = nodes[1];
            } else if (nodes.length >= 1) {
                mediaInfo.mAudioDecoder = nodes[0];
                mediaInfo.mAudioDecoderImpl = "";
            }
        }

        try {
            mediaInfo.mMeta = FSMeta.parse(_getMediaMeta());
        } catch (Throwable e) {
            e.printStackTrace();
        }
        return mediaInfo;
    }

    @Override
    public void setLogEnabled(boolean enable) {
        // do nothing
    }

    @Override
    public boolean isPlayable() {
        return true;
    }

    private native String _getVideoCodecInfo();
    private native String _getAudioCodecInfo();

    public void setOption(int category, String name, String value)
    {
        _setOption(category, name, value);
    }

    public void setOption(int category, String name, long value)
    {
        _setOption(category, name, value);
    }

    private native void _setOption(int category, String name, String value);
    private native void _setOption(int category, String name, long value);

    public Bundle getMediaMeta() {
        return _getMediaMeta();
    }
    private native Bundle _getMediaMeta();

    public static String getColorFormatName(int mediaCodecColorFormat) {
        return _getColorFormatName(mediaCodecColorFormat);
    }

    private static native String _getColorFormatName(int mediaCodecColorFormat);

    @Override
    public void setAudioStreamType(int streamtype) {
        // do nothing
    }

    @Override
    public void setKeepInBackground(boolean keepInBackground) {
        // do nothing
    }

    private static native void native_init();

    private native void native_setup(Object FSPlayer_this);

    private native void native_finalize();

    private native void native_message_loop(Object FSPlayer_this);

    protected void finalize() throws Throwable {
        super.finalize();
        native_finalize();
    }

    public void httphookReconnect() {
        _setPropertyLong(FFP_PROP_INT64_IMMEDIATE_RECONNECT, 1);
    }

    public void setCacheShare(int share) {
        _setPropertyLong(FFP_PROP_INT64_SHARE_CACHE_DATA, (long)share);
    }

    /**
     * 设置画面缩放模式（FS_SCALING_MODE_*）。播放中随时可调用，下一帧生效。
     */
    public void setScalingMode(int mode) {
        _setPropertyLong(FFP_PROP_INT64_VIDEO_SCALING_MODE, (long)mode);
    }

    public int getScalingMode() {
        return (int)_getPropertyLong(FFP_PROP_INT64_VIDEO_SCALING_MODE, FS_SCALING_MODE_ASPECT_FIT);
    }

    /**
     * 设置画面手动三轴旋转（度），语义对齐 iOS 的 xRotateDegrees/yRotateDegrees/zRotateDegrees：
     * 绕画面中心做正交三轴旋转，最终与自动 Z 旋转（元数据）相乘；三轴都为 0 时与原行为一致。
     * 播放中随时可调用，下一帧生效。
     */
    public void setRotateDegrees(float x, float y, float z) {
        _setPropertyFloat(FFP_PROP_FLOAT_VIDEO_X_ROTATE_DEGREES, x);
        _setPropertyFloat(FFP_PROP_FLOAT_VIDEO_Y_ROTATE_DEGREES, y);
        _setPropertyFloat(FFP_PROP_FLOAT_VIDEO_Z_ROTATE_DEGREES, z);
    }

    /** @see #setRotateDegrees(float, float, float) */
    public float getXRotateDegrees() {
        return _getPropertyFloat(FFP_PROP_FLOAT_VIDEO_X_ROTATE_DEGREES, 0.0f);
    }

    /** @see #setRotateDegrees(float, float, float) */
    public float getYRotateDegrees() {
        return _getPropertyFloat(FFP_PROP_FLOAT_VIDEO_Y_ROTATE_DEGREES, 0.0f);
    }

    /** @see #setRotateDegrees(float, float, float) */
    public float getZRotateDegrees() {
        return _getPropertyFloat(FFP_PROP_FLOAT_VIDEO_Z_ROTATE_DEGREES, 0.0f);
    }

    /**
     * 设置高斯模糊背景图：无视频的区域（AspectFit 的黑边）会用这张图的高斯模糊填充，
     * 替代默认纯色背景。传 null 清除。语义对齐 iOS 的 backgroundImage。
     * 可以在 setSurface 之前调用（内部会在 surface 就绪后重试）。
     */
    public void setBackgroundImage(Bitmap bitmap) {
        mBackgroundImage = bitmap;
        if (bitmap == null) {
            mBackgroundPixels = null;
            mBackgroundWidth = mBackgroundHeight = 0;
            setBackgroundImage(null, 0, 0);
            return;
        }
        // 背景不需要高分辨率：先降采样（和 iOS FSMetalBlurFilter 一样，最长边 400），
        // 再交给 native 上传；后续换模糊参数不需要重新上传。
        Bitmap src = bitmap.getConfig() == Bitmap.Config.ARGB_8888
                ? bitmap : bitmap.copy(Bitmap.Config.ARGB_8888, false);
        if (src == null) {
            mBackgroundPixels = null;
            setBackgroundImage(null, 0, 0);
            return;
        }
        int maxSide = Math.max(src.getWidth(), src.getHeight());
        Bitmap scaled = maxSide > FS_BACKGROUND_MAX_SIDE
                ? Bitmap.createScaledBitmap(src,
                        Math.max(1, src.getWidth() * FS_BACKGROUND_MAX_SIDE / maxSide),
                        Math.max(1, src.getHeight() * FS_BACKGROUND_MAX_SIDE / maxSide), true)
                : src;
        int w = scaled.getWidth();
        int h = scaled.getHeight();
        mBackgroundPixels = new byte[w * h * 4];
        // ARGB_8888 在内存里就是 RGBA 字节序，和 native 期望的一致
        scaled.copyPixelsToBuffer(ByteBuffer.wrap(mBackgroundPixels));
        mBackgroundWidth = w;
        mBackgroundHeight = h;
        setBackgroundImage(mBackgroundPixels, w, h);
    }

    public Bitmap getBackgroundImage() {
        return mBackgroundImage;
    }

    /**
     * 生成模糊背景时的高斯迭代次数，默认 3，至少 1。和 iOS 的 backgroundBlurIterations 一致。
     */
    public void setBackgroundBlurIterations(int iterations) {
        if (iterations < 1) {
            iterations = 1;
        }
        mBackgroundBlurIterations = iterations;
        setBackgroundBlur(mBackgroundBlurIterations, mBackgroundBlurSigma);
    }

    public int getBackgroundBlurIterations() {
        return mBackgroundBlurIterations;
    }

    /**
     * 单次高斯模糊的 sigma，默认 30，值越大越模糊。和 iOS 的 backgroundBlurSigma 一致。
     */
    public void setBackgroundBlurSigma(float sigma) {
        if (sigma <= 0) {
            sigma = FS_BACKGROUND_BLUR_SIGMA;
        }
        mBackgroundBlurSigma = sigma;
        setBackgroundBlur(mBackgroundBlurIterations, mBackgroundBlurSigma);
    }

    public float getBackgroundBlurSigma() {
        return mBackgroundBlurSigma;
    }

    /**
     * 色彩调整：亮度和对比度、饱和度的默认值都是 1.0（1.0 = 原样）。
     * 语义对齐 iOS 的 colorPreference（FSColorConvertPreference），
     * 公式也照 iOS 的 rgb_adjust：先按 0.5 为中心拉对比度，再加亮度偏移，最后按亮度权重拉饱和度。
     * 只影响视频画面，不影响字幕。可以在 setSurface 之前调用（内部会在 surface 就绪后重试）。
     *
     * @param brightness 亮度，UI 常用范围 0.5~1.5，1.0 为原样
     * @param saturation 饱和度，1.0 为原样，0 为灰度
     * @param contrast   对比度，1.0 为原样
     */
    public void setColorPreference(float brightness, float saturation, float contrast) {
        mColorBrightness = brightness;
        mColorSaturation = saturation;
        mColorContrast = contrast;
        setColorAdjust(mColorBrightness, mColorSaturation, mColorContrast);
    }

    public float getColorBrightness() {
        return mColorBrightness;
    }

    public float getColorSaturation() {
        return mColorSaturation;
    }

    public float getColorContrast() {
        return mColorContrast;
    }

    /**
     * 无视频区域（黑边）的背景色，0~255，默认黑色。语义对齐 iOS 的 -setBackgroundColor:g:b:。
     * 设了模糊背景图时黑边由背景图填满，看不到这个颜色。
     */
    public void setBackgroundColor(int red, int green, int blue) {
        mBackgroundColorR = clampByte(red);
        mBackgroundColorG = clampByte(green);
        mBackgroundColorB = clampByte(blue);
        native_setBackgroundColor(mBackgroundColorR, mBackgroundColorG, mBackgroundColorB);
    }

    /** 同上，方便直接传 0xRRGGBB / ARGB 颜色（alpha 忽略）。 */
    public void setBackgroundColor(int color) {
        setBackgroundColor((color >> 16) & 0xFF, (color >> 8) & 0xFF, color & 0xFF);
    }

    /** 返回 0xFFRRGGBB。 */
    public int getBackgroundColor() {
        return 0xFF000000
                | (mBackgroundColorR << 16)
                | (mBackgroundColorG << 8)
                | mBackgroundColorB;
    }

    private static int clampByte(int value) {
        return value < 0 ? 0 : (value > 255 ? 255 : value);
    }

    /**
     * 是否允许 HDR 直显，对应 iOS 的 allowHDRDirectDisplay（默认 YES）。
     * 只有「内容是 HDR（BT.2020）且屏能直出」时才不做色调映射；
     * 当前交换链是 8bit UNORM，所以实际上总是走 iOS 的 hdr2sdr 色调映射。
     */
    public void setAllowHDRDirectDisplay(boolean allow) {
        mAllowHDRDirectDisplay = allow;
        native_setAllowHDRDirectDisplay(allow);
    }

    public boolean isAllowHDRDirectDisplay() {
        return mAllowHDRDirectDisplay;
    }

    /**
     * 是否正在直显 HDR，对应 iOS 的 directDisplayHDRSupportted。
     * 注意：安卓这边交换链是 8bit UNORM，直出 HDR 需要 10bit/浮点交换链 +
     * ANativeWindow 的 HDR data space，目前恒为 false（即总是色调映射到 SDR）。
     */
    public boolean isDirectDisplayHDRSupported() {
        return native_isDirectDisplayHDRSupported();
    }

    /** 当前帧是不是 HDR 内容（BT.2020），判定规则和 iOS 的 isHDRContent 一致。 */
    public boolean isHDRContent() {
        return native_isHDRContent();
    }

    /** surface 就绪后要重新下发一次（renderer 是随 surface 建的） */
    private void applyBackgroundSettings() {
        native_setAllowHDRDirectDisplay(mAllowHDRDirectDisplay);
        setColorAdjust(mColorBrightness, mColorSaturation, mColorContrast);
        setBackgroundColor(mBackgroundColorR, mBackgroundColorG, mBackgroundColorB);
        if (mBackgroundPixels != null) {
            setBackgroundImage(mBackgroundPixels, mBackgroundWidth, mBackgroundHeight);
        }
        setBackgroundBlur(mBackgroundBlurIterations, mBackgroundBlurSigma);
    }

    private native void setBackgroundImage(byte[] rgba, int width, int height);

    private native void setBackgroundBlur(int iterations, float sigma);

    private native void setColorAdjust(float brightness, float saturation, float contrast);

    /* public 的 setBackgroundColor(int,int,int) 和这个 native 声明签名相同，所以 native 换个名字 */
    private native void native_setBackgroundColor(int red, int green, int blue);

    private native void native_setAllowHDRDirectDisplay(boolean allow);

    private native boolean native_isDirectDisplayHDRSupported();

    private native boolean native_isHDRContent();

    /**
     * 截取当前画面（等同 {@link #FS_SNAPSHOT_TYPE_SCREEN}）。
     * 失败（还没开始渲染、渲染器不可用等）返回 null。
     * 注意：不要在 UI 线程调用，它会阻塞等渲染线程（正常情况下几十毫秒）。
     * 限制：MediaCodec 零拷贝通路下暂停时取不到最后一帧，会返回 null。
     */
    public Bitmap getSnapshot() {
        return getSnapshot(FS_SNAPSHOT_TYPE_SCREEN);
    }

    /**
     * 截取当前画面，type 取 FS_SNAPSHOT_TYPE_*，语义对齐 iOS 的 FSSnapshotType。
     * 会阻塞等渲染线程把当前帧画出来，最长几秒；失败返回 null。
     */
    public Bitmap getSnapshot(int type) {
        int[] size = new int[2];
        byte[] pixels = takeSnapshot(type, size);
        if (pixels == null || size[0] <= 0 || size[1] <= 0) {
            return null;
        }
        Bitmap bitmap = Bitmap.createBitmap(size[0], size[1], Bitmap.Config.ARGB_8888);
        bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(pixels));
        return bitmap;
    }

    private static class EventHandler extends Handler {
        private final WeakReference<FSPlayer> mWeakPlayer;

        public EventHandler(FSPlayer mp, Looper looper) {
            super(looper);
            mWeakPlayer = new WeakReference<FSPlayer>(mp);
        }

        @Override
        public void handleMessage(Message msg) {
            FSPlayer player = mWeakPlayer.get();
            if (player == null || player.mNativeMediaPlayer == 0) {
                DebugLog.w(TAG,
                        "FSPlayer went away with unhandled events");
                return;
            }

            switch (msg.what) {
            case MEDIA_PREPARED:
                player.mPrepareLatencyMs = SystemClock.elapsedRealtime() - player.mPrepareStartMs;
                player.startHudTimerIfNeed();
                // 与 iOS FFP_MSG_PREPARED 分支一致：可播且能顺放
                player.updateLoadState(LOAD_STATE_PLAYABLE | LOAD_STATE_PLAYTHROUGH_OK);
                player.notifyOnPrepared();
                return;

            case MEDIA_PLAYBACK_COMPLETE:
                player.stayAwake(false);
                player.notifyOnCompletion();
                return;

            case MEDIA_BUFFERING_UPDATE:
                long bufferPosition = msg.arg1;
                if (bufferPosition < 0) {
                    bufferPosition = 0;
                }

                long percent = 0;
                long duration = player.getDuration();
                if (duration > 0) {
                    percent = bufferPosition * 100 / duration;
                }
                if (percent >= 100) {
                    percent = 100;
                }

                // DebugLog.efmt(TAG, "Buffer (%d%%) %d/%d",  percent, bufferPosition, duration);
                player.notifyOnBufferingUpdate((int)percent);
                return;

            case MEDIA_SEEK_COMPLETE:
                player.notifyOnSeekComplete();
                return;

            case MEDIA_SET_VIDEO_SIZE:
                player.mVideoWidth = msg.arg1;
                player.mVideoHeight = msg.arg2;
                player.notifyOnVideoSizeChanged(player.mVideoWidth, player.mVideoHeight,
                        player.mVideoSarNum, player.mVideoSarDen);
                return;

            case MEDIA_ERROR:
                DebugLog.e(TAG, "Error (" + msg.arg1 + "," + msg.arg2 + ")");
                if (!player.notifyOnError(msg.arg1, msg.arg2)) {
                    player.notifyOnCompletion();
                }
                player.stayAwake(false);
                return;

            case MEDIA_INFO:
                switch (msg.arg1) {
                    case MEDIA_INFO_VIDEO_RENDERING_START:
                        DebugLog.i(TAG, "Info: MEDIA_INFO_VIDEO_RENDERING_START\n");
                        if (!player.mFirstFrameMeasured) {
                            player.mFirstFrameMeasured = true;
                            player.mFirstFrameLatencyMs =
                                    SystemClock.elapsedRealtime() - player.mPrepareStartMs;
                        }
                        break;
                    case MEDIA_INFO_AFTER_SEEK_FIRST_FRAME:
                        player.mLastSeekFrameLatencyMs = msg.arg2;
                        break;
                    case MEDIA_INFO_BUFFERING_START:
                        player.updateLoadState(LOAD_STATE_STALLED);
                        break;
                    case MEDIA_INFO_BUFFERING_END:
                        player.updateLoadState(LOAD_STATE_PLAYABLE | LOAD_STATE_PLAYTHROUGH_OK);
                        break;
                    case MEDIA_INFO_PLAYBACK_STATE_CHANGED:
                        player.updatePlaybackSchedule(msg.arg2);
                        break;
                }
                player.notifyOnInfo(msg.arg1, msg.arg2);
                // No real default action so far.
                return;
            case MEDIA_TIMED_TEXT:
                if (msg.obj == null) {
                    player.notifyOnTimedText(null);
                } else {
                    FSTimedText text = new FSTimedText(new Rect(0, 0, 1, 1), (String)msg.obj);
                    player.notifyOnTimedText(text);
                }
                return;
            case MEDIA_NOP: // interface test message - ignore
                break;

            case MEDIA_SET_VIDEO_SAR:
                player.mVideoSarNum = msg.arg1;
                player.mVideoSarDen = msg.arg2;
                player.notifyOnVideoSizeChanged(player.mVideoWidth, player.mVideoHeight,
                        player.mVideoSarNum, player.mVideoSarDen);
                break;

            default:
                DebugLog.e(TAG, "Unknown message type " + msg.what);
            }
        }
    }

    /*
     * Called from native code when an interesting event happens. This method
     * just uses the EventHandler system to post the event back to the main app
     * thread. We use a weak reference to the original FSPlayer object so
     * that the native code is safe from the object disappearing from underneath
     * it. (This is the cookie passed to native_setup().)
     */
    @CalledByNative
    private static void postEventFromNative(Object weakThiz, int what,
            int arg1, int arg2, Object obj) {
        if (weakThiz == null)
            return;

        @SuppressWarnings("rawtypes")
        FSPlayer mp = (FSPlayer) ((WeakReference) weakThiz).get();
        if (mp == null) {
            return;
        }

        if (what == MEDIA_INFO && arg1 == MEDIA_INFO_STARTED_AS_NEXT) {
            // this acquires the wakelock if needed, and sets the client side
            // state
            mp.start();
        }
        if (mp.mEventHandler != null) {
            Message m = mp.mEventHandler.obtainMessage(what, arg1, arg2, obj);
            mp.mEventHandler.sendMessage(m);
        }
    }

    /**
     * Called from the native audio thread. Only reached while an
     * OnAudioSamplesListener is installed, and it must stay allocation free:
     * the player is looked up through the same weak reference as the events.
     */
    @CalledByNative
    private static void postAudioSamplesEventFromNative(Object weakThiz, short[] samples,
            int sampleRate, int channels) {
        if (weakThiz == null)
            return;

        @SuppressWarnings("rawtypes")
        FSPlayer mp = (FSPlayer) ((WeakReference) weakThiz).get();
        if (mp == null || mp.mOnAudioSamplesListener == null) {
            return;
        }

        mp.mOnAudioSamplesListener.onAudioSamples(samples, sampleRate, channels);
    }

    /*
     * ControlMessage
     */

    private OnControlMessageListener mOnControlMessageListener;
    public void setOnControlMessageListener(OnControlMessageListener listener) {
        mOnControlMessageListener = listener;
    }

    public interface OnControlMessageListener {
        String onControlResolveSegmentUrl(int segment);
    }

    /*
     * NativeInvoke
     */

    private OnNativeInvokeListener mOnNativeInvokeListener;
    public void setOnNativeInvokeListener(OnNativeInvokeListener listener) {
        mOnNativeInvokeListener = listener;
    }

    public interface OnNativeInvokeListener {

        int CTRL_WILL_TCP_OPEN = 0x20001;               // NO ARGS
        int CTRL_DID_TCP_OPEN = 0x20002;                // ARG_ERROR, ARG_FAMILIY, ARG_IP, ARG_PORT, ARG_FD

        int CTRL_WILL_HTTP_OPEN = 0x20003;              // ARG_URL, ARG_SEGMENT_INDEX, ARG_RETRY_COUNTER
        int CTRL_WILL_LIVE_OPEN = 0x20005;              // ARG_URL, ARG_RETRY_COUNTER
        int CTRL_WILL_CONCAT_RESOLVE_SEGMENT = 0x20007; // ARG_URL, ARG_SEGMENT_INDEX, ARG_RETRY_COUNTER

        int EVENT_WILL_HTTP_OPEN = 0x1;                 // ARG_URL
        int EVENT_DID_HTTP_OPEN = 0x2;                  // ARG_URL, ARG_ERROR, ARG_HTTP_CODE
        int EVENT_WILL_HTTP_SEEK = 0x3;                 // ARG_URL, ARG_OFFSET
        int EVENT_DID_HTTP_SEEK = 0x4;                  // ARG_URL, ARG_OFFSET, ARG_ERROR, ARG_HTTP_CODE, ARG_FILE_SIZE

        String ARG_URL = "url";
        String ARG_SEGMENT_INDEX = "segment_index";
        String ARG_RETRY_COUNTER = "retry_counter";

        String ARG_ERROR = "error";
        String ARG_FAMILIY = "family";
        String ARG_IP = "ip";
        String ARG_PORT = "port";
        String ARG_FD = "fd";

        String ARG_OFFSET = "offset";
        String ARG_HTTP_CODE = "http_code";
        String ARG_FILE_SIZE = "file_size";

        /*
         * @return true if invoke is handled
         * @throws Exception on any error
         */
        boolean onNativeInvoke(int what, Bundle args);
    }

    @CalledByNative
    private static boolean onNativeInvoke(Object weakThiz, int what, Bundle args) {
        DebugLog.ifmt(TAG, "onNativeInvoke %d", what);
        if (weakThiz == null || !(weakThiz instanceof WeakReference<?>))
            throw new IllegalStateException("<null weakThiz>.onNativeInvoke()");

        @SuppressWarnings("unchecked")
        WeakReference<FSPlayer> weakPlayer = (WeakReference<FSPlayer>) weakThiz;
        FSPlayer player = weakPlayer.get();
        if (player == null)
            throw new IllegalStateException("<null weakPlayer>.onNativeInvoke()");

        OnNativeInvokeListener listener = player.mOnNativeInvokeListener;
        if (listener != null && listener.onNativeInvoke(what, args))
            return true;

        switch (what) {
            case OnNativeInvokeListener.CTRL_WILL_CONCAT_RESOLVE_SEGMENT: {
                OnControlMessageListener onControlMessageListener = player.mOnControlMessageListener;
                if (onControlMessageListener == null)
                    return false;

                int segmentIndex = args.getInt(OnNativeInvokeListener.ARG_SEGMENT_INDEX, -1);
                if (segmentIndex < 0)
                    throw new InvalidParameterException("onNativeInvoke(invalid segment index)");

                String newUrl = onControlMessageListener.onControlResolveSegmentUrl(segmentIndex);
                if (newUrl == null)
                    throw new RuntimeException(new IOException("onNativeInvoke() = <NULL newUrl>"));

                args.putString(OnNativeInvokeListener.ARG_URL, newUrl);
                return true;
            }
            default:
                return false;
        }
    }

    /*
     * MediaCodec select
     */

    public interface OnMediaCodecSelectListener {
        String onMediaCodecSelect(IMediaPlayer mp, String mimeType, int profile, int level);
    }
    private OnMediaCodecSelectListener mOnMediaCodecSelectListener;
    public void setOnMediaCodecSelectListener(OnMediaCodecSelectListener listener) {
        mOnMediaCodecSelectListener = listener;
    }

    public void resetListeners() {
        super.resetListeners();
        mOnMediaCodecSelectListener = null;
    }

    @CalledByNative
    private static String onSelectCodec(Object weakThiz, String mimeType, int profile, int level) {
        if (weakThiz == null || !(weakThiz instanceof WeakReference<?>))
            return null;

        @SuppressWarnings("unchecked")
        WeakReference<FSPlayer> weakPlayer = (WeakReference<FSPlayer>) weakThiz;
        FSPlayer player = weakPlayer.get();
        if (player == null)
            return null;

        OnMediaCodecSelectListener listener = player.mOnMediaCodecSelectListener;
        if (listener == null)
            listener = DefaultMediaCodecSelector.sInstance;

        return listener.onMediaCodecSelect(player, mimeType, profile, level);
    }

    public static class DefaultMediaCodecSelector implements OnMediaCodecSelectListener {
        public static final DefaultMediaCodecSelector sInstance = new DefaultMediaCodecSelector();

        @SuppressWarnings("deprecation")
        @TargetApi(Build.VERSION_CODES.JELLY_BEAN)
        public String onMediaCodecSelect(IMediaPlayer mp, String mimeType, int profile, int level) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.JELLY_BEAN)
                return null;

            if (TextUtils.isEmpty(mimeType))
                return null;

            Log.i(TAG, String.format(Locale.US, "onSelectCodec: mime=%s, profile=%d, level=%d", mimeType, profile, level));
            ArrayList<FSCodecInfo> candidateCodecList = new ArrayList<FSCodecInfo>();
            int numCodecs = MediaCodecList.getCodecCount();
            for (int i = 0; i < numCodecs; i++) {
                MediaCodecInfo codecInfo = MediaCodecList.getCodecInfoAt(i);
                Log.d(TAG, String.format(Locale.US, "  found codec: %s", codecInfo.getName()));
                if (codecInfo.isEncoder())
                    continue;

                String[] types = codecInfo.getSupportedTypes();
                if (types == null)
                    continue;

                for(String type: types) {
                    if (TextUtils.isEmpty(type))
                        continue;

                    Log.d(TAG, String.format(Locale.US, "    mime: %s", type));
                    if (!type.equalsIgnoreCase(mimeType))
                        continue;

                    FSCodecInfo candidate = FSCodecInfo.setupCandidate(codecInfo, mimeType);
                    if (candidate == null)
                        continue;

                    candidateCodecList.add(candidate);
                    Log.i(TAG, String.format(Locale.US, "candidate codec: %s rank=%d", codecInfo.getName(), candidate.mRank));
                    candidate.dumpProfileLevels(mimeType);
                }
            }

            if (candidateCodecList.isEmpty()) {
                return null;
            }

            FSCodecInfo bestCodec = candidateCodecList.get(0);

            for (FSCodecInfo codec : candidateCodecList) {
                if (codec.mRank > bestCodec.mRank) {
                    bestCodec = codec;
                }
            }

            if (bestCodec.mRank < FSCodecInfo.RANK_LAST_CHANCE) {
                Log.w(TAG, String.format(Locale.US, "unaccetable codec: %s", bestCodec.mCodecInfo.getName()));
                return null;
            }

            Log.i(TAG, String.format(Locale.US, "selected codec: %s rank=%d", bestCodec.mCodecInfo.getName(), bestCodec.mRank));
            return bestCodec.mCodecInfo.getName();
        }
    }

    public static native void native_profileBegin(String libName);
    public static native void native_profileEnd();
    public static native void native_setLogLevel(int level);

    // ------------------------------------------------------------------
    // The APIs below are already implemented in the native player, they were
    // only reachable from the iOS wrapper (FSMediaPlayback) until now.
    // ------------------------------------------------------------------

    /** Add an external subtitle file and activate it right away. */
    public native boolean loadThenActiveSubtitle(String path);

    /** Add an external subtitle file without activating it; 0 means succ, 1 means already added. */
    public native int addOnlyExternalSubtitle(String path);

    /** Add several external subtitle files at once; returns how many were added. */
    public native int addOnlyExternalSubtitles(String[] paths);

    /** Apply a subtitle style, pass null to restore the defaults. */
    public native void setSubtitlePreference(FSSubtitlePreference preference);

    /** Subtitle display delay in seconds. */
    public native void setSubtitleExtraDelay(float delay);
    public native float getSubtitleExtraDelay();

    /** Audio display delay in seconds, for a/v sync fine tuning. */
    public native void setAudioExtraDelay(float delay);
    public native float getAudioExtraDelay();

    /** Decode exactly one more frame, meant to be used while paused. */
    public native void stepToNextFrame();

    /** Toggle accurate seek. */
    public native void enableAccurateSeek(boolean open);

    /** How much of the source has been buffered, in ms. */
    public native long getPlayableDuration();

    /** Remaining frames in the queue, see FRAME_CACHE_TYPE_*. */
    public native int getFrameCacheRemaining(int type);

    public static final int FRAME_CACHE_TYPE_AUDIO = 1;
    public static final int FRAME_CACHE_TYPE_VIDEO = 2;
    public static final int FRAME_CACHE_TYPE_SUBTITLE = 3;

    public native void setDeinterlace(int deinterlace);
    public native int getDeinterlace();

    /** Redraw the current frame, e.g. after the surface changed. */
    public native void refreshPicture();

    /** 返回 RGBA8888 像素（宽*高*4），outSize 回填 {width, height}；失败返回 null。 */
    private native byte[] takeSnapshot(int type, int[] outSize);

    /** Reload the current video stream, used after switching the decoder. */
    public native int reloadVideoStream();

    /** Comma separated list of the file extensions the demuxers handle. */
    public native String getIFormatExtensions();

    /**
     * 与 iOS 的 {@code -getInputFormatExtensions} 对齐：把上面的逗号串拆成数组。
     *
     * @return 扩展名数组，取不到时为空数组
     */
    public String[] getInputFormatExtensions() {
        String extensions = getIFormatExtensions();
        if (extensions == null || extensions.isEmpty()) {
            return new String[0];
        }
        return extensions.split(",");
    }

    /** 与 iOS 的 {@code +playerVersion} 对齐。 */
    public static native String getPlayerVersion();

    /** 与 iOS 的 {@code +ffmpegVersion} 对齐（HUD 的 vdec 行由此补上 libavcodec 版本）。 */
    public static native String getFFmpegVersion();

    /** Start/stop recording without re-encoding (stream copy). */
    public native int startFastRecord(String path);
    public native int stopFastRecord();

    /** Start/stop recording with re-encoding. */
    public native int startExactRecord(String path);
    public native int stopExactRecord();

    public static native int native_getLogLevel();
    public static native void native_setLogReport(int useReport);

    /**
     * Observe the decoded audio samples, e.g. to draw a waveform or a level
     * meter. Each callback receives a freshly allocated array, so it can be
     * kept if needed.
     */
    public interface OnAudioSamplesListener {
        /**
         * @param samples    PCM s16 samples, null means the buffer was flushed
         * @param sampleRate samples per second
         * @param channels   number of interleaved channels
         */
        void onAudioSamples(short[] samples, int sampleRate, int channels);
    }

    private OnAudioSamplesListener mOnAudioSamplesListener;

    /**
     * Set (or clear, with null) the audio samples listener. The listener is
     * called from the audio thread.
     */
    public void setOnAudioSamplesListener(OnAudioSamplesListener listener) {
        mOnAudioSamplesListener = listener;
        _setAudioSamplesObserver(listener != null);
    }

    public OnAudioSamplesListener getOnAudioSamplesListener() {
        return mOnAudioSamplesListener;
    }

    private native void _setAudioSamplesObserver(boolean enable);
}
