/*
 * Copyright (c) 2016 Bilibili
 * Copyright (c) 2016 Raymond Zheng <raymondzheng1412@gmail.com>
 * Copyright (c) 2019 debugly <qianlongxu@gmail.com>
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include "ijkdict.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <ctype.h>
#include <inttypes.h>
#include "libavutil/log.h"
#include "libavutil/mem.h"

struct IjkAVDictionary {
    int count;
    IjkAVDictionaryEntry *elems;
};

int ijk_av_dict_count(const IjkAVDictionary *m)
{
    return m ? m->count : 0;
}

IjkAVDictionaryEntry *ijk_av_dict_get(const IjkAVDictionary *m, const char *key,
                               const IjkAVDictionaryEntry *prev, int flags)
{
    unsigned int i, j;

    if (!m)
        return NULL;

    if (prev)
        i = (unsigned int)(prev - m->elems + 1);
    else
        i = 0;

    for (; i < m->count; i++) {
        const char *s = m->elems[i].key;
        if (flags & FS_AV_DICT_MATCH_CASE)
            for (j = 0; s[j] == key[j] && key[j]; j++)
                ;
        else
            for (j = 0; toupper(s[j]) == toupper(key[j]) && key[j]; j++)
                ;
        if (key[j])
            continue;
        if (s[j] && !(flags & FS_AV_DICT_IGNORE_SUFFIX))
            continue;
        return &m->elems[i];
    }
    return NULL;
}

int ijk_av_dict_set(IjkAVDictionary **pm, const char *key, const char *value,
                int flags)
{
    IjkAVDictionary *m = *pm;
    IjkAVDictionaryEntry *tag = NULL;
    char *oldval = NULL, *copy_key = NULL, *copy_value = NULL;

    if (!(flags & FS_AV_DICT_MULTIKEY)) {
        tag = ijk_av_dict_get(m, key, NULL, flags);
    }
    if (flags & FS_AV_DICT_DONT_STRDUP_KEY)
        copy_key = (void *)key;
    else
        copy_key = strdup(key);
    if (flags & FS_AV_DICT_DONT_STRDUP_VAL)
        copy_value = (void *)value;
    else if (copy_key)
        copy_value = strdup(value);
    if (!m)
        m = *pm = (IjkAVDictionary *)calloc(1, sizeof(*m));
    if (!m || (key && !copy_key) || (value && !copy_value))
        goto err_out;

    if (tag) {
        if (flags & FS_AV_DICT_DONT_OVERWRITE) {
            free(copy_key);
            free(copy_value);
            return 0;
        }
        if (flags & FS_AV_DICT_APPEND)
            oldval = tag->value;
        else
            free(tag->value);
            free(tag->key);
        *tag = m->elems[--m->count];
    } else if (copy_value) {
        IjkAVDictionaryEntry *tmp = (IjkAVDictionaryEntry *)realloc(m->elems,
                                            (m->count + 1) * sizeof(*m->elems));
        if (!tmp)
            goto err_out;
        m->elems = tmp;
    }
    if (copy_value) {
        m->elems[m->count].key = copy_key;
        m->elems[m->count].value = copy_value;
        if (oldval && flags & FS_AV_DICT_APPEND) {
            size_t len = strlen(oldval) + strlen(copy_value) + 1;
            char *newval = (char *)calloc(1, len);
            if (!newval)
                goto err_out;
            strlcat(newval, oldval, len);
            av_freep(&oldval);
            strlcat(newval, copy_value, len);
            m->elems[m->count].value = newval;
            av_freep(&copy_value);
        }
        m->count++;
    } else {
        av_freep(&copy_key);
    }
    if (!m->count) {
        av_freep(&m->elems);
        av_freep(pm);
    }

    return 0;

err_out:
    if (m && !m->count) {
        av_freep(&m->elems);
        av_freep(pm);
    }
    free(copy_key);
    free(copy_value);
    return -1;
}

int ijk_av_dict_set_int(IjkAVDictionary **pm, const char *key, int64_t value,
                int flags)
{
    char valuestr[22];
    snprintf(valuestr, sizeof(valuestr), "%"PRId64, value);
    flags &= ~FS_AV_DICT_DONT_STRDUP_VAL;
    return ijk_av_dict_set(pm, key, valuestr, flags);
}

void ijk_av_dict_free(IjkAVDictionary **pm)
{
    IjkAVDictionary *m = *pm;

    if (m) {
        while (m->count--) {
            av_freep(&m->elems[m->count].key);
            av_freep(&m->elems[m->count].value);
        }
        av_freep(&m->elems);
    }
    av_freep(pm);
}

int ijk_av_dict_copy(IjkAVDictionary **dst, const IjkAVDictionary *src, int flags)
{
    IjkAVDictionaryEntry *t = NULL;

    while ((t = ijk_av_dict_get(src, "", t, FS_AV_DICT_IGNORE_SUFFIX))) {
        int ret = ijk_av_dict_set(dst, t->key, t->value, flags);
        if (ret < 0)
            return ret;
    }

    return 0;
}
