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

package tv.danmaku.ijk.media.example.activities;

import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;

import androidx.appcompat.app.ActionBar;
import androidx.appcompat.widget.Toolbar;
import androidx.fragment.app.Fragment;
import androidx.fragment.app.FragmentTransaction;
import androidx.drawerlayout.widget.DrawerLayout;
import androidx.appcompat.app.AppCompatActivity;
import android.text.TextUtils;
import android.util.Log;
import android.util.TypedValue;
import android.view.Menu;
import android.view.MenuItem;
import android.view.ViewGroup;
import android.widget.TextView;

import tv.danmaku.ijk.media.player.FSHudView;
import tv.danmaku.ijk.media.player.IjkMediaPlayer;
import tv.danmaku.ijk.media.example.services.MediaPlayerService;
import tv.danmaku.ijk.media.example.widget.media.MediaPlayerCompat;
import tv.danmaku.ijk.media.player.misc.ITrackInfo;
import tv.danmaku.ijk.media.example.R;
import tv.danmaku.ijk.media.example.application.Settings;
import tv.danmaku.ijk.media.example.content.RecentMediaStorage;
import tv.danmaku.ijk.media.example.fragments.TracksFragment;
import tv.danmaku.ijk.media.example.widget.media.AndroidMediaController;
import tv.danmaku.ijk.media.example.widget.media.IjkVideoView;
import tv.danmaku.ijk.media.example.widget.media.MeasureHelper;

public class VideoActivity extends AppCompatActivity implements TracksFragment.ITrackHolder {
    private static final String TAG = "VideoActivity";

    private String mVideoPath;
    private Uri    mVideoUri;

    private AndroidMediaController mMediaController;
    private IjkVideoView mVideoView;
    private TextView mToastTextView;
    private FSHudView mHudView;
    private DrawerLayout mDrawerLayout;
    private ViewGroup mRightDrawer;

    private Settings mSettings;
    private boolean mBackPressed;

    public static Intent newIntent(Context context, String videoPath, String videoTitle) {
        Intent intent = new Intent(context, VideoActivity.class);
        intent.putExtra("videoPath", videoPath);
        intent.putExtra("videoTitle", videoTitle);
        return intent;
    }

    public static void intentTo(Context context, String videoPath, String videoTitle) {
        context.startActivity(newIntent(context, videoPath, videoTitle));
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_player);

        mSettings = new Settings(this);

        // handle arguments
        mVideoPath = getIntent().getStringExtra("videoPath");

        Intent intent = getIntent();
        String intentAction = intent.getAction();
        if (!TextUtils.isEmpty(intentAction)) {
            if (intentAction.equals(Intent.ACTION_VIEW)) {
                mVideoPath = intent.getDataString();
            } else if (intentAction.equals(Intent.ACTION_SEND)) {
                mVideoUri = intent.getParcelableExtra(Intent.EXTRA_STREAM);
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.ICE_CREAM_SANDWICH) {
                    String scheme = mVideoUri.getScheme();
                    if (TextUtils.isEmpty(scheme)) {
                        Log.e(TAG, "Null unknown scheme\n");
                        finish();
                        return;
                    }
                    if (scheme.equals(ContentResolver.SCHEME_ANDROID_RESOURCE)) {
                        mVideoPath = mVideoUri.getPath();
                    } else if (scheme.equals(ContentResolver.SCHEME_CONTENT)) {
                        Log.e(TAG, "Can not resolve content below Android-ICS\n");
                        finish();
                        return;
                    } else {
                        Log.e(TAG, "Unknown scheme " + scheme + "\n");
                        finish();
                        return;
                    }
                }
            }
        }

        if (!TextUtils.isEmpty(mVideoPath)) {
            new RecentMediaStorage(this).saveUrlAsync(mVideoPath);
        }

        // init UI
        Toolbar toolbar = (Toolbar) findViewById(R.id.toolbar);
        setSupportActionBar(toolbar);

        ActionBar actionBar = getSupportActionBar();
        mMediaController = new AndroidMediaController(this, false);
        mMediaController.setSupportActionBar(actionBar);

        mToastTextView = (TextView) findViewById(R.id.toast_text_view);
        mHudView = (FSHudView) findViewById(R.id.hud_view);
        mDrawerLayout = (DrawerLayout) findViewById(R.id.drawer_layout);
        mRightDrawer = (ViewGroup) findViewById(R.id.right_drawer);

        mDrawerLayout.setScrimColor(Color.TRANSPARENT);

        // init player
        IjkMediaPlayer.loadLibrariesOnce(null);
        IjkMediaPlayer.native_profileBegin("libijkplayer.so");

        mVideoView = (IjkVideoView) findViewById(R.id.video_view);
        mVideoView.setMediaController(mMediaController);
        mVideoView.setHudView(mHudView);
        // HUD 卡片放到工具栏下面（间距 15dp）：按主题的 actionBarSize 取工具栏高度，
        // 这样工具栏被媒体控制器隐藏时卡片位置也不会跳。
        TypedValue actionBarSize = new TypedValue();
        if (getTheme().resolveAttribute(androidx.appcompat.R.attr.actionBarSize, actionBarSize, true)) {
            int toolbarHeight = TypedValue.complexToDimensionPixelSize(actionBarSize.data,
                    getResources().getDisplayMetrics());
            ViewGroup.MarginLayoutParams hudLp = (ViewGroup.MarginLayoutParams) mHudView.getLayoutParams();
            hudLp.topMargin = toolbarHeight + hudLp.topMargin;
            mHudView.setLayoutParams(hudLp);
        }
        // 可用 intent extra "hud"（0/1）起播就显示统计卡片，供脚本使用
        mVideoView.setShouldShowHudView(getIntent().getIntExtra("hud", 0) != 0);
        // prefer mVideoPath
        if (mVideoPath != null)
            mVideoView.setVideoPath(mVideoPath);
        else if (mVideoUri != null)
            mVideoView.setVideoURI(mVideoUri);
        else {
            Log.e(TAG, "Null Data Source\n");
            finish();
            return;
        }
        mVideoView.start();
    }

    @Override
    public void onBackPressed() {
        mBackPressed = true;

        super.onBackPressed();
    }

    @Override
    protected void onStop() {
        super.onStop();

        if (mBackPressed || !mVideoView.isBackgroundPlayEnabled()) {
            mVideoView.stopPlayback();
            mVideoView.release(true);
            mVideoView.stopBackgroundPlay();
        } else {
            mVideoView.enterBackground();
        }
        IjkMediaPlayer.native_profileEnd();
    }

    /** 拿当前播放器（系统播放器/代理包装时返回 null）。 */
    private IjkMediaPlayer getIjkPlayer() {
        return MediaPlayerCompat.getIjkMediaPlayer(MediaPlayerService.getMediaPlayer());
    }

    /** 复用 demo 的 toast 展示方式。 */
    private void showToast(int resId) {
        mToastTextView.setText(resId);
        mMediaController.showOnce(mToastTextView);
    }

    private void showToast(String text) {
        mToastTextView.setText(text);
        mMediaController.showOnce(mToastTextView);
    }

    @Override
    public boolean onCreateOptionsMenu(Menu menu) {
        getMenuInflater().inflate(R.menu.menu_player, menu);
        return true;
    }

    @Override
    public boolean onOptionsItemSelected(MenuItem item) {
        int id = item.getItemId();
        if (id == R.id.action_toggle_ratio) {
            int aspectRatio = mVideoView.toggleAspectRatio();
            String aspectRatioText = MeasureHelper.getAspectRatioText(this, aspectRatio);
            mToastTextView.setText(aspectRatioText);
            mMediaController.showOnce(mToastTextView);
            return true;
        } else if (id == R.id.action_toggle_player) {
            int player = mVideoView.togglePlayer();
            String playerText = IjkVideoView.getPlayerText(this, player);
            mToastTextView.setText(playerText);
            mMediaController.showOnce(mToastTextView);
            return true;
        } else if (id == R.id.action_toggle_render) {
            int render = mVideoView.toggleRender();
            String renderText = IjkVideoView.getRenderText(this, render);
            mToastTextView.setText(renderText);
            mMediaController.showOnce(mToastTextView);
            return true;
        } else if (id == R.id.action_toggle_hud) {
            boolean shown = mVideoView.toggleHudView();
            mToastTextView.setText(shown ? R.string.hud_on : R.string.hud_off);
            mMediaController.showOnce(mToastTextView);
            return true;
        } else if (id == R.id.action_show_info) {
            mVideoView.showMediaInfo();
        } else if (id == R.id.action_audio_channel) {
            // 新 API 演示：声道选择（对应 iOS 的 setAudioChannel:）
            IjkMediaPlayer mp = getIjkPlayer();
            if (mp == null) {
                showToast("Audio channel: ijkplayer only");
                return true;
            }
            int channel = mp.getAudioChannel();
            if (channel == IjkMediaPlayer.AUDIO_CHANNEL_STEREO) {
                channel = IjkMediaPlayer.AUDIO_CHANNEL_LEFT;
            } else if (channel == IjkMediaPlayer.AUDIO_CHANNEL_LEFT) {
                channel = IjkMediaPlayer.AUDIO_CHANNEL_RIGHT;
            } else {
                channel = IjkMediaPlayer.AUDIO_CHANNEL_STEREO;
            }
            mp.setAudioChannel(channel);
            showToast(channel == IjkMediaPlayer.AUDIO_CHANNEL_STEREO ? R.string.audio_channel_stereo
                    : channel == IjkMediaPlayer.AUDIO_CHANNEL_LEFT ? R.string.audio_channel_left
                    : R.string.audio_channel_right);
            return true;
        } else if (id == R.id.action_rotate_x || id == R.id.action_rotate_y
                || id == R.id.action_rotate_z || id == R.id.action_rotate_reset) {
            // 新 API 演示：画面三轴旋转（对应 iOS 的 x/y/zRotateDegrees）
            IjkMediaPlayer mp = getIjkPlayer();
            if (mp == null) {
                showToast("Rotate: ijkplayer only");
                return true;
            }
            float x = mp.getXRotateDegrees();
            float y = mp.getYRotateDegrees();
            float z = mp.getZRotateDegrees();
            // 步进取 90 的整数倍：Z +90 是平面内旋转（会交换宽高，最有意义的一档）；
            // X/Y 在正好 90 度时是侧视（画面退化成一条线），所以用 180 度翻转。
            if (id == R.id.action_rotate_x) {
                x += 180;
            } else if (id == R.id.action_rotate_y) {
                y += 180;
            } else if (id == R.id.action_rotate_z) {
                z += 90;
            } else {
                x = y = z = 0;
            }
            mp.setRotateDegrees(x, y, z);
            showToast(String.format("Rotate X %.0f  Y %.0f  Z %.0f", x, y, z));
            return true;
        } else if (id == R.id.action_show_tracks) {
            if (mDrawerLayout.isDrawerOpen(mRightDrawer)) {
                Fragment f = getSupportFragmentManager().findFragmentById(R.id.right_drawer);
                if (f != null) {
                    FragmentTransaction transaction = getSupportFragmentManager().beginTransaction();
                    transaction.remove(f);
                    transaction.commit();
                }
                mDrawerLayout.closeDrawer(mRightDrawer);
            } else {
                Fragment f = TracksFragment.newInstance();
                FragmentTransaction transaction = getSupportFragmentManager().beginTransaction();
                transaction.replace(R.id.right_drawer, f);
                transaction.commit();
                mDrawerLayout.openDrawer(mRightDrawer);
            }
        }

        return super.onOptionsItemSelected(item);
    }

    @Override
    public ITrackInfo[] getTrackInfo() {
        if (mVideoView == null)
            return null;

        return mVideoView.getTrackInfo();
    }

    @Override
    public void selectTrack(int stream) {
        mVideoView.selectTrack(stream);
    }

    @Override
    public void deselectTrack(int stream) {
        mVideoView.deselectTrack(stream);
    }

    @Override
    public int getSelectedTrack(int trackType) {
        if (mVideoView == null)
            return -1;

        return mVideoView.getSelectedTrack(trackType);
    }
}
