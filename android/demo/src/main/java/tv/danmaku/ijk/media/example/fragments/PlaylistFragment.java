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

package tv.danmaku.ijk.media.example.fragments;

import android.app.Activity;
import android.content.Context;
import android.os.Bundle;
import androidx.annotation.Nullable;
import androidx.fragment.app.Fragment;
import android.util.Log;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.ListView;
import android.widget.TextView;

import java.net.URLDecoder;
import java.util.List;

import tv.danmaku.ijk.media.example.R;

/**
 * 选集列表：模仿 {@link SampleMediaListFragment}，两行式列表（名称 + 地址），
 * 点击一项回调宿主 Activity 切换播放。
 */
public class PlaylistFragment extends Fragment {
    private static final String TAG = "PlaylistFragment";

    private ListView mListView;
    private PlaylistAdapter mAdapter;

    public static PlaylistFragment newInstance() {
        return new PlaylistFragment();
    }

    @Nullable
    @Override
    public View onCreateView(LayoutInflater inflater, ViewGroup container, Bundle savedInstanceState) {
        ViewGroup viewGroup = (ViewGroup) inflater.inflate(R.layout.fragment_file_list, container, false);
        mListView = (ListView) viewGroup.findViewById(R.id.file_list_view);
        return viewGroup;
    }

    @Override
    public void onActivityCreated(@Nullable Bundle savedInstanceState) {
        super.onActivityCreated(savedInstanceState);

        final Activity activity = getActivity();
        if (!(activity instanceof IPlaylistHolder)) {
            Log.e(TAG, "activity is not an instance of IPlaylistHolder.");
            return;
        }

        final IPlaylistHolder holder = (IPlaylistHolder) activity;
        mAdapter = new PlaylistAdapter(activity);
        mAdapter.setItems(holder.getPlaylist());
        mListView.setAdapter(mAdapter);
        mListView.setOnItemClickListener(new AdapterView.OnItemClickListener() {
            @Override
            public void onItemClick(AdapterView<?> parent, View view, int position, long id) {
                holder.onPlaylistItemSelected(position);
            }
        });
    }

    public interface IPlaylistHolder {
        List<String> getPlaylist();
        int getCurrentPlaylistIndex();
        void onPlaylistItemSelected(int index);
    }

    final class PlaylistItem {
        int mIndex;
        String mName;
        String mUrl;
    }

    final class PlaylistAdapter extends ArrayAdapter<PlaylistItem> {
        public PlaylistAdapter(Context context) {
            super(context, android.R.layout.simple_list_item_2);
        }

        public void setItems(List<String> urls) {
            clear();
            if (urls == null)
                return;
            for (int i = 0; i < urls.size(); i++) {
                PlaylistItem item = new PlaylistItem();
                item.mIndex = i;
                item.mUrl = urls.get(i);
                item.mName = (i + 1) + ". " + displayName(urls.get(i));
                add(item);
            }
        }

        @Override
        public long getItemId(int position) {
            return position;
        }

        @Override
        public View getView(int position, View convertView, ViewGroup parent) {
            View view = convertView;
            if (view == null) {
                LayoutInflater inflater = LayoutInflater.from(parent.getContext());
                view = inflater.inflate(android.R.layout.simple_list_item_2, parent, false);
            }

            ViewHolder viewHolder = (ViewHolder) view.getTag();
            if (viewHolder == null) {
                viewHolder = new ViewHolder();
                viewHolder.mNameTextView = (TextView) view.findViewById(android.R.id.text1);
                viewHolder.mUrlTextView = (TextView) view.findViewById(android.R.id.text2);
                view.setTag(viewHolder);
            }

            PlaylistItem item = getItem(position);
            viewHolder.mNameTextView.setText(item.mName);
            viewHolder.mUrlTextView.setText(item.mUrl);

            return view;
        }

        final class ViewHolder {
            public TextView mNameTextView;
            public TextView mUrlTextView;
        }
    }

    private static String displayName(String url) {
        if (url == null)
            return "";
        String s = url;
        int q = s.indexOf('?');
        if (q >= 0)
            s = s.substring(0, q);
        int slash = s.lastIndexOf('/');
        if (slash >= 0 && slash < s.length() - 1)
            s = s.substring(slash + 1);
        try {
            s = URLDecoder.decode(s, "UTF-8");
        } catch (Exception ignored) {
        }
        return s;
    }
}
