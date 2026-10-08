#!/usr/bin/env python3
"""Build pinned native Vulkan headers and loader for Windows or Linux.

Use an installed Vulkan SDK instead when available. This script builds SDK
libraries, not a GPU driver. Point VULKAN_SDK at the resulting destination.
macOS uses Metal and does not need any Vulkan dependency.
"""
import argparse
import hashlib
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

VERSION = '1.4.328'
DIGESTS = {
    'Vulkan-Headers': '3ad56d387179b47dd632432ccf989bbb69773e1d732692b7bbad9c4d36aa1304',
    'Vulkan-Loader': '07b5bae70dabdd2ee5a0fdaea95f72dac9561ddd768b0739d4af6cb8771e9ac8',
}
ROOT = Path(__file__).resolve().parents[1]


def run(*arguments):
    subprocess.run(list(map(str, arguments)), check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, default=ROOT / 'Engine/vendor/vulkan-sdk')
    args = parser.parse_args()
    if platform.system() not in ('Windows', 'Linux'):
        parser.error('Vulkan is for native Windows/Linux hosts; use Metal on macOS')
    if args.destination.exists():
        parser.error('Destination exists; choose a new --destination to preserve the installed SDK')
    with tempfile.TemporaryDirectory(prefix='guava-vulkan-build-') as directory:
        temp = Path(directory)
        for name, digest in DIGESTS.items():
            archive = temp / (name + '.tar.gz')
            urllib.request.urlretrieve(f'https://codeload.github.com/KhronosGroup/{name}/tar.gz/refs/tags/v{VERSION}', archive)
            if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
                raise RuntimeError(f'{name} source checksum mismatch')
            with tarfile.open(archive) as bundle:
                bundle.extractall(temp, filter='data')
        install = temp / 'install'
        common = ['-DCMAKE_BUILD_TYPE=Release', f'-DCMAKE_INSTALL_PREFIX={install}']
        run('cmake', '-S', temp / f'Vulkan-Headers-{VERSION}', '-B', temp / 'headers-build', *common)
        run('cmake', '--install', temp / 'headers-build', '--config', 'Release')
        run('cmake', '-S', temp / f'Vulkan-Loader-{VERSION}', '-B', temp / 'loader-build', *common,
            f'-DCMAKE_PREFIX_PATH={install}',
            '-DBUILD_TESTS=OFF', '-DBUILD_WERROR=OFF')
        run('cmake', '--build', temp / 'loader-build', '--config', 'Release', '--parallel', '4')
        run('cmake', '--install', temp / 'loader-build', '--config', 'Release')
        shutil.copytree(install, args.destination)
        for name in DIGESTS:
            source = temp / f'{name}-{VERSION}'
            license_file = next(iter(source.glob('LICENSE*')))
            shutil.copy2(license_file, args.destination / f'{name}-LICENSE.txt')
    print(f'VULKAN_SDK={args.destination.resolve()}')
    print('The GPU driver must provide a native Vulkan ICD.')


if __name__ == '__main__':
    main()
