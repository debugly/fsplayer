/*
 * ijksdl_gpu_opengl_shader_compiler.m
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
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#import "ijksdl_gpu_opengl_shader_compiler.h"
#import "ijksdl_gles2.h"

@interface FSSDLOpenGLCompiler ()

@property uint32_t program;

@end

@implementation FSSDLOpenGLCompiler

- (void)dealloc
{
    glDeleteProgram(_program);
}

- (instancetype)initWithvsh:(NSString *)vsh
                        fsh:(NSString *)fsh
{
    self = [super init];
    if (self) {
        self.vsh = vsh;
        self.fsh = fsh;
    }
    return self;
}

- (BOOL)compileIfNeed
{
    if (self.program) {
        return YES;
    } else if (self.vsh.length > 0 && self.fsh.length > 0) {
        GLuint program = [self compileProgram];
        if (program > 0) {
            self.program = program;
            return YES;
        } else {
            return NO;
        }
    } else {
        return NO;
    }
}

- (void)active
{
    if (self.program > 0) {
        glUseProgram(self.program);
    }
}

- (int)getUniformLocation:(const char *)name
{
    NSAssert(self.program > 0, @"you must compile opengl program firstly!");
    NSAssert(strlen(name) > 0, @"what's your uniform name?");
    int r = glGetUniformLocation(self.program, name);
    FS_GLES2_checkError("GetUniform");
    return r;
}

- (int)getAttribLocation:(const char *)name
{
    NSAssert(self.program > 0, @"you must compile opengl program firstly!");
    NSAssert(strlen(name) > 0, @"what's your uniform name?");
    
    int r = glGetAttribLocation(self.program, name);
    NSAssert(r >= 0, @"get attrib location failed:%s", name);
    return r;
}

- (GLuint)compileProgram
{
    // Create and compile the vertex shader.
    GLuint vertShader = [self compileShader:self.vsh type:GL_VERTEX_SHADER];
    FS_GLES2_checkError("compile vertex shader");
    NSAssert(vertShader, @"Failed to compile vertex shader");
    // Create and compile fragment shader.
    GLuint fragShader = [self compileShader:self.fsh type:GL_FRAGMENT_SHADER];
    FS_GLES2_checkError("compile fragment shader");
    NSAssert(fragShader, @"Failed to compile fragment shader");
    GLuint program = glCreateProgram();
    
    // Attach vertex shader to program.
    glAttachShader(program, vertShader);
    
    // Attach fragment shader to program.
    glAttachShader(program, fragShader);
    
    // Bind attribute locations. This needs to be done prior to linking.
    //glBindAttribLocation(self.program, ATTRIB_VERTEX, "position");
    //glBindAttribLocation(self.program, ATTRIB_TEXCOORD, "texCoord");
    
    // Link the program.
    if (![self linkProgram:program]) {
        if (vertShader) {
            glDeleteShader(vertShader);
            vertShader = 0;
        }
        if (fragShader) {
            glDeleteShader(fragShader);
            fragShader = 0;
        }
        if (self.program) {
            glDeleteProgram(self.program);
            self.program = 0;
        }
        NSAssert(NO, @"Failed link program:%d",program);
        return 0;
    }

    // Release vertex and fragment shaders.
    if (vertShader) {
        glDetachShader(program, vertShader);
        glDeleteShader(vertShader);
    }
    
    if (fragShader) {
        glDetachShader(program, fragShader);
        glDeleteShader(fragShader);
    }
    
    FS_GLES2_checkError("link program");
    return program;
}

- (GLuint)compileShader:(NSString *)sourceStr type:(GLenum)type
{
    GLint status;
    const GLchar *source = (GLchar *)[sourceStr UTF8String];
    
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    
#if defined(DEBUG)
    GLint logLength;
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetShaderInfoLog(shader, logLength, &logLength, log);
        NSLog(@"Shader compile log:\n%s", log);
        free(log);
    }
#endif
    
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (status == 0) {
        glDeleteShader(shader);
        return 0;
    }
    
    return shader;
}

- (BOOL)linkProgram:(GLuint)prog
{
    GLint status;
    glLinkProgram(prog);
    
#if defined(DEBUG)
    GLint logLength;
    glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetProgramInfoLog(prog, logLength, &logLength, log);
        NSLog(@"Program link log:\n%s", log);
        free(log);
    }
#endif
    
    glGetProgramiv(prog, GL_LINK_STATUS, &status);
    if (status == 0) {
        return NO;
    }
    
    return YES;
}

- (BOOL)validateProgram:(GLuint)prog
{
    GLint logLength, status;
    
    glValidateProgram(prog);
    glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetProgramInfoLog(prog, logLength, &logLength, log);
        NSLog(@"Program validate log:\n%s", log);
        free(log);
    }
    
    glGetProgramiv(prog, GL_VALIDATE_STATUS, &status);
    if (status == 0) {
        return NO;
    }
    
    return YES;
}

@end

