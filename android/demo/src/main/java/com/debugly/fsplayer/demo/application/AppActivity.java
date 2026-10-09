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

package com.debugly.fsplayer.demo.application;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.util.Log;

import androidx.appcompat.widget.Toolbar;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import androidx.core.content.FileProvider;
import androidx.appcompat.app.AppCompatActivity;
import android.view.Menu;
import android.view.MenuItem;
import android.widget.ProgressBar;
import android.widget.Toast;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;

import com.debugly.fsplayer.demo.BuildConfig;
import com.debugly.fsplayer.demo.R;
import com.debugly.fsplayer.demo.activities.FileExplorerActivity;
import com.debugly.fsplayer.demo.activities.RecentMediaActivity;
import com.debugly.fsplayer.demo.activities.SettingsActivity;
import com.debugly.fsplayer.demo.updater.UpdateChecker;

@SuppressLint("Registered")
public class AppActivity extends AppCompatActivity {
    private static final String TAG = "AppActivity";
    private static final int MY_PERMISSIONS_REQUEST_READ_EXTERNAL_STORAGE = 1;
    private static final int MY_PERMISSIONS_REQUEST_READ_MEDIA = 2;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_app);

        Toolbar toolbar = (Toolbar) findViewById(R.id.toolbar);
        setSupportActionBar(toolbar);

        requestStoragePermissions();
    }

    /**
     * 读取外部存储里的视频。
     *
     * targetSdk 33 起 READ_EXTERNAL_STORAGE 不再授予任何东西，读媒体必须用
     * READ_MEDIA_VIDEO / READ_MEDIA_AUDIO；再往上（API 34+）音频拆成
     * READ_MEDIA_AUDIO，视觉则统一由 READ_MEDIA_VIDEO 覆盖。
     *
     * 而且这两个权限都必须在 manifest 里声明——声明之前调 requestPermissions
     * 会被系统静默丢弃：不弹窗、无回调，但系统仍会拉起一个空的
     * GrantPermissionsActivity 叠在我们的转场上，那层空转场会把 activity
     * 切换动画压缩掉，表现为「进 Files 有时淡入、有时直切」。
     */
    private void requestStoragePermissions() {
        String[] wanted;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            wanted = new String[]{
                    "android.permission.READ_MEDIA_VIDEO",
                    "android.permission.READ_MEDIA_IMAGES",
            };
        } else {
            wanted = new String[]{Manifest.permission.READ_EXTERNAL_STORAGE};
        }

        java.util.List<String> missing = new java.util.ArrayList<>();
        for (String permission : wanted) {
            if (ContextCompat.checkSelfPermission(this, permission)
                    != PackageManager.PERMISSION_GRANTED) {
                missing.add(permission);
            }
        }
        if (missing.isEmpty())
            return;

        ActivityCompat.requestPermissions(this,
                missing.toArray(new String[0]),
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                        ? MY_PERMISSIONS_REQUEST_READ_MEDIA
                        : MY_PERMISSIONS_REQUEST_READ_EXTERNAL_STORAGE);
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String permissions[], int[] grantResults) {
        switch (requestCode) {
            case MY_PERMISSIONS_REQUEST_READ_MEDIA:
            case MY_PERMISSIONS_REQUEST_READ_EXTERNAL_STORAGE: {
                if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    // permission was granted, yay! Do the task you need to do.
                } else {
                    // permission denied, boo! Disable the functionality that depends on this permission.
                }
            }
        }
    }

    @Override
    public boolean onCreateOptionsMenu(Menu menu) {
        getMenuInflater().inflate(R.menu.menu_app, menu);
        return true;
    }

    @Override
    public boolean onOptionsItemSelected(MenuItem item) {
        int id = item.getItemId();
        if (id == R.id.action_settings) {
            SettingsActivity.intentTo(this);
            return true;
        } else if (id == R.id.action_recent) {
            RecentMediaActivity.intentTo(this);
        } else if (id == R.id.action_files) {
            FileExplorerActivity.intentTo(this);
        } else if (id == R.id.action_check_update) {
            checkUpdate();
            return true;
        }

        return super.onOptionsItemSelected(item);
    }

    @Override
    public boolean onPrepareOptionsMenu(Menu menu) {
        boolean show = super.onPrepareOptionsMenu(menu);
        if (!show)
            return show;

        return true;
    }

    // ---------------- 检查更新 ----------------

    private void checkUpdate() {
        Toast.makeText(this, R.string.update_checking, Toast.LENGTH_SHORT).show();
        final String current = BuildConfig.VERSION_NAME;
        new Thread(new Runnable() {
            @Override
            public void run() {
                final UpdateChecker.Result result;
                try {
                    result = UpdateChecker.check(current);
                } catch (Exception e) {
                    Log.e(TAG, "check update failed", e);
                    runOnUiThread(new Runnable() {
                        @Override
                        public void run() {
                            Toast.makeText(AppActivity.this, R.string.update_check_failed, Toast.LENGTH_SHORT).show();
                        }
                    });
                    return;
                }
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        if (result == null) {
                            Toast.makeText(AppActivity.this, R.string.update_none, Toast.LENGTH_SHORT).show();
                        } else {
                            showUpdateDialog(result);
                        }
                    }
                });
            }
        }).start();
    }

    private void showUpdateDialog(final UpdateChecker.Result result) {
        String message = getString(R.string.update_available, result.latestVersion, BuildConfig.VERSION_NAME);
        new AlertDialog.Builder(this)
                .setTitle(R.string.update_found)
                .setMessage(message)
                .setPositiveButton(R.string.update_download, new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        downloadAndInstall(result);
                    }
                })
                .setNegativeButton(R.string.close, null)
                .show();
    }

    private void downloadAndInstall(final UpdateChecker.Result result) {
        final AlertDialog downloading = new AlertDialog.Builder(this)
                .setTitle(R.string.update_downloading)
                .setView(new ProgressBar(this))
                .setCancelable(false)
                .create();
        downloading.show();

        new Thread(new Runnable() {
            @Override
            public void run() {
                final File apk = download(result.downloadUrl, result.fileName);
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        downloading.dismiss();
                        if (apk == null) {
                            Toast.makeText(AppActivity.this, R.string.update_download_failed, Toast.LENGTH_SHORT).show();
                        } else {
                            installApk(apk);
                        }
                    }
                });
            }
        }).start();
    }

    private File download(String url, String fileName) {
        File dir = new File(getCacheDir(), "updates");
        if (!dir.exists())
            dir.mkdirs();
        File out = new File(dir, fileName);
        HttpURLConnection conn = null;
        try {
            conn = (HttpURLConnection) new URL(url).openConnection();
            conn.setConnectTimeout(20000);
            conn.setReadTimeout(120000);
            InputStream in = conn.getInputStream();
            FileOutputStream fos = new FileOutputStream(out);
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) != -1)
                fos.write(buf, 0, n);
            fos.close();
            in.close();
            return out;
        } catch (Exception e) {
            Log.e(TAG, "download update failed: " + url, e);
            return null;
        } finally {
            if (conn != null)
                conn.disconnect();
        }
    }

    private void installApk(File apk) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !getPackageManager().canRequestPackageInstalls()) {
            Toast.makeText(this, R.string.update_allow_unknown, Toast.LENGTH_LONG).show();
            try {
                Intent intent = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:" + getPackageName()));
                startActivity(intent);
            } catch (Exception e) {
                Log.e(TAG, "cannot open unknown-sources settings", e);
            }
            return;
        }
        Uri uri = FileProvider.getUriForFile(this, getPackageName() + ".fileprovider", apk);
        Intent intent = new Intent(Intent.ACTION_VIEW);
        intent.setDataAndType(uri, "application/vnd.android.package-archive");
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        startActivity(intent);
    }
}
