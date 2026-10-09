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

package com.debugly.fsplayer.demo.activities;

import android.animation.Animator;
import android.animation.AnimatorListenerAdapter;
import android.animation.ValueAnimator;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.res.Configuration;
import android.database.Cursor;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.OpenableColumns;

import androidx.annotation.NonNull;
import androidx.appcompat.app.ActionBar;
import androidx.appcompat.widget.Toolbar;
import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsCompat;
import androidx.core.view.WindowInsetsControllerCompat;
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
import android.view.animation.DecelerateInterpolator;
import android.widget.TextView;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;

import com.debugly.fsplayer.player.FSHudView;
import com.debugly.fsplayer.player.FSPlayer;
import com.debugly.fsplayer.demo.services.MediaPlayerService;
import com.debugly.fsplayer.demo.widget.media.MediaPlayerCompat;
import com.debugly.fsplayer.player.misc.ITrackInfo;
import com.debugly.fsplayer.demo.R;
import com.debugly.fsplayer.demo.application.Settings;
import com.debugly.fsplayer.demo.content.RecentMediaStorage;
import com.debugly.fsplayer.demo.content.ZlistParser;
import com.debugly.fsplayer.demo.fragments.PlaylistFragment;
import com.debugly.fsplayer.demo.fragments.TracksFragment;
import com.debugly.fsplayer.demo.widget.media.AndroidMediaController;
import com.debugly.fsplayer.demo.widget.media.FSVideoView;
import com.debugly.fsplayer.demo.widget.media.MeasureHelper;

public class VideoActivity extends AppCompatActivity implements TracksFragment.ITrackHolder, PlaylistFragment.IPlaylistHolder {
    private static final String TAG = "VideoActivity";

    private String mVideoPath;
    private Uri    mVideoUri;

    private AndroidMediaController mMediaController;
    private FSVideoView mVideoView;
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

    /**
     * 带播放列表进入播放器：把整个列表和当前项的下标一起传过去，
     * 这样播放页的播放列表（上滑切换、列表抽屉、播完自动下一条）
     * 就是来源页展示的那份，而不是空列表。
     */
    public static void intentTo(Context context, String videoPath, String videoTitle,
                                ArrayList<String> playlist, int playlistIndex) {
        Intent intent = newIntent(context, videoPath, videoTitle);
        if (playlist != null && playlist.size() > 1) {
            intent.putStringArrayListExtra("videoPlaylist", new ArrayList<>(playlist));
            intent.putExtra("videoPlaylistIndex", playlistIndex);
        }
        context.startActivity(intent);
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // 横屏时进沉浸式全屏：隐藏状态栏和导航栏，画面顶到四条边。
        // 不这样做的话系统按 insets 把窗口内缩，1272 高的屏里状态栏+导航栏要占
        // 141+56=197px（15.5%），横屏看视频时这两条栏纯属浪费。
        // 竖屏不隐藏，保持和列表页一致的行为。
        getWindow().setDecorFitsSystemWindows(false);
        applyImmersive();

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

        // 来源页（示例列表、文件列表等）带过来的播放列表：
        // 整份列表 + 当前播放项的下标，两者要成对使用。
        if (mPlaylist == null) {
            ArrayList<String> carried = intent.getStringArrayListExtra("videoPlaylist");
            if (carried != null && !carried.isEmpty()) {
                mPlaylist = carried;
                mPlaylistIndex = intent.getIntExtra("videoPlaylistIndex", 0);
                if (mPlaylistIndex < 0 || mPlaylistIndex >= mPlaylist.size())
                    mPlaylistIndex = 0;
                if (!TextUtils.isEmpty(mVideoPath))
                    mPlaylistIndex = mPlaylist.indexOf(mVideoPath);
                if (mPlaylistIndex < 0)
                    mPlaylistIndex = 0;
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
        mSwipePreview = findViewById(R.id.swipe_preview);
        mSwipePreviewLabel = (TextView) findViewById(R.id.swipe_preview_label);

        mDrawerLayout.setScrimColor(Color.TRANSPARENT);

        // init player
        FSPlayer.loadLibrariesOnce(null);
        FSPlayer.native_profileBegin("libijkplayer.so");

        mVideoView = (FSVideoView) findViewById(R.id.video_view);
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
        mVideoView.setOnCompletionListener(mp -> {
            // 播完自动接下一条；已经是最后一条就停在原地。
            if (mPlaylist == null || mPlaylistSwitching)
                return;
            int next = mPlaylistIndex + 1;
            if (next >= mPlaylist.size())
                return;
            mVideoView.postDelayed(() -> {
                if (mPlaylist != null && !mPlaylistSwitching && next < mPlaylist.size())
                    playUrlAtIndex(next);
            }, 300);
        });
        mVideoView.start();
    }

    @Override
    public void onBackPressed() {
        mBackPressed = true;

        super.onBackPressed();
    }

    /**
     * Activity 声明了 configChanges="orientation|screenSize"，所以旋转不会重建 Activity，
     * 这里必须自己把新尺寸告诉播放器视图：没有这次 requestLayout，按旧宽高算出来的
     * MeasureHelper 结果会继续生效，画面就会停在旧比例上被拉伸。
     */
    @Override
    public void onConfigurationChanged(@NonNull Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        // 横竖屏切换要重新决定要不要沉浸式
        applyImmersive();
        // 手势进行到一半被旋转打断的话，播放器会停在非零位移上，直接归位
        resetSwipeTranslation();
        if (mVideoView != null) {
            mVideoView.requestLayout();
            // 旋转期间 MediaController 也得重新贴底，否则进度条位置会停在旧方向
            mVideoView.invalidate();
        }
    }

    /**
     * 只在横屏时隐藏系统栏。
     *
     * 坑：setDecorFitsSystemWindows(false) 是全局开关，一开竖屏的内容也会顶进状态栏，
     * 工具栏上半截直接被盖住。所以竖屏必须把它设回 true，让系统重新做 insets 内缩。
     *
     * immersive 状态会在用户划一下（临时显示状态栏）后被系统清掉，
     * 所以 onConfigurationChanged / onResume 都要重新贴一次。
     */
    private void applyImmersive() {
        int orientation = getResources().getConfiguration().orientation;
        boolean landscape = orientation == Configuration.ORIENTATION_LANDSCAPE;

        WindowInsetsControllerCompat controller =
                WindowCompat.getInsetsController(getWindow(), getWindow().getDecorView());
        if (landscape) {
            getWindow().setDecorFitsSystemWindows(false);
            controller.hide(WindowInsetsCompat.Type.systemBars());
            controller.setSystemBarsBehavior(
                    WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        } else {
            // 转回竖屏：把窗口交还给 insets 处理，否则工具栏会被状态栏切掉一截
            getWindow().setDecorFitsSystemWindows(true);
            controller.show(WindowInsetsCompat.Type.systemBars());
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        // 用户从屏幕边缘划一下会临时唤出系统栏，把 immersive 状态清掉，
        // 回到前台时要重新贴上，否则横屏时会莫名其妙多出两条栏。
        applyImmersive();
    }

    @Override
    protected void onStop() {
        resetSwipeTranslation();
        super.onStop();

        if (mBackPressed || !mVideoView.isBackgroundPlayEnabled()) {
            mVideoView.stopPlayback();
            mVideoView.release(true);
            mVideoView.stopBackgroundPlay();
        } else {
            mVideoView.enterBackground();
        }
        FSPlayer.native_profileEnd();
    }

    /**
     * 拿当前正在使用的 FSPlayer（系统播放器/代理包装时返回 null）。
     *
     * 必须从 mVideoView 取：MediaPlayerService.getMediaPlayer() 的静态字段只有
     * 后台播放（initBackground/enterBackground）才会被赋值，前台播放一直是 null，
     * 用它会让声道切换、三轴旋转这些菜单永远提示"请切换播放器"。
     */
    private FSPlayer getFSPlayer() {
        if (mVideoView == null) {
            return null;
        }
        return MediaPlayerCompat.getFSPlayer(mVideoView.getMediaPlayer());
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
        // 渲染器只有一种可选时，切换是空操作，直接不露这个入口。
        MenuItem renderItem = menu.findItem(R.id.action_toggle_render);
        if (renderItem != null)
            renderItem.setVisible(mVideoView != null && mVideoView.canToggleRender());
        // HUD 统计卡片由 ijkplayer 驱动，换成别的后端就没有这张卡片可显示。
        MenuItem hudItem = menu.findItem(R.id.action_toggle_hud);
        if (hudItem != null)
            hudItem.setVisible(mVideoView != null && mVideoView.canToggleHudView());
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
            String playerText = FSVideoView.getPlayerText(this, player);
            mToastTextView.setText(playerText);
            mMediaController.showOnce(mToastTextView);
            return true;
        } else if (id == R.id.action_toggle_render) {
            int render = mVideoView.toggleRender();
            String renderText = FSVideoView.getRenderText(this, render);
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
            FSPlayer mp = getFSPlayer();
            if (mp == null) {
                showToast(R.string.need_fs_player);
                return true;
            }
            int channel = mp.getAudioChannel();
            if (channel == FSPlayer.AUDIO_CHANNEL_STEREO) {
                channel = FSPlayer.AUDIO_CHANNEL_LEFT;
            } else if (channel == FSPlayer.AUDIO_CHANNEL_LEFT) {
                channel = FSPlayer.AUDIO_CHANNEL_RIGHT;
            } else {
                channel = FSPlayer.AUDIO_CHANNEL_STEREO;
            }
            mp.setAudioChannel(channel);
            showToast(channel == FSPlayer.AUDIO_CHANNEL_STEREO ? R.string.audio_channel_stereo
                    : channel == FSPlayer.AUDIO_CHANNEL_LEFT ? R.string.audio_channel_left
                    : R.string.audio_channel_right);
            return true;
        } else if (id == R.id.action_rotate_x || id == R.id.action_rotate_y
                || id == R.id.action_rotate_z || id == R.id.action_rotate_reset) {
            // 新 API 演示：画面三轴旋转（对应 iOS 的 x/y/zRotateDegrees）
            FSPlayer mp = getFSPlayer();
            if (mp == null) {
                showToast(R.string.need_fs_player);
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
            // 正在准备 / 正在切换：此时 setVideoPath 会在主线程阻塞（ANR），
            // 而且 native 侧上一次的播放器可能还没完全销毁，反复重建会踩坏堆。忽略这次手势。
            return;
        }
        mPlaylistSwitching = true;
        mPlaylistIndex = index;
        // 优先复用当前播放器实例切数据源，避免 openVideo() 里「销毁旧 ffp + 立刻新建」
        // 挤在同一调用栈导致的 native 崩溃；没有可复用实例时（冷启动）才退回冷启动路径。
        if (!mVideoView.switchToUrl(mPlaylist.get(index))) {
            mVideoView.setVideoPath(mPlaylist.get(index));
        }
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

    /**
     * 有播放列表时的上下拖拽切换视频：上拖看下一条、下拖看上一条，跟手滑动，
     * 松手时预览已经露出过半才真正重建播放器加载新地址，头尾不循环。
     *
     * 关键点是预览层初始停在屏幕外（上拖时在下方 -height 处，下拖时在上方 +height 处），
     * 而不是一开始就在原位——那样第一帧就铺满全屏，看起来像"啪"地盖上去，没有滑动的过程。
     * 位移按阻尼映射到 [-1, 1]，封顶到刚好露出整屏。
     */
    private void setupPlaylistSwipe() {
        if (mPlaylist == null || mPlaylist.size() <= 1)
            return;
        final float slop = ViewConfiguration.get(this).getScaledTouchSlop();

        mVideoView.setOnTouchListener(new View.OnTouchListener() {
            private float downX;
            private float downY;
            private boolean tracking;
            private int candidate = -1;
            /** -1 表示预览在下方向上滑，+1 表示在上方向下滑 */
            private int direction;

            @Override
            public boolean onTouch(View v, MotionEvent event) {
                switch (event.getActionMasked()) {
                    case MotionEvent.ACTION_DOWN:
                        // 用屏幕坐标：mVideoView 自己在被 setTranslationY 推着走，
                        // getX()/getY() 是它的本地坐标，会跟着位移变化，手指不动 dy 也会变，
                        // 形成「移动 → dy 变小 → 退回 → dy 变大」的反馈抖动。
                        downX = event.getRawX();
                        downY = event.getRawY();
                        tracking = false;
                        candidate = -1;
                        // 必须消费 DOWN 才能收到后续 MOVE/UP，进而判断滑动
                        return true;

                    case MotionEvent.ACTION_MOVE: {
                        float dy = event.getRawY() - downY;
                        float dx = event.getRawX() - downX;
                        // 超过触摸阈值、且垂直方向占优，才把这次手势当作拖拽切换
                        if (!tracking && Math.abs(dy) > slop && Math.abs(dy) > Math.abs(dx)) {
                            tracking = true;
                            direction = dy < 0 ? -1 : 1;
                            candidate = mPlaylistIndex - direction;
                            if (candidate < 0 || candidate >= mPlaylist.size()) {
                                // 头尾不循环：到边了就直接放弃这次切换
                                candidate = -1;
                                tracking = false;
                                return true;
                            }
                            showSwipePreview(candidate, direction);
                        }
                        if (tracking && candidate >= 0)
                            moveSwipe(dy);
                        return true;
                    }

                    case MotionEvent.ACTION_UP:
                    case MotionEvent.ACTION_CANCEL: {
                        if (!tracking || candidate < 0) {
                            hideSwipePreview();
                            // 没成拖拽手势 = 点击：切换媒体控制条
                            // （替代被 OnTouchListener 拦掉的 FSVideoView.onTouchEvent 行为）
                            if (event.getActionMasked() == MotionEvent.ACTION_UP) {
                                if (mMediaController.isShowing()) {
                                    mMediaController.hide();
                                } else {
                                    mMediaController.show();
                                }
                            }
                            return true;
                        }
                        // 先把 index 存下来：下面立刻会把 candidate 清零，
                        // 而切视频要等落位动画结束才执行（见 commitSwipePreview）
                        final int target = candidate;
                        if (isPreviewPastHalfway()) {
                            // 露出过半：补齐剩下的距离，落位后重建播放器加载新地址
                            commitSwipePreview(target);
                        } else {
                            // 没过半：退回起点，什么都不做
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

            /** 预览层在屏幕外的静止位置：上拖时藏在下方，下拖时藏在上方。 */
            private float parkedTranslation() {
                int h = mSwipePreview.getHeight();
                return direction < 0 ? h : -h;
            }

            private void showSwipePreview(int index, int dir) {
                mSwipePreview.setBackgroundColor(previewColorFor(index));
                mSwipePreviewLabel.setText((index + 1) + ". " + PlaylistFragment.displayName(mPlaylist.get(index)));
                mSwipePreview.setVisibility(View.VISIBLE);
                // 先摆到拼接起点（当前视频铺满、预览在屏外），第一帧绝不出现色块
                applyProgress(0f);
            }

            /** 跟手：手指拖了多远换算成 0..1 的拼接进度。 */
            private void moveSwipe(float dy) {
                int h = mSwipePreview.getHeight();
                if (h <= 0)
                    return;
                float dragged = direction < 0 ? -dy : dy;
                applyProgress(Math.max(0f, Math.min(1f, dragged / h)));
            }

            /**
             * 拼接的核心：两个 view 位移方向相反，任意时刻首尾相接拼成一条连续的长带。
             *
             * progress=0：当前视频在原位铺满，预览整个在屏幕外（起始态）
             * progress=1：当前视频移出屏幕，预览正好铺满（终态）
             *
             * 因为视频走的距离和预览走的距离相等，两者在屏幕上「接力」，
             * 既不会同时可见（不会有色块盖住画面），中间也不会露出缝隙。
             */
            private void applyProgress(float progress) {
                int h = mSwipePreview.getHeight();
                if (h <= 0)
                    return;
                // 预览迎着手势方向进场：屏幕外 → 原位
                mSwipePreview.setTranslationY(parkedTranslation() + direction * progress * h);
                // 当前视频顺着手势方向离场：原位 → 屏幕外，与预览反向
                mVideoView.setTranslationY(direction * progress * h);

                // 视频那一层是独立的合成 surface（TextureView/SurfaceView），
                // 平移父容器时它不总是跟着重绘，屏幕上会残留上一帧的位置形成重影。
                // 显式 invalidate 强制它按新位移重绘。
                mVideoView.invalidate();
            }

            /** 当前的拼接进度。 */
            private float progress() {
                int h = mSwipePreview.getHeight();
                if (h <= 0)
                    return 0f;
                return (mSwipePreview.getTranslationY() - parkedTranslation()) / (direction * h);
            }

            /** 松手判定：预览露出 15% 就算切换，不用拖过半。 */
            private boolean isPreviewPastHalfway() {
                return progress() > SWIPE_COMMIT_THRESHOLD;
            }

            /** 露到这个比例就判定切换。15% 足够明确，又不用费力拖很远。 */
            private static final float SWIPE_COMMIT_THRESHOLD = 0.15f;

            private void hideSwipePreview() {
                mSwipePreview.animate().cancel();
                mVideoView.animate().cancel();
                applyProgress(0f);
                mSwipePreview.setVisibility(View.GONE);
            }

            /**
             * 切成功：把剩下的距离补完（预览铺满、当前视频移出），再重建播放器。
             * 终点 progress=1 时两个 view 都处于「准备交棒」的姿态，接上新画面没有跳变。
             */
            private void commitSwipePreview(final int index) {
                animateProgressTo(1f, 160, () -> {
                    mSwipePreview.setVisibility(View.GONE);
                    resetSwipeTranslation();
                    playUrlAtIndex(index);
                });
            }

            /** 没切：退回拼接起点，当前视频回到原位。 */
            private void cancelSwipePreview() {
                animateProgressTo(0f, 180, () -> {
                    applyProgress(0f);
                    mSwipePreview.setVisibility(View.GONE);
                });
            }

            /**
             * 补间整个拼接进度：先用系统动画驱动「视频的位移」，
             * 每一帧再由同一个进度反推出预览的位移，保证两者永远同步、绝不脱节。
             */
            private void animateProgressTo(final float target, long duration, final Runnable end) {
                final float start = progress();
                if (Math.abs(start - target) < 0.001f) {
                    applyProgress(target);
                    end.run();
                    return;
                }
                ValueAnimator animator = ValueAnimator.ofFloat(start, target);
                animator.setDuration(duration);
                animator.setInterpolator(new DecelerateInterpolator());
                animator.addUpdateListener(a -> applyProgress((Float) a.getAnimatedValue()));
                animator.addListener(new AnimatorListenerAdapter() {
                    private boolean cancelled;

                    @Override
                    public void onAnimationCancel(Animator animation) {
                        cancelled = true;
                    }

                    @Override
                    public void onAnimationEnd(Animator animation) {
                        if (!cancelled)
                            end.run();
                    }
                });
                animator.start();
            }
        });
    }

    /** 手势被打断（旋转、切后台）时把画面归位，否则播放器会永远停在偏移的位置。 */
    private void resetSwipeTranslation() {
        if (mVideoView != null) {
            mVideoView.animate().cancel();
            mVideoView.setTranslationY(0);
        }
        if (mSwipePreview != null) {
            mSwipePreview.animate().cancel();
            mSwipePreview.setTranslationY(0);
            mSwipePreview.setVisibility(View.GONE);
        }
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
