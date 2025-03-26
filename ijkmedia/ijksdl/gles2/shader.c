/*
 * Copyright (c) 2016 Bilibili
 * Copyright (c) 2016 Zhang Rui <bbcallen@gmail.com>
 * Copyright (c) 2019 debugly <qianlongxu@gmail.com>
 *
 * This file is part of FSPlayer.
 *
 * FSPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * FSPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include "internal.h"

static void FS_GLES2_printShaderInfo(GLuint shader)
{
    if (!shader)
        return;

    GLint info_len = 0;
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &info_len);
    if (!info_len) {
        ALOGE("[GLES2][Shader] empty info\n");
        return;
    }

    char    buf_stack[32];
    char   *buf_heap = NULL;
    char   *buf      = buf_stack;
    GLsizei buf_len  = sizeof(buf_stack) - 1;
    if (info_len > sizeof(buf_stack)) {
        buf_heap = (char*) malloc(info_len + 1);
        if (buf_heap) {
            buf     = buf_heap;
            buf_len = info_len;
        }
    }

    glGetShaderInfoLog(shader, buf_len, NULL, buf);
    ALOGE("[GLES2][Shader] error %s\n", buf);

    if (buf_heap)
        free(buf_heap);
}

GLuint FS_GLES2_loadShader(GLenum shader_type, const char *shader_source)
{
    assert(shader_source);

    GLuint shader = glCreateShader(shader_type);        FS_GLES2_checkError("glCreateShader");
    if (!shader)
        return 0;

    assert(shader_source);

    glShaderSource(shader, 1, &shader_source, NULL);    FS_GLES2_checkError_TRACE("glShaderSource");
    glCompileShader(shader);                            FS_GLES2_checkError_TRACE("glCompileShader");

#if defined(DEBUG)
    GLint logLength;
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetShaderInfoLog(shader, logLength, &logLength, log);
        printf("Shader compile log:\n%s", log);
        free(log);
    }
#endif
    
    GLint compile_status = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compile_status);
    if (!compile_status)
        goto fail;

    return shader;

fail:

    if (shader) {
        FS_GLES2_printShaderInfo(shader);
        glDeleteShader(shader);
    }

    return 0;
}
