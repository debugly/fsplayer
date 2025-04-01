/*
 * ijksdl_gpu_opengl_renderer_macos.m
 *
 * Copyright (c) 2024 debugly <qianlongxu@gmail.com>
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
 * License along with FSPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#import "ijksdl_gpu_opengl_renderer_macos.h"
#import "ijksdl_gpu_opengl_shader_compiler.h"
#import "ijksdl_gpu_opengl_fbo_macos.h"
#import "ijksdl_gles2.h"
#import "ijksdl_vout_ios_gles2.h"
// Uniform index.
enum
{
    UNIFORM_S_AI,
    DIMENSION_S_AI,
    NUM_UNIFORMS_AI
};

// Attribute index.
enum
{
    ATTRIB_VERTEX_AI,
    ATTRIB_TEXCOORD_AI,
    NUM_ATTRIBUTES_AI
};

@interface FSSDLOpenGLSubRenderer()
{
    GLint _uniforms[NUM_UNIFORMS_AI];
    GLint _attributers[NUM_ATTRIBUTES_AI];
    
    /// 顶点对象
    GLuint _vbo;
    GLuint _vao;
    GLuint _ubo;
}

@property (nonatomic) FSSDLOpenGLCompiler * openglCompiler;
@property (nonatomic) CGRect lastRect;

@end

@implementation FSSDLOpenGLSubRenderer

- (void)dealloc
{
    glDeleteBuffers(1, &_vbo);
    glDeleteVertexArrays(1, &_vao);
    glDeleteBuffers(1, &_ubo);
}

#define SDL_STRINGIZE(x)   #x
#define SDL_STRINGIZE2(x)  SDL_STRINGIZE(x)
#define SDL_STRING(x)      @SDL_STRINGIZE2(x)

- (NSString *)commonVSH
{
    return @"#"SDL_STRING(
version 330\n

in vec2 texCoord;
in vec2 position;
out vec2 texCoordVarying;

void main()
{
    gl_Position = vec4(position, 0.0, 1.0);
    texCoordVarying = texCoord;
}
                      );
}

- (NSString *)fsh
{
    return @"#"SDL_STRING(
version 330 core\n

uniform sampler2DRect SamplerS;
uniform vec2 textureDimensionS;
in vec2 texCoordVarying;
out vec4 fragColor;

void main()
{
    vec2 texCoord = texCoordVarying * textureDimensionS;
    fragColor = texture(SamplerS, texCoord);
}

                      );
}

- (NSString *)fsh2
{
    return @"#"SDL_STRING(
version 330 core\n

uniform sampler2D SamplerS;
layout (std140) uniform ColorBlock {
    ivec4 colors[64];
    uint width;
    uint height;
};
in vec2 texCoordVarying;
out vec4 fragColor;

void main()
{
    //No matching function for call to texelFetch(sampler2D, vec2, int)
    ivec2 position = ivec2(texCoordVarying * ivec2(width,height));

    uint loc = uint(texelFetch(SamplerS, position, 0).r * 255);
    uint idx = loc >> 2u;
    uint offset = loc % 4u;
    ivec4 color = colors[idx];
    uint c;
    if (offset == 0u) {
        c = uint(color.x);
    } else if (offset == 1u) {
        c = uint(color.y);
    } else if (offset == 2u) {
        c = uint(color.z);
    } else if (offset == 3u) {
        c = uint(color.w);
    }
    
    //'&' does not operate on 'unsigned int' and 'int'
    //'+' does not operate on 'unsigned int' and 'int'
    uint mask = uint(0xFFu);
    uint b = c & mask;
    uint g = (c >> 8) & mask;
    uint r = (c >> 16) & mask;
    uint a = (c >> 24) & mask;

    fragColor = vec4(b, g, r, a) / 255.0;
}

                      );
}

- (void)setupOpenGLProgramIfNeed
{
    if (!self.openglCompiler) {
        self.openglCompiler = [[FSSDLOpenGLCompiler alloc] initWithvsh:[self commonVSH] fsh:[self fsh2]];
        
        if ([self.openglCompiler compileIfNeed]) {
            // Get uniform locations.
            _uniforms[UNIFORM_S_AI]   = [self.openglCompiler getUniformLocation:"SamplerS"];
            _uniforms[DIMENSION_S_AI] = [self.openglCompiler getUniformLocation:"textureDimensionS"];
            
            _attributers[ATTRIB_VERTEX_AI]   = [self.openglCompiler getAttribLocation:"position"];
            _attributers[ATTRIB_TEXCOORD_AI] = [self.openglCompiler getAttribLocation:"texCoord"];
            
            glGenVertexArrays(1, &_vao);
            // 创建顶点缓存对象
            glGenBuffers(1, &_vbo);
            
            [self.openglCompiler active];
            
            FS_GLES2_checkError_TRACE("glUniformBlockBinding(setupOpenGLProgramIfNeed)111");
            
            //ubo
            glGenBuffers(1, &_ubo);
            glBindBuffer(GL_UNIFORM_BUFFER, _ubo);
            glBufferData(GL_UNIFORM_BUFFER, 64*16+8, NULL, GL_DYNAMIC_DRAW);
            
            GLuint program = self.openglCompiler.program;
            GLuint block_index = glGetUniformBlockIndex(program, "ColorBlock");
            GLuint binding_point_index = 2;
            glBindBufferBase(GL_UNIFORM_BUFFER, binding_point_index, _ubo);
            glUniformBlockBinding(program, block_index, binding_point_index);
            FS_GLES2_checkError_TRACE("glUniformBlockBinding(setupOpenGLProgramIfNeed)");
            glBindBuffer(GL_UNIFORM_BUFFER, 0);
        }
    }
    [self.openglCompiler active];
}

- (void)clean
{
    glClearColor(0.0,0.0,0.0,0.0);
    glClear(GL_COLOR_BUFFER_BIT);
    glDisable(GL_DEPTH_TEST);
}

- (void)bindFBO:(FSSDLOpenGLFBO *)fbo
{
    // Bind the FBO
    [fbo bind];
    CGSize viewport = [fbo size];
    glViewport(0, 0, viewport.width, viewport.height);
}

- (void)updateSubtitleVertexIfNeed:(CGRect)rect
{
    if (CGRectEqualToRect(self.lastRect, rect)) {
        return;
    }
    
    self.lastRect = rect;
    //OpenGL坐标范围只为-1到1
    float x = rect.origin.x;
    float y = rect.origin.y;
    float w = rect.size.width;
    float h = rect.size.height;
    /*
     triangle strip
       ^+
     V3|V4
     --|--->+
     V1|V2
     -->V1V2V3
     -->V2V3V4
     
     texture
     ^y
     |V3 V4
     |V1 V2
     |---->x
     */
    
    GLfloat quadData [] = {
        x,     y,
        x + w, y,
        x, y + h,
        x + w, y + h,
        //Texture Postition;这里纹理坐标和显示的时候不一样，保证画面方向是正常的，而不是倒立的
        0, 0,
        1, 0,
        0, 1,
        1, 1,
    };
    
    // 绑定顶点缓存对象到当前的顶点位置,之后对GL_ARRAY_BUFFER的操作即是对_VBO的操作
    glBindBuffer(GL_ARRAY_BUFFER, _vbo);
    // 将CPU数据发送到GPU,数据类型GL_ARRAY_BUFFER
    // GL_STATIC_DRAW 表示数据不会被修改,将其放置在GPU显存的更合适的位置,增加其读取速度
    glBufferData(GL_ARRAY_BUFFER, sizeof(quadData), quadData, GL_DYNAMIC_DRAW);
    
    // 更新顶点数据
    glBindVertexArray(_vao);
    glEnableVertexAttribArray(_attributers[ATTRIB_VERTEX_AI]);
    glEnableVertexAttribArray(_attributers[ATTRIB_TEXCOORD_AI]);
    
    // 指定顶点着色器位置为0的参数的数据读取方式与数据类型
    // 第一个参数: 参数位置
    // 第二个参数: 一次读取数据
    // 第三个参数: 数据类型
    // 第四个参数: 是否归一化数据
    // 第五个参数: 间隔多少个数据读取下一次数据
    // 第六个参数: 指定读取第一个数据在顶点数据中的偏移量
    glVertexAttribPointer(_attributers[ATTRIB_VERTEX_AI], 2, GL_FLOAT, GL_FALSE, 0, (void*)0);
    FS_GLES2_checkError_TRACE("glVertexAttribPointer(av4_position)");
    // texture coord attribute
    glVertexAttribPointer(_attributers[ATTRIB_TEXCOORD_AI], 2, GL_FLOAT, GL_FALSE, 0, (void*)(8 * sizeof(float)));
    FS_GLES2_checkError_TRACE("glVertexAttribPointer(av2_texcoord)");
}

- (void)updateColors:(void *)colors w:(GLuint)w h:(GLuint)h
{
    glBindBuffer(GL_UNIFORM_BUFFER, _ubo);
    
    int offset = 0;
    
    glBufferSubData(GL_UNIFORM_BUFFER, offset, 64*16, colors);
    offset += 64*16;
    glBufferSubData(GL_UNIFORM_BUFFER, offset, 4, &w);
    offset += 4;
    glBufferSubData(GL_UNIFORM_BUFFER, offset, 4, &h);
    
    FS_GLES2_checkError_TRACE("glBufferSubData(updateColors)");
}

- (void)drawTexture:(id<FSSDLSubtitleTextureWrapper>)subTexture colors:(void *)colors
{
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    //设置采样器位置，保证了每个uniform采样器对应着正确的纹理单元
    glUniform1i(_uniforms[UNIFORM_S_AI], 0);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, [subTexture texture]);
    glBindVertexArray(_vao);
    [self updateColors:colors w:subTexture.w h:subTexture.h];
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    //unbind
    glBindTexture(GL_TEXTURE_2D, 0);
    glBindVertexArray(0);
    glBindBuffer(GL_UNIFORM_BUFFER, 0);
    FS_GLES2_checkError("subtitle renderer draw");
}

@end
