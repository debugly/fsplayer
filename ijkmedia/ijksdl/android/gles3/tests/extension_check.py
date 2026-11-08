#!/usr/bin/env python3
"""Unit-test extension lookup against a broken indexed-extension driver contract.
This is a narrow GL-query stub, NOT an OES/MediaCodec execution test.
"""
from pathlib import Path
import subprocess
import tempfile
here = Path(__file__).resolve().parent
source = (here.parent/'fs_gles_mediacodec.inc').read_text()
source = source[source.index('static int has_extension'):source.index('#ifdef FS_GLES_ANDROID_CODEC')]
prelude = r'''
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stddef.h>
typedef unsigned GLenum; typedef int GLint; typedef unsigned GLuint;
#define GL_NUM_EXTENSIONS 1
#define GL_EXTENSIONS 2
#define GL_NO_ERROR 0
#define LOGE(...) ((void)0)
static GLenum error;
static int broken;
static GLenum glGetError(void){GLenum result=error;error=0;return result;}
static void glGetIntegerv(GLenum p,GLint *v){(void)p;*v=broken?3:1;}
static const unsigned char *glGetStringi(GLenum p,GLuint i){(void)p;
 if(broken && i>0){if(broken==1)error=0x501;return NULL;}
 return (const unsigned char *)(broken?"GL_OTHER":"GL_OES_EGL_image_external_essl3");}
static const unsigned char *glGetString(GLenum p){(void)p;
 return (const unsigned char *)"GL_OTHER GL_OES_EGL_image_external GL_END";}
'''
postlude = r'''
int main(void){
 broken=1;
 assert(has_extension("GL_OES_EGL_image_external"));
 assert(!has_extension("GL_OES_EGL_image_external_essl3"));
 assert(!has_extension("GL_OES_EGL_image"));
 assert(!has_extension("OES_EGL_image_external"));
 assert(glGetError()==0);
 broken=2;
 assert(has_extension("GL_OES_EGL_image_external"));
 assert(glGetError()==0);
 broken=0;
 assert(has_extension("GL_OES_EGL_image_external_essl3"));
 assert(!has_extension("GL_OES_EGL_image_external"));
 puts("Extension enumeration error/fallback/token-boundary PASS");
}
'''
scratch = Path.home()/'.hermes/cache/scratch'
scratch.mkdir(parents=True,exist_ok=True)
build = Path(tempfile.mkdtemp(prefix='fs-gles-ext-',dir=scratch))
p=build/'extension.c';p.write_text(prelude+source+postlude)
subprocess.run(['clang','-std=c11','-Wall','-Wextra','-Wno-unused-function',str(p),'-o',str(build/'test')],check=True)
subprocess.run([str(build/'test')],check=True)
