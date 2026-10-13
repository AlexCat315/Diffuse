"""Shared tool discovery for the Swift 6.4 Android validation programs."""
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'Engine/build/android-validation'


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
        raise ValueError('Install the Swift 6.4.1 release toolchain and add swift to PATH')
    # Python is only used by repository verification. Production build ownership
    # lives in the Swift CLI, including native dependencies and artifact staging.
    descriptor, result_name = tempfile.mkstemp(prefix='compile-', suffix='.json', dir=OUTPUT)
    os.close(descriptor)
    result = Path(result_name)
    arguments = [swift, 'run', '--package-path', ROOT / 'Platforms/Android/Tools', 'GuavaAndroid', 'compile',
                 '--product', product, '--ndk', ndk, '--configuration', configuration, '--result-file', result]
    try:
        run(arguments)
        return Path(json.loads(result.read_text())['products'])
    finally: result.unlink(missing_ok=True)


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
