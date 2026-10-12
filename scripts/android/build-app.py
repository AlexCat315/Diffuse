#!/usr/bin/env python3
"""Build a debug APK hosting the shared Swift NativeRHI/GuavaUI renderer."""
import argparse
import shutil
import zipfile
from pathlib import Path
from common import ROOT, OUTPUT, run, sdk_root, ndk_root, ndk_host, build, adb_device


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--android-sdk')
    parser.add_argument('--ndk')
    parser.add_argument('--serial')
    parser.add_argument('--install', action='store_true', help='Install and launch on the selected device')
    args = parser.parse_args()
    sdk, ndk = sdk_root(args.android_sdk), ndk_root(args.ndk)
    products = build('GuavaAndroidApp', ndk)
    tools = sdk / 'build-tools/36.1.0'
    android_jar = sdk / 'platforms/android-36/android.jar'
    directory = OUTPUT / 'apk'
    directory.mkdir(exist_ok=True)
    classes, dex = directory / 'classes', directory / 'dex'
    for target in (classes, dex):
        if target.exists(): shutil.rmtree(target)
        target.mkdir()
    run(['javac', '--release', '8', '-Xlint:-options', '-classpath', android_jar, '-d', classes,
        *sorted((ROOT / 'Android/App/src').rglob('*.java'))])
    run([tools / 'd8', '--min-api', '28', '--output', dex, *classes.rglob('*.class')])
    base = directory / 'base.apk'
    run([tools / 'aapt2', 'link', '-I', android_jar, '--manifest', ROOT / 'Android/App/AndroidManifest.xml', '-o', base])
    with zipfile.ZipFile(base, 'a', compression=zipfile.ZIP_DEFLATED) as archive:
        for file in dex.glob('*.dex'): archive.write(file, file.name)
        archive.write(products / 'libGuavaAndroidApp.so', 'lib/arm64-v8a/libGuavaAndroidApp.so')
        archive.write(ndk_host(ndk) / 'sysroot/usr/lib/aarch64-linux-android/libc++_shared.so', 'lib/arm64-v8a/libc++_shared.so')
        bundle = products / 'GuavaAndroid_GuavaUIRendering.bundle'
        for file in bundle.rglob('*'):
            if file.is_file(): archive.write(file, 'assets/' + bundle.name + '/' + str(file.relative_to(bundle)))
    aligned, apk = directory / 'aligned.apk', OUTPUT / 'GuavaAndroidProbe.apk'
    run([tools / 'zipalign', '-f', '-P', '16', '4', base, aligned])
    key = OUTPUT / 'debug.keystore'
    if not key.is_file():
        run(['keytool', '-genkeypair', '-keystore', key, '-storepass', 'android', '-keypass', 'android',
            '-alias', 'androiddebugkey', '-dname', 'CN=Guava Android Probe,O=Guava,C=CN',
            '-keyalg', 'RSA', '-keysize', '2048', '-validity', '3650'])
    run([tools / 'apksigner', 'sign', '--ks', key, '--ks-pass', 'pass:android', '--out', apk, aligned])
    run([tools / 'apksigner', 'verify', apk])
    print(f'Built debug APK: {apk}')
    if args.install:
        adb = adb_device(sdk, args.serial)
        run(adb + ['install', '--no-incremental', '-r', apk])
        run(adb + ['shell', 'am', 'start', '-W', '-n', 'com.guava.probe/.MainActivity'])


if __name__ == '__main__':
    main()
