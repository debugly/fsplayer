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

package com.debugly.aura.application;

import android.content.Context;
import android.content.SharedPreferences;
import android.preference.PreferenceManager;

import com.debugly.aura.R;

public class Settings {
    private Context mAppContext;
    private SharedPreferences mSharedPreferences;

    // 0 曾经是 PV_PLAYER__Auto（"未设置"），createPlayer 的 default 分支也一直
    // 落到 FSPlayer，所以它和 FSPlayer 实际是同一个后端。现在 0 直接就是 FSPlayer：
    // 已装用户 prefs 里存的旧值 0 无需迁移，getPlayer() 解析失败同样回落到这里。
    public static final int PV_PLAYER__FSPlayer = 0;
    public static final int PV_PLAYER__AndroidMediaPlayer = 1;
    public static final int PV_PLAYER__AndroidXMedia3 = 3;

    public Settings(Context context) {
        mAppContext = context.getApplicationContext();
        mSharedPreferences = PreferenceManager.getDefaultSharedPreferences(mAppContext);
    }

    public boolean getEnableBackgroundPlay() {
        String key = mAppContext.getString(R.string.pref_key_enable_background_play);
        return mSharedPreferences.getBoolean(key, false);
    }

    public int getPlayer() {
        String key = mAppContext.getString(R.string.pref_key_player);
        String value = mSharedPreferences.getString(key, "");
        int player;
        try {
            player = Integer.valueOf(value).intValue();
        } catch (NumberFormatException e) {
            player = PV_PLAYER__FSPlayer;
        }
        // 旧版把 FSPlayer 存成 2（现在的 2 已经是无效值），已装用户的 prefs 里
        // 还留着这个数；映射回 FSPlayer，避免落到 createPlayer 的 default。
        if (player == 2)
            return PV_PLAYER__FSPlayer;
        return player;
    }

    public boolean getUsingMediaCodec() {
        String key = mAppContext.getString(R.string.pref_key_using_media_codec);
        return mSharedPreferences.getBoolean(key, false);
    }

    public boolean getUsingMediaCodecAutoRotate() {
        String key = mAppContext.getString(R.string.pref_key_using_media_codec_auto_rotate);
        return mSharedPreferences.getBoolean(key, false);
    }

    public boolean getMediaCodecHandleResolutionChange() {
        String key = mAppContext.getString(R.string.pref_key_media_codec_handle_resolution_change);
        return mSharedPreferences.getBoolean(key, false);
    }

    public boolean getUsingOpenSLES() {
        String key = mAppContext.getString(R.string.pref_key_using_opensl_es);
        return mSharedPreferences.getBoolean(key, false);
    }

    public String getPixelFormat() {
        String key = mAppContext.getString(R.string.pref_key_pixel_format);
        return mSharedPreferences.getString(key, "");
    }

    public boolean getEnableNoView() {
        String key = mAppContext.getString(R.string.pref_key_enable_no_view);
        return mSharedPreferences.getBoolean(key, false);
    }

    public boolean getEnableSurfaceView() {
        String key = mAppContext.getString(R.string.pref_key_enable_surface_view);
        return mSharedPreferences.getBoolean(key, false);
    }

    public boolean getEnableTextureView() {
        String key = mAppContext.getString(R.string.pref_key_enable_texture_view);
        return mSharedPreferences.getBoolean(key, false);
    }

    public boolean getEnableDetachedSurfaceTextureView() {
        String key = mAppContext.getString(R.string.pref_key_enable_detached_surface_texture);
        return mSharedPreferences.getBoolean(key, false);
    }

    public boolean getUsingMediaDataSource() {
        String key = mAppContext.getString(R.string.pref_key_using_mediadatasource);
        return mSharedPreferences.getBoolean(key, false);
    }

    public String getLastDirectory() {
        String key = mAppContext.getString(R.string.pref_key_last_directory);
        return mSharedPreferences.getString(key, "/");
    }

    public void setLastDirectory(String path) {
        String key = mAppContext.getString(R.string.pref_key_last_directory);
        mSharedPreferences.edit().putString(key, path).apply();
    }

    /** Player 菜单切换后端时落盘；设置页写的是同一个 key。 */
    public void setPlayer(int player) {
        String key = mAppContext.getString(R.string.pref_key_player);
        mSharedPreferences.edit().putString(key, String.valueOf(player)).apply();
    }
}
