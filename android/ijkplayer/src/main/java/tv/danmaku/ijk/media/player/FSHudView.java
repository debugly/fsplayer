/*
 * Copyright (C) 2013-2014 Bilibili
 * Copyright (C) 2013-2014 Zhang Rui <bbcallen@gmail.com>
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

package tv.danmaku.ijk.media.player;

import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.util.AttributeSet;
import android.util.TypedValue;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Playback statistics card, the Android counterpart of the iOS FSHudCardView:
 * a translucent card pinned to a corner that keeps a row per key and updates
 * the row text in place (the values carry their own label, exactly like the
 * strings the iOS player feeds it).
 */
public class FSHudView extends ScrollView {
    /** 对齐 iOS：卡片宽度 300pt */
    private static final int CARD_WIDTH_DP = 300;

    private final LinearLayout mCard;
    private final TextView mTitle;
    /** 行按首次出现的顺序排列，和 iOS 的卡片一致 */
    private final LinkedHashMap<String, TextView> mRows = new LinkedHashMap<String, TextView>();

    public FSHudView(Context context) {
        this(context, null);
    }

    public FSHudView(Context context, AttributeSet attrs) {
        super(context, attrs);

        mCard = new LinearLayout(context);
        mCard.setOrientation(LinearLayout.VERTICAL);
        mCard.setPadding(dp(8), dp(6), dp(8), dp(6));

        GradientDrawable background = new GradientDrawable();
        background.setColor(0x99000000);
        background.setCornerRadius(dp(6));
        mCard.setBackground(background);

        mTitle = new TextView(context);
        mTitle.setTextColor(0xFFFFFFFF);
        mTitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        mTitle.setTypeface(Typeface.MONOSPACE);
        mTitle.setVisibility(View.GONE);
        mCard.addView(mTitle);

        addView(mCard);

        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                dp(CARD_WIDTH_DP), LinearLayout.LayoutParams.WRAP_CONTENT);
        setLayoutParams(params);

        setVisibility(View.GONE);
    }

    /** 追加一行标题（iOS 的 appendTitle:，可多次调用） */
    public void appendTitle(String title) {
        if (TextUtils.isEmpty(title)) {
            return;
        }
        CharSequence current = mTitle.getText();
        mTitle.setText(TextUtils.isEmpty(current) ? title : current + "\n" + title);
        mTitle.setVisibility(View.VISIBLE);
    }

    /** 更新/新增一行（iOS 的 setHudValue:forKey:），value 自带标签 */
    public void setHudValue(String value, String key) {
        if (key == null) {
            return;
        }
        TextView row = mRows.get(key);
        if (row == null) {
            row = new TextView(getContext());
            row.setTextColor(0xFFDDFFDD);
            row.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
            row.setTypeface(Typeface.MONOSPACE);
            mRows.put(key, row);
            mCard.addView(row);
        }
        row.setText(value == null ? "" : value);
    }

    /** iOS 的 allHudItem */
    public Map<String, String> allHudItem() {
        LinkedHashMap<String, String> items = new LinkedHashMap<String, String>();
        for (Map.Entry<String, TextView> entry : mRows.entrySet()) {
            items.put(entry.getKey(), entry.getValue().getText().toString());
        }
        return items;
    }

    public void clear() {
        for (TextView row : mRows.values()) {
            mCard.removeView(row);
        }
        mRows.clear();
        mTitle.setText("");
        mTitle.setVisibility(View.GONE);
    }

    public void setHudVisible(boolean visible) {
        setVisibility(visible ? View.VISIBLE : View.GONE);
        if (visible) {
            bringToFront();
        }
    }

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density + 0.5f);
    }
}
