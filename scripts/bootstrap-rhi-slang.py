#!/usr/bin/env python3
"""Install the pinned macOS arm64 Slang toolchain in ignored Engine/vendor.

Other platforms can supply the same Slang version with SLANGC. Compiler binaries
are not checked into Git. Verify the release's SHA-256 before extraction.
"""
import argparse
import hashlib
from pathlib import Path
import platform
import tarfile
import tempfile
import urllib.request

VERSION = '2026.19'
SHA256 = 'fa46822c92d81404a7951de3746093985c1e6f520f4b533e2aa3bea576f0f2f0'
URL = f'https://github.com/shader-slang/slang/releases/download/v{VERSION}/slang-{VERSION}-macos-aarch64.tar.gz'
ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, default=ROOT / 'Engine/vendor/slang')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('This installer targets macOS arm64; set SLANGC to Slang 2026.19 on other hosts')
    if args.destination.exists():
        parser.error('Destination exists; choose a new --destination to preserve the installed compiler')
    with tempfile.TemporaryDirectory(prefix='guava-slang-download-') as directory:
        archive = Path(directory) / 'slang.tar.gz'
        urllib.request.urlretrieve(URL, archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
            raise RuntimeError('Slang release checksum mismatch')
        args.destination.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive) as bundle:
            bundle.extractall(args.destination, filter='data')
    print(args.destination.resolve() / 'bin/slangc')


if __name__ == '__main__':
    main()
