#!/usr/bin/env python3
"""NDK API21 compile checks and JNI-disabled pbuffer harness (does not use adb).
Usage: python3 native_check.py [--abi arm64-v8a] [--api 21]
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
parser = argparse.ArgumentParser()
parser.add_argument('--abi', choices=['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86'], action='append')
parser.add_argument('--api', type=int, default=21)
args = parser.parse_args()
here = Path(__file__).resolve().parent
media = here.parents[3]
repo = media.parent
ndk = Path(os.environ.get('ANDROID_NDK_HOME', str(Path.home()/'Library/Android/sdk/ndk/27.3.13750724')))
clang = ndk/'toolchains/llvm/prebuilt/darwin-x86_64/bin/clang'
scratch = Path.home()/'.hermes/cache/scratch'
scratch.mkdir(parents=True, exist_ok=True)
build = Path(tempfile.mkdtemp(prefix='fs-gles-android-', dir=scratch))
abis = {'arm64-v8a': ('aarch64-linux-android', 'arm64'), 'armeabi-v7a': ('armv7a-linux-androideabi', 'armv7a'), 'x86_64': ('x86_64-linux-android', 'x86_64'), 'x86': ('i686-linux-android', 'x86')}
for abi in args.abi or list(abis):
    target, arch = abis[abi]
    ffmpeg = repo/('FFToolChain/build/product/android/universal/ffmpeg/ffmpeg-'+arch)
    base = [str(clang), '--target='+target+str(args.api), '--sysroot='+str(clang.parents[1]/'sysroot'),
            '-std=gnu11', '-O2', '-g', '-Wall', '-Wextra', '-Werror', '-I'+str(media),
            '-I'+str(media/'ijkj4a'), '-I'+str(ffmpeg/'include')]
    obj = build/(abi+'.o')
    subprocess.run(base+['-c', str(here.parent/'fs_gles_renderer.c'), '-o', str(obj)], check=True)
    print('API'+str(args.api), abi, 'renderer object PASS', flush=True)
    exe = build/('renderer-test-'+abi)
    # Standalone binary has no Java VM/player JNI; compile a second explicit
    # JNI-disabled object. The production JNI/OES object above is still checked.
    harness_obj = build/(abi+'-no-jni.o')
    subprocess.run(base+['-DFS_GLES_NO_JNI', '-c', str(here.parent/'fs_gles_renderer.c'),
                        '-o', str(harness_obj)], check=True)
    subprocess.run(base+['-DFS_GLES_NO_JNI', '-Wno-missing-field-initializers', '-x', 'c', str(here/'renderer_test.inc'),
                        str(media/'ijksdl/ijksdl_rectangle.c'), '-x', 'none', str(harness_obj),
                        '-L'+str(ffmpeg/'lib'), '-Wl,--start-group', '-lswscale', '-lavutil', '-Wl,--end-group',
                        '-lEGL', '-lGLESv3', '-llog', '-landroid', '-lm', '-ldl', '-lz', '-o', str(exe)], check=True)
    print('Standalone pbuffer harness:', exe, flush=True)
print('Native compile/link checks PASS (execution on Android remains separate)')
