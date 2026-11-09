#!/usr/bin/env python3
"""Check the packaged APK floor, ABI dependencies and versioned native imports.

Usage: python3 examples/android/tests/check_apk_compat.py path/to/app.apk --api 21
This is a static loader check, not an Android device playback test.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile


def output(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def symbols(readelf, path):
    exports, imports = set(), []
    for line in output(readelf, '--dyn-syms', '--wide', str(path)).splitlines():
        fields = line.split()
        if len(fields) < 8 or not re.fullmatch(r'\d+:', fields[0]):
            continue
        name = fields[7].replace('@@', '@')
        if fields[6] != 'UND':
            exports.add(name)
            exports.add(name.split('@')[0])
        elif fields[4] != 'WEAK':
            imports.append(name)
    return exports, imports


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--api', type=int, default=21)
    parser.add_argument('--sdk', type=Path, default=Path(os.environ.get(
        'ANDROID_HOME', str(Path.home() / 'Library/Android/sdk'))))
    parser.add_argument('--ndk', type=Path)
    args = parser.parse_args()
    ndk = args.ndk or args.sdk / 'ndk/27.3.13750724'
    toolchain = ndk / 'toolchains/llvm/prebuilt/darwin-x86_64'
    readelf = str(toolchain / 'bin/llvm-readelf')
    aapt = str(sorted((args.sdk / 'build-tools').glob('*/aapt'))[-1])
    badging = output(aapt, 'dump', 'badging', str(args.apk))
    floor = re.search(r"sdkVersion:'(\d+)'", badging)
    assert floor and int(floor.group(1)) <= args.api, (
        'APK minSdk ' + (floor.group(1) if floor else 'unknown') +
        ' exceeds requested API ' + str(args.api))
    triples = {'arm64-v8a': 'aarch64-linux-android',
               'armeabi-v7a': 'arm-linux-androideabi',
               'x86': 'i686-linux-android', 'x86_64': 'x86_64-linux-android'}
    scratch = Path(os.environ.get('TMPDIR', str(Path.home() / '.hermes/cache/scratch')))
    scratch.mkdir(parents=True, exist_ok=True)
    checked = []
    with tempfile.TemporaryDirectory(prefix='apk-api-check-', dir=scratch) as work:
        with zipfile.ZipFile(args.apk) as apk:
            abis = sorted({n.split('/')[1] for n in apk.namelist()
                           if n.startswith('lib/') and n.endswith('.so')})
            assert abis, 'APK contains no native libraries'
            for abi in abis:
                platform = toolchain / 'sysroot/usr/lib' / triples[abi] / str(args.api)
                exports, packaged, paths = set(), set(), []
                platform_names = set()
                for stub in platform.glob('*.so'):
                    if stub.read_bytes()[:4] != b'\x7fELF':
                        continue  # e.g. libc++.so is a linker script.
                    platform_names.add(stub.name)
                    exports.update(symbols(readelf, stub)[0])
                for name in apk.namelist():
                    if name.startswith('lib/' + abi + '/') and name.endswith('.so'):
                        dest = Path(work) / abi / Path(name).name
                        dest.parent.mkdir(parents=True, exist_ok=True)
                        dest.write_bytes(apk.read(name))
                        paths.append(dest)
                        packaged.add(dest.name)
                        exports.update(symbols(readelf, dest)[0])
                for path in paths:
                    needed = re.findall(r'Shared library: \[(.*?)\]',
                                        output(readelf, '-d', str(path)))
                    assert 'libvulkan.so' not in needed, (abi, path.name, 'hard Vulkan dependency')
                    missing_libs = set(needed) - packaged - platform_names
                    assert not missing_libs, (abi, path.name, 'missing libraries', missing_libs)
                    missing = [s for s in symbols(readelf, path)[1] if s not in exports]
                    assert not missing, (abi, path.name, 'unsupported strong imports', missing)
                checked.append(abi)
                print('PASS API%d %s: dependency closure and versioned imports' % (args.api, abi))
    print('PASS APK minSdk=%s; ABIs=%s (static compatibility only)' % (
        floor.group(1), ','.join(checked)))


if __name__ == '__main__':
    main()
