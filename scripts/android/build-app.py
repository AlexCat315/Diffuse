#!/usr/bin/env python3
"""Build a debug APK hosting the shared Swift NativeRHI/GuavaUI renderer."""
import argparse
import json
import shutil
import zipfile
from pathlib import Path
from common import ROOT, OUTPUT, run, sdk_root, ndk_root, ndk_host, build, adb_device


def package_apk(products, sdk, ndk, *, launch, application_id="com.guava.probe", name="GuavaUI Gallery", output=None, project=None, signing=None, debuggable=True):
    import xml.etree.ElementTree as ET
    tools = sdk / "build-tools/36.1.0"
    android_jar = sdk / "platforms/android-36/android.jar"
    directory = OUTPUT / ("apk-" + application_id)
    directory.mkdir(parents=True, exist_ok=True)
    manifest = ET.parse(ROOT / "Android/App/AndroidManifest.xml")
    namespace = "{http://schemas.android.com/apk/res/android}"
    manifest.getroot().set("package", application_id)
    manifest.find("application").set(namespace + "label", name)
    manifest.find("application").set(namespace + "debuggable", str(debuggable).lower())
    manifest.find("application/activity").set(namespace + "name", "com.guava.probe.MainActivity")
    manifest_path = directory / "AndroidManifest.xml"
    manifest.write(manifest_path, encoding="utf-8", xml_declaration=True)

    classes, dex = directory / 'classes', directory / 'dex'
    for target in (classes, dex):
        if target.exists(): shutil.rmtree(target)
        target.mkdir()
    run(['javac', '--release', '8', '-Xlint:-options', '-classpath', android_jar, '-d', classes,
        *sorted((ROOT / 'Android/App/src').rglob('*.java')),
        *sorted((ROOT / 'Engine/third-party/sdl3/android-project/app/src/main/java').rglob('*.java'))])
    run([tools / 'd8', '--min-api', '28', '--output', dex, *classes.rglob('*.class')])
    base = directory / 'base.apk'
    run([tools / 'aapt2', 'link', '-I', android_jar, '--manifest', manifest_path, '-o', base])
    with zipfile.ZipFile(base, 'a', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('assets/launch.json', json.dumps(launch))
        for name in ('NotoEmoji.ttf', 'OFL-Emoji.txt'):
            archive.write(ROOT / 'GuavaUI/Text/Fonts' / name, 'assets/Fonts/' + name)
        for file in dex.glob('*.dex'): archive.write(file, file.name)
        archive.write(products / 'libGuavaAndroidApp.so', 'lib/arm64-v8a/libGuavaAndroidApp.so')
        archive.write(ndk_host(ndk) / 'sysroot/usr/lib/aarch64-linux-android/libc++_shared.so', 'lib/arm64-v8a/libc++_shared.so')
        for bundle in sorted(products.iterdir()):
            if bundle.suffix not in ('.bundle', '.resources'): continue
            for file in bundle.rglob('*'):
                if file.is_file():
                    relative = file.relative_to(bundle)
                    if 'Shaders' in relative.parts and 'Slang' in relative.parts: continue
                    if 'Native' in relative.parts:
                        target = relative.parts[relative.parts.index('Native') + 1]
                        expected = 'spirv-mobile' if 'RenderBackend' in bundle.name else 'spirv'
                        if target in ('metal', 'dxil', 'spirv', 'spirv-mobile') and target != expected: continue
                    archive.write(file, 'assets/' + bundle.name + '/' + str(relative))
        if project:
            for file in sorted(project.rglob('*')):
                relative = file.relative_to(project)
                if file.is_file() and relative.parts[:2] != ('.guava', 'static-sources') and file.name != 'static-scripts.json':
                    archive.write(file, 'assets/GuavaProject/' + str(relative))
    aligned, apk = directory / 'aligned.apk', Path(output or OUTPUT / 'GuavaAndroidProbe.apk').resolve()
    apk.parent.mkdir(parents=True, exist_ok=True)
    run([tools / 'zipalign', '-f', '-P', '16', '4', base, aligned])
    key = Path(signing['keystore']) if signing else OUTPUT / 'debug.keystore'
    if not signing and not key.is_file():
        run(['keytool', '-genkeypair', '-keystore', key, '-storepass', 'android', '-keypass', 'android',
            '-alias', 'androiddebugkey', '-dname', 'CN=Guava Android Probe,O=Guava,C=CN',
            '-keyalg', 'RSA', '-keysize', '2048', '-validity', '3650'])
    signer = ['--ks', key, '--ks-pass', 'pass:android']
    if signing:
        signer = ['--ks', key, '--ks-key-alias', signing['alias'], '--ks-pass', 'env:' + signing['store_password_env'],
                  '--key-pass', 'env:' + signing['key_password_env']]
    run([tools / 'apksigner', 'sign', *signer, '--out', apk, aligned])
    run([tools / 'apksigner', 'verify', apk])
    print(f'Built signed APK: {apk} (debuggable={debuggable})')
    return apk


def install(apk, sdk, serial, application_id='com.guava.probe'):
    adb = adb_device(sdk, serial)
    run(adb + ['install', '--no-incremental', '-r', apk])
    run(adb + ['shell', 'am', 'force-stop', application_id])
    run(adb + ['shell', 'am', 'start', '-W', '-n', application_id + '/com.guava.probe.MainActivity'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--android-sdk')
    parser.add_argument('--ndk')
    parser.add_argument('--serial')
    parser.add_argument('--install', action='store_true')
    parser.add_argument('--demo', choices=['gallery', 'counter'], default='gallery')
    parser.add_argument('--component', default='introduction')
    args = parser.parse_args()
    sdk, ndk = sdk_root(args.android_sdk), ndk_root(args.ndk)
    products = build('GuavaAndroidApp', ndk)
    apk = package_apk(products, sdk, ndk, launch={'mode': args.demo, 'component': args.component})
    if args.install: install(apk, sdk, args.serial)


if __name__ == '__main__': main()
