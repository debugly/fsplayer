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

package tv.danmaku.ijk.media.example.player;

import android.content.Context;
import android.net.Uri;
import android.view.Surface;
import android.view.SurfaceHolder;

import androidx.annotation.NonNull;
import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.VideoSize;
import androidx.media3.exoplayer.ExoPlayer;

import java.util.Map;

import tv.danmaku.ijk.media.player.AbstractMediaPlayer;
import tv.danmaku.ijk.media.player.misc.IMediaDataSource;
import tv.danmaku.ijk.media.player.MediaInfo;
import tv.danmaku.ijk.media.player.misc.ITrackInfo;

/**
 * AndroidX Media3（以前的 ExoPlayer）后端。
 *
 * Media3 是 Google 维护的播放器，解码全部走平台 MediaCodec，与 ijkmedia
 * 的软解路线正好互补——demo 同时挂这两个后端，可以在同一台机器、同一段
 * 片子上直接比较两者的差异。
 *
 * 它没有 IJK 的那些特有能力（声道重排、三轴旋转、自定义 option），
 * 菜单里那些入口对它无效。
 */
public class Media3MediaPlayer extends AbstractMediaPlayer {

    private final Context mContext;
    private ExoPlayer mExoPlayer;

    /**
     * Media3 的 STATE_READY 也是播放器刚建好时的初值，必须配合「确实调用过
     * prepare」这个标志，否则一 setMediaItem 就会误报 prepared。
     */
    private boolean mPreparing;

    public Media3MediaPlayer(Context context) {
        mContext = context.getApplicationContext();
    }

    private ExoPlayer ensurePlayer() {
        if (mExoPlayer == null) {
            mExoPlayer = new ExoPlayer.Builder(mContext).build();
            mExoPlayer.addListener(new Player.Listener() {
                @Override
                public void onPlaybackStateChanged(int state) {
                    if (state == Player.STATE_READY && !mPreparing)
                        return;
                    if (state == Player.STATE_ENDED) {
                        notifyOnCompletion();
                    } else if (state == Player.STATE_BUFFERING) {
                        notifyOnBufferingUpdate(0);
                    }
                }

                @Override
                public void onPlayerError(@NonNull PlaybackException error) {
                    notifyOnError(MEDIA_ERROR_UNKNOWN, MEDIA_ERROR_UNKNOWN);
                }

                @Override
                public void onVideoSizeChanged(@NonNull VideoSize videoSize) {
                    if (videoSize.width == 0 || videoSize.height == 0)
                        return;
                    notifyOnVideoSizeChanged(videoSize.width, videoSize.height, 1, 1);
                }
            });
        }
        return mExoPlayer;
    }

    // ---------------- 数据源 ----------------

    @Override
    public void setDataSource(String path) {
        setDataSource(mContext, Uri.parse(path), null);
    }

    @Override
    public void setDataSource(Context context, Uri uri) {
        setDataSource(context, uri, null);
    }

    @Override
    public void setDataSource(Context context, Uri uri, Map<String, String> headers) {
        ExoPlayer player = ensurePlayer();
        // HLS / DASH 交给 Media3 按 URI 自动挑 source（DefaultMediaSourceFactory
        // 内含这些 factory），所以这里只把地址和 headers 递进去。
        player.setMediaItem(buildItem(uri, headers));
        player.prepare();
        mPreparing = true;
        notifyOnPrepared();
    }

    private static MediaItem buildItem(Uri uri, Map<String, String> headers) {
        // HLS / DASH 由 DefaultMediaSourceFactory 按 URI 自动挑 source，
        // 所以这里只递地址。请求头要生效得配 DataSource.Factory，
        // demo 目前没有需要请求头的场景，先不接。
        return new MediaItem.Builder().setUri(uri).build();
    }

    @Override
    public void setDataSource(java.io.FileDescriptor fd) {
        throw new UnsupportedOperationException(
                "Media3 backend does not support FileDescriptor");
    }

    @Override
    public void setDataSource(IMediaDataSource mediaDataSource) {
        throw new UnsupportedOperationException(
                "Media3 backend does not support IMediaDataSource");
    }

    @Override
    public String getDataSource() {
        MediaItem item = mExoPlayer == null ? null : mExoPlayer.getCurrentMediaItem();
        return item == null || item.localConfiguration == null
                ? null
                : item.localConfiguration.uri.toString();
    }

    @Override
    public void prepareAsync() {
        // setDataSource 里已经 prepare 过了，回调也一并发出。
    }

    // ---------------- 播放控制 ----------------

    @Override
    public void start() {
        ensurePlayer().setPlayWhenReady(true);
    }

    @Override
    public void pause() {
        ensurePlayer().setPlayWhenReady(false);
    }

    @Override
    public void stop() {
        if (mExoPlayer != null)
            mExoPlayer.stop();
    }

    @Override
    public boolean isPlaying() {
        return mExoPlayer != null
                && mExoPlayer.getPlayWhenReady()
                && mExoPlayer.getPlaybackState() == Player.STATE_READY;
    }

    @Override
    public void reset() {
        if (mExoPlayer != null) {
            mExoPlayer.stop();
            mExoPlayer.clearMediaItems();
        }
        mPreparing = false;
    }

    @Override
    public void release() {
        if (mExoPlayer != null) {
            mExoPlayer.release();
            mExoPlayer = null;
        }
        mPreparing = false;
    }

    @Override
    public void seekTo(long msec) {
        ensurePlayer().seekTo(msec);
        notifyOnSeekComplete();
    }

    @Override
    public long getCurrentPosition() {
        return mExoPlayer == null ? 0 : Math.max(0, mExoPlayer.getCurrentPosition());
    }

    @Override
    public long getDuration() {
        long duration = mExoPlayer == null ? 0 : mExoPlayer.getDuration();
        return duration == C.TIME_UNSET ? 0 : duration;
    }

    @Override
    public void setLooping(boolean looping) {
        ensurePlayer().setRepeatMode(looping ? Player.REPEAT_MODE_ALL : Player.REPEAT_MODE_OFF);
    }

    @Override
    public boolean isLooping() {
        return mExoPlayer != null && mExoPlayer.getRepeatMode() == Player.REPEAT_MODE_ALL;
    }

    @Override
    public void setVolume(float leftVolume, float rightVolume) {
        // Media3 只有单声道量，没有左右分开这回事。
        ensurePlayer().setVolume(Math.max(0f, Math.min(1f, leftVolume)));
    }

    @Override
    public void setAudioStreamType(int streamtype) {
        ensurePlayer().setAudioAttributes(new AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(), true);
    }

    @Override
    public int getAudioSessionId() {
        // Media3 不暴露 audio session id（旧版 Visualizer 的挂点）。
        return 0;
    }

    @Override
    public void setWakeMode(Context context, int mode) {
        // WakeLock 由宿主持有。
    }

    @Override
    public void setKeepInBackground(boolean keepInBackground) {
        // 随宿主生命周期走，没有 ijk 那种后台播放概念。
    }

    @Override
    public void setScreenOnWhilePlaying(boolean screenOn) {
        // 由宿主决定，Media3 没有对应接口。
    }

    // ---------------- 画面 ----------------

    @Override
    public void setDisplay(SurfaceHolder sh) {
        applySurface(sh != null ? sh.getSurface() : null);
    }

    @Override
    public void setSurface(Surface surface) {
        applySurface(surface);
    }

    private void applySurface(Surface surface) {
        ExoPlayer player = ensurePlayer();
        if (surface != null && surface.isValid()) {
            player.setVideoSurface(surface);
        } else {
            player.clearVideoSurface();
        }
    }

    @Override
    public int getVideoWidth() {
        VideoSize size = mExoPlayer == null ? null : mExoPlayer.getVideoSize();
        return size == null ? 0 : size.width;
    }

    @Override
    public int getVideoHeight() {
        VideoSize size = mExoPlayer == null ? null : mExoPlayer.getVideoSize();
        return size == null ? 0 : size.height;
    }

    @Override
    public int getVideoSarNum() {
        return 1;
    }

    @Override
    public int getVideoSarDen() {
        return 1;
    }

    // ---------------- 其它 ----------------

    @Override
    public boolean isPlayable() {
        return mExoPlayer != null && mExoPlayer.getPlaybackState() != Player.STATE_IDLE;
    }

    @Override
    public void setLogEnabled(boolean enable) {
        // Media3 的日志开关不在这一层。
    }

    @Override
    public MediaInfo getMediaInfo() {
        MediaInfo info = new MediaInfo();
        info.mMediaPlayerName = "media3";
        if (mExoPlayer == null)
            return info;
        Format videoFormat = mExoPlayer.getVideoFormat();
        Format audioFormat = mExoPlayer.getAudioFormat();
        if (videoFormat != null) {
            info.mVideoDecoder = videoFormat.sampleMimeType;
        }
        if (audioFormat != null) {
            info.mAudioDecoder = audioFormat.sampleMimeType;
        }
        return info;
    }

    @Override
    public ITrackInfo[] getTrackInfo() {
        return new ITrackInfo[0];
    }
}