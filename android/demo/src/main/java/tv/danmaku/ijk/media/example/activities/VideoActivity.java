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
import android.database.Cursor;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.OpenableColumns;

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
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewGroup;
import android.widget.TextView;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;

import tv.danmaku.ijk.media.player.FSHudView;
import tv.danmaku.ijk.media.player.IjkMediaPlayer;
import tv.danmaku.ijk.media.example.services.MediaPlayerService;
import tv.danmaku.ijk.media.example.widget.media.MediaPlayerCompat;
import tv.danmaku.ijk.media.player.misc.ITrackInfo;
import tv.danmaku.ijk.media.example.R;
import tv.danmaku.ijk.media.example.application.Settings;
import tv.danmaku.ijk.media.example.content.RecentMediaStorage;
import tv.danmaku.ijk.media.example.content.ZlistParser;
import tv.danmaku.ijk.media.example.fragments.PlaylistFragment;
import tv.danmaku.ijk.media.example.fragments.TracksFragment;
import tv.danmaku.ijk.media.example.widget.media.AndroidMediaController;
import tv.danmaku.ijk.media.example.widget.media.IjkVideoView;
import tv.danmaku.ijk.media.example.widget.media.MeasureHelper;

public class VideoActivity extends AppCompatActivity implements TracksFragment.ITrackHolder, PlaylistFragment.IPlaylistHolder {
    private static final String TAG = "VideoActivity";

    private String mVideoPath;
    private Uri    mVideoUri;

    private AndroidMediaController mMediaController;
    private IjkVideoView mVideoView;
    private TextView mToastTextView;
    private FSHudView mHudView;
    private DrawerLayout mDrawerLayout;
    private ViewGroup mRightDrawer;
    /** 上下拖拽时跟手移动的预览层，见 setupPlaylistSwipe()。 */
    private View mSwipePreview;
    private TextView mSwipePreviewLabel;

    private Settings mSettings;
    private boolean mBackPressed;

    private ArrayList<String> mPlaylist;
    private int mPlaylistIndex = 0;

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

        // zlist 播放列表：微信「用其他应用打开」.zlist 时解析，默认播第一条
        resolveZlist(intent, intentAction);

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
        mSwipePreview = findViewById(R.id.swipe_preview);
        mSwipePreviewLabel = (TextView) findViewById(R.id.swipe_preview_label);

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
        setupPlaylistSwipe();
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
        if (mPlaylist == null || mPlaylist.isEmpty()) {
            MenuItem item = menu.findItem(R.id.action_show_playlist);
            if (item != null)
                item.setVisible(false);
        }
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
                showToast("Audio channel: switch Settings > Player to IJK Media Player");
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
                showToast("Rotate: switch Settings > Player to IJK Media Player");
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
        } else if (id == R.id.action_show_playlist) {
            if (mPlaylist == null || mPlaylist.isEmpty())
                return true;
            if (mDrawerLayout.isDrawerOpen(mRightDrawer)) {
                Fragment f = getSupportFragmentManager().findFragmentById(R.id.right_drawer);
                if (f != null) {
                    FragmentTransaction transaction = getSupportFragmentManager().beginTransaction();
                    transaction.remove(f);
                    transaction.commit();
                }
                mDrawerLayout.closeDrawer(mRightDrawer);
            } else {
                Fragment f = PlaylistFragment.newInstance();
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

    // ---------------- zlist 播放列表 ----------------

    /** 从 intent 里识别并解析 .zlist，把第一条地址当作当前播放源。 */
    private void resolveZlist(Intent intent, String intentAction) {
        Uri zlistUri = null;
        if (Intent.ACTION_VIEW.equals(intentAction)) {
            zlistUri = intent.getData();
        } else if (Intent.ACTION_SEND.equals(intentAction)) {
            zlistUri = mVideoUri;
        }
        if (zlistUri == null && mVideoPath != null && mVideoPath.toLowerCase().endsWith(".zlist")) {
            zlistUri = Uri.fromFile(new File(mVideoPath));
        }
        if (!isZlistUri(zlistUri, intent.getType()))
            return;

        mPlaylist = loadPlaylist(zlistUri);
        if (mPlaylist != null && !mPlaylist.isEmpty()) {
            mVideoPath = mPlaylist.get(0);
            mPlaylistIndex = 0;
        } else {
            mPlaylist = null;
        }
    }

    private boolean isZlistUri(Uri uri, String type) {
        if (uri == null)
            return false;
        String scheme = uri.getScheme();
        if ("file".equals(scheme)) {
            String path = uri.getPath();
            return path != null && path.toLowerCase().endsWith(".zlist");
        }
        if ("content".equals(scheme)) {
            String name = queryDisplayName(uri);
            if (name != null && name.toLowerCase().endsWith(".zlist"))
                return true;
            return "application/octet-stream".equals(type) || "text/plain".equals(type);
        }
        return false;
    }

    private String queryDisplayName(Uri uri) {
        Cursor cursor = null;
        try {
            cursor = getContentResolver().query(uri, null, null, null, null);
            if (cursor != null && cursor.moveToFirst()) {
                int idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (idx >= 0)
                    return cursor.getString(idx);
            }
        } catch (Exception ignored) {
        } finally {
            if (cursor != null)
                cursor.close();
        }
        return null;
    }

    private ArrayList<String> loadPlaylist(Uri uri) {
        InputStream in = null;
        try {
            if ("content".equals(uri.getScheme())) {
                in = getContentResolver().openInputStream(uri);
            } else if ("file".equals(uri.getScheme())) {
                in = new FileInputStream(uri.getPath());
            } else {
                return null;
            }
            return ZlistParser.parse(in);
        } catch (Exception e) {
            Log.e(TAG, "Failed to load zlist: " + uri, e);
            return null;
        } finally {
            if (in != null) {
                try {
                    in.close();
                } catch (IOException ignored) {
                }
            }
        }
    }

    /** 播放列表切换中的守卫：一次只允许一个视频在准备/重建，避免 native 侧播放器反复销毁重建。 */
    private boolean mPlaylistSwitching = false;

    private void playUrlAtIndex(int index) {
        if (mPlaylist == null || index < 0 || index >= mPlaylist.size())
            return;
        if (mVideoView.isPreparing() || mPlaylistSwitching) {
            // 正在准备 / 正在切换：此时 stopPlayback+setVideoPath 会在主线程阻塞（ANR），
            // 而且 native 侧上一次的播放器可能还没完全销毁，反复重建会踩坏堆。忽略这次手势。
            return;
        }
        mPlaylistSwitching = true;
        mPlaylistIndex = index;
        mVideoView.stopPlayback();
        mVideoView.setVideoPath(mPlaylist.get(index));
        mVideoView.start();
        // native 侧播放器重建完成前不接受下一次切换；onPrepared 里也会清，这里兜个底
        mVideoView.postDelayed(() -> mPlaylistSwitching = false, 1500);
    }

    /**
     * 切换预览的色块占位：没做封面图之前，用按序号取色 + 轻微渐变代替「下一条的视频」，
     * 让「下面还有一条」这件事有实感。序号做色相偏移，所以相邻两条颜色必然不同。
     */
    private int previewColorFor(int index) {
        float[] hsv = {((index * 47) % 360) / 360f, 0.62f, 0.55f};
        return Color.HSVToColor(hsv);
    }

    /** 有播放列表时的上下拖拽切换视频：上拖预览下一条、下拖预览上一条，松手过半才真正切换。 */
    private void setupPlaylistSwipe() {
        if (mPlaylist == null || mPlaylist.size() <= 1)
            return;
        final float slop = ViewConfiguration.get(this).getScaledTouchSlop();
        final float previewHeight = Math.max(mVideoView.getHeight(), 1);
        final int threshold = (int) (previewHeight / 2);

        mVideoView.setOnTouchListener(new View.OnTouchListener() {
            private float downX;
            private float downY;
            private boolean tracking;
            private int candidate = -1;

            @Override
            public boolean onTouch(View v, MotionEvent event) {
                switch (event.getActionMasked()) {
                    case MotionEvent.ACTION_DOWN:
                        downX = event.getX();
                        downY = event.getY();
                        tracking = false;
                        candidate = -1;
                        // 必须消费 DOWN 才能收到后续 MOVE/UP，进而判断滑动
                        return true;

                    case MotionEvent.ACTION_MOVE: {
                        float dy = event.getY() - downY;
                        float dx = event.getX() - downX;
                        // 超过触摸阈值、且垂直方向占优，才把这次手势当作拖拽切换
                        if (!tracking && Math.abs(dy) > slop && Math.abs(dy) > Math.abs(dx)) {
                            tracking = true;
                            candidate = mPlaylistIndex + (dy < 0 ? 1 : -1);
                            if (candidate < 0 || candidate >= mPlaylist.size()) {
                                // 头尾不循环：到边了就直接放弃这次切换
                                candidate = -1;
                                tracking = false;
                                return true;
                            }
                            showSwipePreview(candidate);
                        }
                        if (tracking && candidate >= 0)
                            moveSwipePreview(dy, threshold);
                        return true;
                    }

                    case MotionEvent.ACTION_UP:
                    case MotionEvent.ACTION_CANCEL: {
                        if (!tracking || candidate < 0) {
                            hideSwipePreview();
                            // 没成拖拽手势 = 点击：切换媒体控制条
                            // （替代被 OnTouchListener 拦掉的 IjkVideoView.onTouchEvent 行为）
                            if (event.getActionMasked() == MotionEvent.ACTION_UP) {
                                if (mMediaController.isShowing()) {
                                    mMediaController.hide();
                                } else {
                                    mMediaController.show();
                                }
                            }
                            return true;
                        }
                        float dy = event.getY() - downY;
                        if (Math.abs(dy) > threshold) {
                            // 露出过半：预览落位，再重建播放器加载新地址
                            commitSwipePreview();
                            playUrlAtIndex(candidate);
                        } else {
                            // 没过半：预览弹回原位，什么都不做
                            cancelSwipePreview();
                        }
                        tracking = false;
                        candidate = -1;
                        return true;
                    }

                    default:
                        return true;
                }
            }

            private void showSwipePreview(int index) {
                mSwipePreview.setBackgroundColor(previewColorFor(index));
                mSwipePreviewLabel.setText((index + 1) + ". " + PlaylistFragment.displayName(mPlaylist.get(index)));
                mSwipePreview.setVisibility(View.VISIBLE);
            }

            /** 跟手：位移取绝对值封顶到整屏，保证不会拖过头把预览甩出屏幕。 */
            private void moveSwipePreview(float dy, int threshold) {
                float offset = Math.max(-1f, Math.min(1f, dy / (float) threshold));
                mSwipePreview.setTranslationY(offset * threshold);
            }

            private void hideSwipePreview() {
                mSwipePreview.animate().cancel();
                mSwipePreview.setTranslationY(0);
                mSwipePreview.setVisibility(View.GONE);
            }

            private void commitSwipePreview() {
                mSwipePreview.animate()
                        .translationY(0)
                        .setDuration(180)
                        .withEndAction(() -> mSwipePreview.setVisibility(View.GONE))
                        .start();
            }

            private void cancelSwipePreview() {
                mSwipePreview.animate()
                        .translationY(0)
                        .setDuration(180)
                        .withEndAction(() -> mSwipePreview.setVisibility(View.GONE))
                        .start();
            }
        });
    }

    @Override
    public List<String> getPlaylist() {
        return mPlaylist;
    }

    @Override
    public int getCurrentPlaylistIndex() {
        return mPlaylistIndex;
    }

    @Override
    public void onPlaylistItemSelected(int index) {
        playUrlAtIndex(index);
        if (mDrawerLayout.isDrawerOpen(mRightDrawer)) {
            mDrawerLayout.closeDrawer(mRightDrawer);
        }
    }
}
