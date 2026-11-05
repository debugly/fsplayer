package com.debugly.aura.testing;

import android.app.Activity;
import android.app.PictureInPictureParams;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.graphics.Bitmap;
import android.graphics.Rect;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.util.Rational;
import android.view.Gravity;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.Toast;

import androidx.annotation.RequiresApi;

import java.io.File;
import java.io.FileOutputStream;

import com.debugly.fsplayer.player.FSHudView;
import com.debugly.fsplayer.player.IMediaPlayer;
import com.debugly.fsplayer.player.FSPlayer;

public class MainActivity extends Activity implements SurfaceHolder.Callback {

    private static final String TAG = "FSPlayerPiP";

    private FSPlayer mPlayer;
    private SurfaceView mSurfaceView;
    private FrameLayout mRootLayout;
    private FSHudView mHudView;
    private String mSubtitlePath;
    private int mSnapshotType = -1;
    private int mSnapshotDelayMs = 4000;
    private String mBackgroundPath;
    private int mBlurIterations = FSPlayer.FS_BACKGROUND_BLUR_ITERATIONS;
    private float mBrightness;
    private float mSaturation;
    private float mContrast;
    private int mBgColor;
    private float mBlurSigma = FSPlayer.FS_BACKGROUND_BLUR_SIGMA;
    private boolean mPipOnPrepared;
    private int mPipAtMs = 3000;

    // H264 + AAC MP4，软解可播放（W3C 长期托管）
    // 可用 intent extra "url" 覆盖（本地文件或网络地址）
    // 可用 intent extra "subtitle" 挂一个外挂字幕（SRT/ASS）
    // 可用 intent extra "scaleMode" 指定缩放模式 0 等比完整显示(默认) 1 等比铺满 2 拉伸
    // 可用 intent extra "snapshotType" 在起播若干秒后截一张快照到 files/snapshot-<type>.png
    //   0 原始尺寸 1 屏幕所见(默认) 2 原始尺寸+字幕 3 原始尺寸+字幕+效果
    // 可用 intent extra "snapshotDelayMs" 改截屏延时（默认 4000）
    // 可用 intent extra "pauseAfterMs" 指定起播后多少毫秒暂停（用来验证暂停时也能截屏）
    // 可用 intent extra "background" 指定一张图（设备路径），用它的高斯模糊填充黑边
    // 可用 intent extra "blurIterations" / "blurSigma"（float）调模糊参数（默认 3 / 30）
    // 可用 intent extra "brightness" / "saturation" / "contrast"（float）调色彩（默认 1.0 / 1.0 / 1.0）
    // 可用 intent extra "bgColor"（int，0xRRGGBB 的十进制）设黑边背景色（默认黑）
    // 可用 intent extra "allowHDRDirect"（0/1）设 HDR 直显开关（默认 1，对齐 iOS）
    // 可用 intent extra "hud"（0/1）起播就显示统计 HUD（默认 0，点画面也能开关）
    // 可用 intent extra "seekAtMs" 指定起播后多少毫秒 seek 到 seekToMs（验证 seek-frame 耗时）
    // 可用 intent extra "seekToMs"（默认 30000）配合 seekAtMs 使用
    // 画中画：长按画面手动进入；退到后台且正在播放时自动进入（Android 8.0+）
    // 可用 intent extra "pip"（1）起播后自动进入画中画，配合 "pipAtMs"（默认 3000）调整延时
    private static final String TEST_URL =
            "https://media.w3.org/2010/05/sintel/trailer.mp4";

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density + 0.5f);
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        mSurfaceView = new SurfaceView(this);
        mSurfaceView.getHolder().addCallback(this);

        // 视频 Surface 上叠一张统计卡片（对应 iOS 的 FSHudCardView）
        mRootLayout = new FrameLayout(this);
        mRootLayout.addView(mSurfaceView, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        mHudView = new FSHudView(this);
        mHudView.appendTitle("Vulkan");
        FrameLayout.LayoutParams hudParams = new FrameLayout.LayoutParams(
                (int) (300 * getResources().getDisplayMetrics().density),
                FrameLayout.LayoutParams.WRAP_CONTENT);
        hudParams.gravity = Gravity.TOP | Gravity.END;
        hudParams.topMargin = dp(12);
        hudParams.rightMargin = dp(12);
        mRootLayout.addView(mHudView, hudParams);
        setContentView(mRootLayout);

        mSubtitlePath = getIntent() != null ? getIntent().getStringExtra("subtitle") : null;
        mSnapshotType = getIntent() != null ? getIntent().getIntExtra("snapshotType", -1) : -1;
        mSnapshotDelayMs = getIntent() != null ? getIntent().getIntExtra("snapshotDelayMs", 4000) : 4000;
        int pauseAfterMs = getIntent() != null ? getIntent().getIntExtra("pauseAfterMs", -1) : -1;
        int seekAtMs = getIntent() != null ? getIntent().getIntExtra("seekAtMs", -1) : -1;
        int seekToMs = getIntent() != null ? getIntent().getIntExtra("seekToMs", 30000) : 30000;
        mBackgroundPath = getIntent() != null ? getIntent().getStringExtra("background") : null;
        mBlurIterations = getIntent() != null
                ? getIntent().getIntExtra("blurIterations", FSPlayer.FS_BACKGROUND_BLUR_ITERATIONS)
                : FSPlayer.FS_BACKGROUND_BLUR_ITERATIONS;
        mBlurSigma = getIntent() != null
                ? getIntent().getFloatExtra("blurSigma", FSPlayer.FS_BACKGROUND_BLUR_SIGMA)
                : FSPlayer.FS_BACKGROUND_BLUR_SIGMA;
        mBrightness = getIntent() != null
                ? getIntent().getFloatExtra("brightness", FSPlayer.FS_COLOR_DEFAULT)
                : FSPlayer.FS_COLOR_DEFAULT;
        mSaturation = getIntent() != null
                ? getIntent().getFloatExtra("saturation", FSPlayer.FS_COLOR_DEFAULT)
                : FSPlayer.FS_COLOR_DEFAULT;
        mContrast = getIntent() != null
                ? getIntent().getFloatExtra("contrast", FSPlayer.FS_COLOR_DEFAULT)
                : FSPlayer.FS_COLOR_DEFAULT;
        mBgColor = getIntent() != null ? getIntent().getIntExtra("bgColor", 0) : 0;
        mPipOnPrepared = getIntent() != null && getIntent().getIntExtra("pip", 0) != 0;
        mPipAtMs = getIntent() != null ? getIntent().getIntExtra("pipAtMs", 3000) : 3000;

        mPlayer = new FSPlayer();
        mPlayer.attachHudView(mHudView);
        mPlayer.setShouldShowHudView(getIntent() != null
                && getIntent().getIntExtra("hud", 0) != 0);
        mSurfaceView.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                mPlayer.setShouldShowHudView(!mPlayer.shouldShowHudView());
            }
        });
        // 长按画面进画中画（和 iOS 上的 PiP 入口对应）
        mSurfaceView.setOnLongClickListener(new View.OnLongClickListener() {
            @Override
            public boolean onLongClick(View v) {
                return enterPictureInPicture();
            }
        });
        // MediaCodec 硬解 + Vulkan 外部显存零拷贝（设备不支持时自动回退软解）
        // 可用 intent extra "mediacodec" 传 0 强制走软解（排查硬解通路用）
        int useMediaCodec = getIntent() != null ? getIntent().getIntExtra("mediacodec", 1) : 1;
        if (useMediaCodec != 0) {
            mPlayer.setOption(FSPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 1);
        }
        // 画面缩放模式（和 iOS 的 player.scalingMode 对齐）
        int scaleMode = getIntent() != null
                ? getIntent().getIntExtra("scaleMode", FSPlayer.FS_SCALING_MODE_ASPECT_FIT)
                : FSPlayer.FS_SCALING_MODE_ASPECT_FIT;
        mPlayer.setScalingMode(scaleMode);
        mPlayer.setOnPreparedListener(new IMediaPlayer.OnPreparedListener() {
            @Override
            public void onPrepared(IMediaPlayer mp) {
                mp.start();
                // 外挂字幕要在流打开之后挂（native 侧需要 is 已经建立）
                Toast.makeText(MainActivity.this,
                        "scaleMode=" + mPlayer.getScalingMode(), Toast.LENGTH_SHORT).show();
                if (mSubtitlePath != null && !mSubtitlePath.isEmpty()) {
                    boolean ok = mPlayer.loadThenActiveSubtitle(mSubtitlePath);
                    Toast.makeText(MainActivity.this,
                            "loadThenActiveSubtitle(" + mSubtitlePath + ") = " + ok,
                            Toast.LENGTH_LONG).show();
                }
                if (mBackgroundPath != null && !mBackgroundPath.isEmpty()) {
                    Bitmap bg = android.graphics.BitmapFactory.decodeFile(mBackgroundPath);
                    if (bg == null) {
                        toast("背景图解码失败: " + mBackgroundPath);
                    } else {
                        mPlayer.setBackgroundBlurIterations(mBlurIterations);
                        mPlayer.setBackgroundBlurSigma(mBlurSigma);
                        mPlayer.setBackgroundImage(bg);
                        toast("背景 " + bg.getWidth() + "x" + bg.getHeight()
                                + " iterations=" + mPlayer.getBackgroundBlurIterations()
                                + " sigma=" + mPlayer.getBackgroundBlurSigma());
                    }
                }
                mPlayer.setBackgroundColor(mBgColor);
                mPlayer.setColorPreference(mBrightness, mSaturation, mContrast);
                if (getIntent() != null && getIntent().hasExtra("allowHDRDirect")) {
                    mPlayer.setAllowHDRDirectDisplay(getIntent().getIntExtra("allowHDRDirect", 1) != 0);
                }
                toast("hdrContent=" + mPlayer.isHDRContent()
                        + " directHDR=" + mPlayer.isDirectDisplayHDRSupported()
                        + " allow=" + mPlayer.isAllowHDRDirectDisplay());
                if (mBgColor != 0 || mBrightness != 1.0f || mSaturation != 1.0f || mContrast != 1.0f) {
                    toast("color b=" + mPlayer.getColorBrightness()
                            + " s=" + mPlayer.getColorSaturation()
                            + " c=" + mPlayer.getColorContrast()
                            + " bg=" + Integer.toHexString(mPlayer.getBackgroundColor()));
                }
                updatePictureInPictureParams();
                if (seekAtMs >= 0) {
                    new Handler(Looper.getMainLooper()).postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            mPlayer.seekTo(seekToMs);
                        }
                    }, seekAtMs);
                }
                if (pauseAfterMs >= 0) {
                    new Handler(Looper.getMainLooper()).postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            mPlayer.pause();
                        }
                    }, pauseAfterMs);
                }
                if (mPipOnPrepared) {
                    new Handler(Looper.getMainLooper()).postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            enterPictureInPicture();
                        }
                    }, mPipAtMs);
                }
                if (mSnapshotType >= 0) {
                    new Handler(Looper.getMainLooper()).postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            // 取快照会阻塞等渲染线程，别放在主线程上
                            new Thread(new Runnable() {
                                @Override
                                public void run() {
                                    saveSnapshot(mSnapshotType);
                                }
                            }).start();
                        }
                    }, mSnapshotDelayMs);
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

    /** 系统/设备是否支持画中画（Android 8.0+，且厂商没有裁掉 FEATURE_PICTURE_IN_PICTURE）。 */
    private boolean isPictureInPictureSupported() {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                && getPackageManager().hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE);
    }

    /** 用当前视频尺寸构造画中画参数；宽高比拿了视频的（含 SAR），拿不到就用系统默认。 */
    @RequiresApi(api = Build.VERSION_CODES.O)
    private PictureInPictureParams buildPictureInPictureParams() {
        PictureInPictureParams.Builder builder = new PictureInPictureParams.Builder();
        int width = mPlayer != null ? mPlayer.getVideoWidth() : 0;
        int height = mPlayer != null ? mPlayer.getVideoHeight() : 0;
        int sarNum = mPlayer != null ? mPlayer.getVideoSarNum() : 0;
        int sarDen = mPlayer != null ? mPlayer.getVideoSarDen() : 0;
        if (width > 0 && height > 0) {
            if (sarNum > 0 && sarDen > 0) {
                width *= sarNum;
                height *= sarDen;
            }
            int divisor = gcd(width, height);
            int num = width / divisor;
            int den = height / divisor;
            // 画中画窗口宽高比系统只接受 1:2.39 ~ 2.39:1，超范围会抛 IllegalArgumentException
            if (num > 0 && den > 0 && num * 1000L <= den * 2390L && den * 1000L <= num * 2390L) {
                builder.setAspectRatio(new Rational((int) num, (int) den));
            }
        }
        if (mSurfaceView != null) {
            Rect sourceRectHint = new Rect();
            if (mSurfaceView.getGlobalVisibleRect(sourceRectHint)) {
                builder.setSourceRectHint(sourceRectHint);
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(mPlayer != null && mPlayer.isPlaying());
        }
        return builder.build();
    }

    /** 进入画中画；返回是否进入成功。 */
    private boolean enterPictureInPicture() {
        if (!isPictureInPictureSupported()) {
            toast("画中画需要 Android 8.0 及以上，且设备支持");
            return false;
        }
        try {
            PictureInPictureParams params = buildPictureInPictureParams();
            boolean enter = enterPictureInPictureMode(params);
            Log.i(TAG, "enterPictureInPictureMode -> " + enter);
            if (!enter) {
                toast("进入画中画失败");
            }
            return enter;
        } catch (IllegalStateException e) {
            Log.w(TAG, "enterPictureInPictureMode failed: " + e.getMessage());
            toast("进入画中画失败: " + e.getMessage());
            return false;
        }
    }

    /** 更新系统画中画参数。 */
    private void updatePictureInPictureParams() {
        if (isPictureInPictureSupported() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                setPictureInPictureParams(buildPictureInPictureParams());
            } catch (Exception e) {
                Log.w(TAG, "setPictureInPictureParams failed: " + e.getMessage());
            }
        }
    }

    private static int gcd(int a, int b) {
        while (b != 0) {
            int t = b;
            b = a % b;
            a = t;
        }
        return a;
    }

    /** 点了 Home/切到别的应用：正在播放就进画中画（Android 8.0+）。 */
    @Override
    protected void onUserLeaveHint() {
        super.onUserLeaveHint();
        if (isPictureInPictureSupported() && mPlayer != null && mPlayer.isPlaying()) {
            enterPictureInPicture();
        }
    }

    /** 画中画窗口小，HUD 会挡住画面，进出画中画时收起/恢复。 */
    @Override
    public void onPictureInPictureModeChanged(boolean isInPictureInPictureMode, Configuration newConfig) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig);
        Log.i(TAG, "onPictureInPictureModeChanged -> " + isInPictureInPictureMode);
        if (mHudView != null) {
            mHudView.setVisibility(isInPictureInPictureMode
                    ? View.GONE
                    : (mPlayer != null && mPlayer.shouldShowHudView() ? View.VISIBLE : View.GONE));
        }
    }

    private void saveSnapshot(int type) {
        final Bitmap bitmap = mPlayer.getSnapshot(type);
        if (bitmap == null) {
            toast("snapshot(" + type + ") 失败");
            return;
        }
        File out = new File(getFilesDir(), "snapshot-" + type + ".png");
        try {
            FileOutputStream fos = new FileOutputStream(out);
            try {
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, fos);
            } finally {
                fos.close();
            }
        } catch (Exception e) {
            toast("写快照失败: " + e.getMessage());
            return;
        }
        toast("snapshot " + bitmap.getWidth() + "x" + bitmap.getHeight() + " -> " + out.getPath());
    }

    private void toast(final String message) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                Toast.makeText(MainActivity.this, message, Toast.LENGTH_LONG).show();
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
