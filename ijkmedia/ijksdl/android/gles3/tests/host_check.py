#!/usr/bin/env python3
"""Run real ES3 headless tests using Android Emulator's host ANGLE libraries.
No emulator, adb, device, APK or repository integration changes are used.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
root = Path(__file__).resolve().parents[4]
here = Path(__file__).resolve().parent
ndk = Path(os.environ.get('ANDROID_NDK_HOME', str(Path.home()/'Library/Android/sdk/ndk/27.3.13750724')))
angle = Path(os.environ.get('ANGLE_LIB_DIR', str(Path.home()/'Library/Android/sdk/emulator/lib64/gles_angle')))
ffmpeg = Path(os.environ.get('FFMPEG_PREFIX', '/opt/homebrew/opt/ffmpeg'))
scratch = Path.home()/'.hermes/cache/scratch'
scratch.mkdir(parents=True, exist_ok=True)
build = Path(tempfile.mkdtemp(prefix='fs-gles-host-', dir=scratch))
inc = build/'include'
inc.mkdir()
for name in ('EGL', 'KHR', 'GLES2', 'GLES3'):
    shutil.copytree(ndk/'toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/include'/name, inc/name)
shutil.copy(ndk/'toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/include/jni.h', inc/'jni.h')
(inc/'android').mkdir()
(inc/'android/native_window.h').write_text('''#include <stdint.h>
typedef struct ANativeWindow ANativeWindow;
static inline void ANativeWindow_acquire(ANativeWindow *w) {(void)w;}
static inline void ANativeWindow_release(ANativeWindow *w) {(void)w;}
static inline int ANativeWindow_setBuffersGeometry(ANativeWindow *w,int a,int b,int c) {(void)w;(void)a;(void)b;(void)c;return -1;}
''')
(inc/'android/log.h').write_text('''#include <stdarg.h>
#include <stdio.h>
#define ANDROID_LOG_ERROR 6
static inline int __android_log_print(int p,const char *t,const char *s,...) {(void)p;fprintf(stderr,"%s: ",t);va_list a;va_start(a,s);int n=vfprintf(stderr,s,a);va_end(a);fputc('\\n',stderr);return n;}
''')
cmd = ['clang', '-std=gnu11', '-g', '-O1', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined',
       '-I'+str(inc), '-I'+str(root), '-I'+str(ffmpeg/'include'),
       '-Wno-missing-field-initializers', '-x', 'c', str(here.parent/'fs_gles_renderer.c'), str(here/'renderer_test.inc'),
       str(root/'ijksdl/ijksdl_rectangle.c'), '-L'+str(angle), '-lEGL', '-lGLESv2',
       '-Wl,-rpath,'+str(angle), '-L'+str(ffmpeg/'lib'), '-lavutil', '-lswscale', '-o', str(build/'renderer_test')]
print(' '.join(cmd), flush=True)
subprocess.run(cmd, check=True)
env = dict(os.environ)
env['ANGLE_DEFAULT_PLATFORM'] = 'metal'
env['DYLD_LIBRARY_PATH'] = str(angle)
subprocess.run([str(build/'renderer_test')], env=env, check=True)
print('HOST TEST PASS', build)
