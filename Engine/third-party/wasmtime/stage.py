#!/usr/bin/env python3
"""Stage a pinned Wasmtime runtime independently of the graphics dependencies."""
import argparse
from pathlib import Path
from staging.archive import fetch
from staging.bundle import stage, ready
from staging.ios import build
from staging.catalog import read, host


def main():
    root = Path(__file__).resolve().parent
    catalog = read()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", default=host(), choices=catalog["platforms"])
    parser.add_argument("--check", action="store_true", help="Check the staged platform without downloading or building")
    parser.add_argument("--vendor", type=Path, default=root.parents[1] / "vendor")
    parser.add_argument("--cache", type=Path, default=root.parents[1] / "build/native/wasmtime")
    args = parser.parse_args()
    args.cache = args.cache.resolve()
    platform = catalog["platforms"][args.platform]
    version = catalog["version"]
    if args.check:
        checksum = platform.get("sha256", catalog["source_sha256"])
        raise SystemExit(0 if ready(args.vendor, args.platform, platform, version, checksum) else 1)
    base = f"https://github.com/bytecodealliance/wasmtime/releases/download/v{version}"
    if "release" in platform:
        extension = "zip" if args.platform.startswith("windows-") else "tar.xz"
        url = f"{base}/wasmtime-v{version}-{platform['release']}-c-api.{extension}"
        checksum = platform["sha256"]
        installed = fetch(url, checksum, args.cache)
    else:
        url = f"{base}/wasmtime-v{version}-src.tar.gz"
        checksum = catalog["source_sha256"]
        source = fetch(url, checksum, args.cache)
        installed = build(source, platform["rust_target"], args.cache)
    stage(installed, args.vendor.resolve(), args.platform, platform, version, dict(url=url, sha256=checksum))


if __name__ == "__main__":
    main()
