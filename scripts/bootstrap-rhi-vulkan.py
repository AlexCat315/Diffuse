#!/usr/bin/env python3
"""Build the pinned Vulkan loader/header XCFramework for NativeRHI on macOS arm64.

This provides the loader, not a GPU driver. Install a Vulkan ICD (e.g. MoltenVK)
separately. Sources are verified before building; binaries stay in Engine/vendor.
"""
import argparse
import hashlib
from pathlib import Path
import platform
import plistlib
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
    parser.add_argument('--destination', type=Path, default=ROOT / 'Engine/vendor/VulkanLoader.xcframework')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('The current NativeRHI package integration targets macOS arm64')
    if args.destination.exists():
        parser.error('Destination exists; choose a new --destination to preserve the installed loader')
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
        common = ['-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_ARCHITECTURES=arm64',
                  '-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0', f'-DCMAKE_INSTALL_PREFIX={install}']
        run('cmake', '-S', temp / f'Vulkan-Headers-{VERSION}', '-B', temp / 'headers-build', *common)
        run('cmake', '--install', temp / 'headers-build')
        run('cmake', '-S', temp / f'Vulkan-Loader-{VERSION}', '-B', temp / 'loader-build', *common,
            f'-DCMAKE_PREFIX_PATH={install}', '-DSYSCONFDIR=/etc',
            '-DBUILD_TESTS=OFF', '-DBUILD_WERROR=OFF')
        run('cmake', '--build', temp / 'loader-build', '--parallel', '4')
        run('cmake', '--install', temp / 'loader-build')
        bundle = temp / 'VulkanLoader.xcframework'
        library = bundle / 'macos-arm64'
        library.mkdir(parents=True)
        binary = library / 'libvulkan.dylib'
        shutil.copy2(install / 'lib/libvulkan.dylib', binary)
        run('install_name_tool', '-id', '@rpath/libvulkan.dylib', binary)
        shutil.copytree(install / 'include', library / 'Headers')
        # Retain upstream license notices alongside the generated dependency.
        for name in DIGESTS:
            source = temp / f'{name}-{VERSION}'
            license_file = next(iter(source.glob('LICENSE*')))
            shutil.copy2(license_file, bundle / f'{name}-LICENSE.txt')
        metadata = {'AvailableLibraries': [{
            'BinaryPath': 'libvulkan.dylib', 'LibraryPath': 'libvulkan.dylib',
            'HeadersPath': 'Headers', 'LibraryIdentifier': 'macos-arm64',
            'SupportedArchitectures': ['arm64'], 'SupportedPlatform': 'macos',
        }], 'CFBundlePackageType': 'XFWK', 'XCFrameworkFormatVersion': '1.0'}
        (bundle / 'Info.plist').write_bytes(plistlib.dumps(metadata))
        args.destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(bundle, args.destination)
    print(args.destination.resolve())


if __name__ == '__main__':
    main()
