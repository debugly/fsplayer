package com.debugly.fsplayer.demo;

import android.app.Activity;
import android.os.Bundle;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.widget.Toast;

import tv.danmaku.ijk.media.player.IMediaPlayer;
import tv.danmaku.ijk.media.player.IjkMediaPlayer;

public class MainActivity extends Activity implements SurfaceHolder.Callback {

    private IjkMediaPlayer mPlayer;
    private SurfaceView mSurfaceView;
    private String mSubtitlePath;

    // H264 + AAC MP4，软解可播放（W3C 长期托管）
    // 可用 intent extra "url" 覆盖（本地文件或网络地址）
    // 可用 intent extra "subtitle" 挂一个外挂字幕（SRT/ASS）
    private static final String TEST_URL =
            "https://media.w3.org/2010/05/sintel/trailer.mp4";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        mSurfaceView = new SurfaceView(this);
        mSurfaceView.getHolder().addCallback(this);
        setContentView(mSurfaceView);

        mSubtitlePath = getIntent() != null ? getIntent().getStringExtra("subtitle") : null;

        mPlayer = new IjkMediaPlayer();
        // MediaCodec 硬解 + Vulkan 外部显存零拷贝（设备不支持时自动回退软解）
        mPlayer.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 1);
        mPlayer.setOnPreparedListener(new IMediaPlayer.OnPreparedListener() {
            @Override
            public void onPrepared(IMediaPlayer mp) {
                mp.start();
                // 外挂字幕要在流打开之后挂（native 侧需要 is 已经建立）
                if (mSubtitlePath != null && !mSubtitlePath.isEmpty()) {
                    boolean ok = mPlayer.loadThenActiveSubtitle(mSubtitlePath);
                    Toast.makeText(MainActivity.this,
                            "loadThenActiveSubtitle(" + mSubtitlePath + ") = " + ok,
                            Toast.LENGTH_LONG).show();
                }
            }
        });
        mPlayer.setOnErrorListener(new IMediaPlayer.OnErrorListener() {
            @Override
            public boolean onError(IMediaPlayer mp, int what, int extra) {
                Toast.makeText(MainActivity.this,
                        "播放出错 what=" + what + " extra=" + extra, Toast.LENGTH_LONG).show();
                return false;
            }
        });
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        try {
            String url = getIntent() != null ? getIntent().getStringExtra("url") : null;
            if (url == null || url.isEmpty())
                url = TEST_URL;
            mPlayer.setSurface(holder.getSurface());
            mPlayer.setDataSource(url);
            mPlayer.prepareAsync();
        } catch (Exception e) {
            Toast.makeText(this, "setDataSource 失败: " + e.getMessage(), Toast.LENGTH_LONG).show();
        }
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        mPlayer.setSurface(null);
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (mPlayer != null) {
            mPlayer.release();
            mPlayer = null;
        }
    }
}
