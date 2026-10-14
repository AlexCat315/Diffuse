#!/usr/bin/env python3
"""Build isolated iOS native dependencies without replacing desktop artifacts."""
import argparse
import platform
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", choices=["iphoneos", "iphonesimulator"], default="iphonesimulator")
    parser.add_argument("--arch", choices=["arm64", "x86_64"], default="arm64")
    parser.add_argument("--plugins", action=argparse.BooleanOptionalAction, default=True, help="Build Wasmtime/Pulley (requires Rust target)")
    args = parser.parse_args()
    if platform.system() != "Darwin" or (args.sdk == "iphoneos" and args.arch != "arm64"):
        parser.error("iOS builds require macOS; devices require arm64")
    variant = f"ios-{args.arch}" + ("-simulator" if args.sdk == "iphonesimulator" else "")
    media = [sys.executable, str(ROOT / "Engine/Media/Native/stage.py"), "--platform", variant]
    if subprocess.run(media + ["--check"]).returncode != 0:
        subprocess.run(media, check=True)
    sdk = subprocess.check_output(["xcrun", "--sdk", args.sdk, "--show-sdk-path"], text=True).strip()
    for package in ["Engine", "GuavaUI"]:
        build = ROOT / package / "build" / variant
        command = ["cmake", "-S", str(ROOT / package / "third-party"), "-B", str(build / "native"),
                   "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_SYSTEM_NAME=iOS",
                   f"-DCMAKE_OSX_SYSROOT={sdk}", f"-DCMAKE_OSX_ARCHITECTURES={args.arch}",
                   "-DCMAKE_OSX_DEPLOYMENT_TARGET=16.0", f"-DGUAVA_VENDOR_DIR={build / 'vendor'}"]
        if package == "Engine":
            command += ["-DGUAVA_BUILD_OPENEXR=OFF", "-DGUAVA_STAGE_WASMTIME=" + ("ON" if args.plugins else "OFF")]
        subprocess.run(command, check=True)
        targets = ["stage_sdl3", "stage_jolt", "stage_image_decode"] if package == "Engine" else ["stage_freetype", "stage_harfbuzz"]
        if args.plugins and package == "Engine":
            targets.append("stage_wasmtime")
        subprocess.run(["cmake", "--build", str(build / "native"), "--parallel", "4", "--target", *targets], check=True)
        subprocess.run(["cmake", "--install", str(build / "native"), "--prefix", str(build / "install")], check=True)


if __name__ == "__main__":
    main()
