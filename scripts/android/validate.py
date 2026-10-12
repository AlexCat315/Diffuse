#!/usr/bin/env python3
"""Cross-compile and run strict NativeRHI/GuavaUI Vulkan checks on an Android device."""
import argparse
import importlib.util
import json
import shlex
import tempfile
from pathlib import Path
from common import ROOT, OUTPUT, run, sdk_root, ndk_root, ndk_host, build, adb_device


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--android-sdk')
    parser.add_argument('--ndk')
    parser.add_argument('--serial')
    args = parser.parse_args()
    sdk, ndk = sdk_root(args.android_sdk), ndk_root(args.ndk)
    adb = adb_device(sdk, args.serial)
    # The probe is ARM64; reject another ABI instead of pushing an unusable ELF.
    import subprocess
    if subprocess.check_output(list(map(str, adb + ['shell', 'getprop', 'ro.product.cpu.abi'])), text=True).strip() != 'arm64-v8a':
        raise ValueError('This validation package currently targets arm64-v8a')
    products = build('GuavaAndroidProbe', ndk)
    directory = Path(tempfile.mkdtemp(prefix='run-', dir=OUTPUT))
    properties = {name: subprocess.check_output(list(map(str, adb + ['shell', 'getprop', name])), text=True).strip()
        for name in ['ro.product.model', 'ro.product.cpu.abi', 'ro.build.version.release', 'ro.build.version.sdk', 'ro.board.platform']}
    (directory / 'device-info.json').write_text(json.dumps(properties, indent=2) + '\n')
    (directory / 'vkjson.json').write_text(subprocess.check_output(list(map(str, adb + ['shell', 'cmd', 'gpu', 'vkjson'])), text=True))
    artifacts = directory / 'Artifacts'; artifacts.mkdir()
    spec = importlib.util.spec_from_file_location('shader', ROOT / 'scripts/compile-rhi-shader.py')
    compiler = importlib.util.module_from_spec(spec); spec.loader.exec_module(compiler)
    for name, source, entry, stage in [('compute','compute','computeMain','compute'),
            ('raster.vertex','raster','vertexMain','vertex'), ('raster.fragment','raster','fragmentMain','fragment')]:
        compiler.compile_shader(ROOT / f'Engine/Tests/NativeRHITests/Fixtures/{source}.slang', entry, stage,
            'spirv', artifacts / (name + '.json'), str(ROOT / 'Engine/vendor/slang/bin/slangc'),
            line_directives=False, spirv_profile='spirv_1_3')
    remote = '/data/local/tmp/guava-rhi-' + directory.name
    run(adb + ['shell', 'mkdir', '-p', remote])
    run(adb + ['push', products / 'GuavaAndroidProbe', products / 'GuavaUI_GuavaUIRuntime.bundle',
        artifacts, ndk_host(ndk) / 'sysroot/usr/lib/aarch64-linux-android/libc++_shared.so', remote + '/'])
    command = f'cd {shlex.quote(remote)} && chmod 755 GuavaAndroidProbe && LD_LIBRARY_PATH=. ./GuavaAndroidProbe Artifacts results'
    status = subprocess.run(list(map(str, adb + ['shell', command])), capture_output=True, text=True, timeout=120)
    (directory / 'device.log').write_text(status.stdout + status.stderr)
    print(status.stdout, end='')
    run(adb + ['pull', remote + '/results', directory])
    report = json.loads((directory / 'results/report.json').read_text())
    expected = {'layout','transfer','compute','raster-1x','raster-4x','guavaui-1x','guavaui-4x'}
    names = [result['name'] for result in report['results']]
    if status.returncode or set(names) != expected or len(names) != len(expected) or not all(r['passed'] for r in report['results']):
        raise ValueError(f'Android validation failed; inspect {directory}')
    run(adb + ['shell', 'rm', '-r', remote])
    print(f'All {len(expected)} Android checks passed: {directory / "results/report.json"}')


if __name__ == '__main__':
    main()
