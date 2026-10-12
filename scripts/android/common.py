"""Shared tool discovery for the Swift 6.4 Android validation programs."""
import os
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'Engine/build/android-validation'
SDK_ID = 'swift-6.4.0-RELEASE_android'
TRIPLE = 'aarch64-unknown-linux-android28'


def run(arguments, **options):
    print('+', ' '.join(map(str, arguments)), flush=True)
    return subprocess.run(list(map(str, arguments)), check=True, **options)


def sdk_root(value=None):
    root = Path(value or os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
                or Path.home() / 'Library/Android/sdk').resolve()
    if not (root / 'platform-tools/adb').is_file():
        raise ValueError('Supply --android-sdk pointing to an Android SDK with platform-tools')
    return root


def ndk_root(value=None):
    root = Path(value or os.environ.get('ANDROID_NDK_HOME') or OUTPUT / 'android-ndk-r30').resolve()
    properties = (root / 'source.properties').read_text()
    if not re.search(r'Pkg.Revision\s*=\s*30\.', properties):
        raise ValueError('Swift 6.4 Android SDK requires NDK r30; supply --ndk')
    return root


def ndk_host(ndk):
    hosts = list((ndk / 'toolchains/llvm/prebuilt').iterdir())
    if len(hosts) != 1:
        raise ValueError('Expected one NDK host toolchain')
    return hosts[0]


def build(product, ndk, configuration='debug'):
    OUTPUT.mkdir(parents=True, exist_ok=True)
    swift = os.environ.get('GUAVA_SWIFT_EXECUTABLE', shutil.which('swift'))
    if not swift:
        raise ValueError('Install the Swift 6.4.0 release toolchain and add swift to PATH')
    version = subprocess.check_output([swift, '--version'], text=True)
    if 'swift-6.4-RELEASE' not in version and 'swift-6.4.0-RELEASE' not in version:
        raise ValueError('Select the Swift 6.4.0 release toolchain to match the Android SDK')
    from fonts import prepare
    font_vendor = prepare(ndk)
    from native import prepare as prepare_native
    engine_vendor = prepare_native(ndk)
    environment = dict(os.environ, ANDROID_NDK_HOME=str(ndk),
                       GUAVA_TEXT_ARTIFACT_ROOT=os.path.relpath(font_vendor, ROOT / 'GuavaUI/Text'),
                       GUAVA_ENGINE_ARTIFACT_ROOT=os.path.relpath(engine_vendor, ROOT / 'Engine'))
    arguments = [swift, 'build', '--package-path', ROOT / 'Android', '--swift-sdk', SDK_ID,
                 '--triple', TRIPLE, '--static-swift-stdlib', '--configuration', configuration, '--jobs', '4']
    run(arguments + ['--product', product], env=environment)
    return Path(subprocess.check_output(list(map(str, arguments + ['--show-bin-path'])), env=environment, text=True).strip())


def adb_device(sdk, serial=None):
    adb = sdk / 'platform-tools/adb'
    devices = subprocess.check_output([str(adb), 'devices'], text=True).splitlines()[1:]
    ready = [line.split()[0] for line in devices if len(line.split()) >= 2 and line.split()[1] == 'device']
    if serial is None:
        if len(ready) != 1:
            raise ValueError('Connect exactly one authorized device, or supply --serial')
        serial = ready[0]
    if serial not in ready:
        raise ValueError(f'Android device {serial} is not connected and authorized')
    return [adb, '-s', serial]
