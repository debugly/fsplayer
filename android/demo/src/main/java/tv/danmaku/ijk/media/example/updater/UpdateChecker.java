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

package tv.danmaku.ijk.media.example.updater;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;

/**
 * 检查更新：查 GitHub Releases，找最新一个带 Aura APK（Aura-android-*.apk）的 release，
 * 从 APK 文件名解析版本号，比当前版本新才返回。
 *
 * 下载对象是 release 资产里的 APK（browser_download_url），不是 workflow artifact 的 zip——
 * 后者要登录 GitHub、30 天过期、还得解压，不适合端内更新。
 */
public class UpdateChecker {

    public static final String RELEASES_URL =
            "https://api.github.com/repos/debugly/fsplayer/releases?per_page=50";
    private static final String APK_PREFIX = "Aura-android-";
    private static final String APK_SUFFIX = ".apk";

    /** 一次更新查询的结果；没有新版本时返回 null。 */
    public static class Result {
        public String latestVersion;
        public String downloadUrl;
        public String fileName;
        public long sizeBytes;
    }

    /** 查询 GitHub Releases，找到最新一个带 demo APK 的 release；比 currentVersion 新才返回。 */
    public static Result check(String currentVersion) throws IOException {
        JSONArray releases = fetchJsonArray(RELEASES_URL);
        for (int i = 0; i < releases.length(); i++) {
            JSONObject release = releases.optJSONObject(i);
            if (release == null)
                continue;
            JSONArray assets = release.optJSONArray("assets");
            if (assets == null)
                continue;
            for (int j = 0; j < assets.length(); j++) {
                JSONObject asset = assets.optJSONObject(j);
                if (asset == null)
                    continue;
                String name = asset.optString("name");
                if (name.startsWith(APK_PREFIX) && name.endsWith(APK_SUFFIX)) {
                    String version = name.substring(APK_PREFIX.length(), name.length() - APK_SUFFIX.length());
                    if (compareVersion(version, currentVersion) > 0) {
                        Result r = new Result();
                        r.latestVersion = version;
                        r.downloadUrl = asset.optString("browser_download_url");
                        r.fileName = name;
                        r.sizeBytes = asset.optLong("size", 0);
                        return r;
                    }
                }
            }
        }
        return null;
    }

    private static JSONArray fetchJsonArray(String url) throws IOException {
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        conn.setRequestProperty("Accept", "application/vnd.github+json");
        conn.setRequestProperty("User-Agent", "fsplayer-demo");
        conn.setConnectTimeout(10000);
        conn.setReadTimeout(10000);
        try {
            InputStream in = conn.getInputStream();
            BufferedReader reader = new BufferedReader(new InputStreamReader(in, "UTF-8"));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null)
                sb.append(line);
            return new JSONArray(sb.toString());
        } catch (org.json.JSONException e) {
            throw new IOException("Malformed JSON from " + url, e);
        } finally {
            conn.disconnect();
        }
    }

    /** 逐段数字比较版本号，如 1.1.2 > 1.1.1；相等返回 0。 */
    static int compareVersion(String a, String b) {
        String[] pa = a.split("\\.");
        String[] pb = b.split("\\.");
        int n = Math.max(pa.length, pb.length);
        for (int i = 0; i < n; i++) {
            int va = i < pa.length ? parsePart(pa[i]) : 0;
            int vb = i < pb.length ? parsePart(pb[i]) : 0;
            if (va != vb)
                return va > vb ? 1 : -1;
        }
        return 0;
    }

    private static int parsePart(String s) {
        // 去掉可能的非数字后缀（如 "1-beta" -> 1）
        StringBuilder digits = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c >= '0' && c <= '9')
                digits.append(c);
            else
                break;
        }
        if (digits.length() == 0)
            return 0;
        try {
            return Integer.parseInt(digits.toString());
        } catch (NumberFormatException e) {
            return 0;
        }
    }
}
