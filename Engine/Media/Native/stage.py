#!/usr/bin/env python3
"""Build the pinned LGPL FFmpeg libraries and desktop editing tools."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.request

VERSION = "8.1.3"
SHA256 = "7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3"
ROOT = Path(__file__).resolve().parents[1]
LIBRARIES = ["avformat", "avcodec", "avfilter", "swresample", "swscale", "avutil"]


def host():
    system = {"Darwin": "macos", "Linux": "linux", "Windows": "windows"}[platform.system()]
    arm = platform.machine().lower() in ("arm64", "aarch64")
    return system + "-" + ("aarch64" if arm and system == "linux" else "arm64" if arm else "x86_64")


def target_options(name):
    arch = "aarch64" if "arm64" in name or "aarch64" in name else "x86_64"
    options = [f"--arch={arch}"]
    if name.startswith("ios-"):
        sdk = "iphonesimulator" if name.endswith("simulator") else "iphoneos"
        sysroot = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
        triple = ("arm64" if arch == "aarch64" else arch) + "-apple-ios16.0" + ("-simulator" if sdk.endswith("simulator") else "")
        options += ["--target-os=darwin", "--enable-cross-compile", "--cc=clang",
                    f"--sysroot={sysroot}", f"--extra-cflags=-target {triple}", f"--extra-ldflags=-target {triple}", "--disable-programs"]
    elif name.startswith("android-"):
        ndk = Path(os.environ["ANDROID_NDK_HOME"])
        tag = "darwin-x86_64" if platform.system() == "Darwin" else "linux-x86_64"
        tools = ndk / "toolchains/llvm/prebuilt" / tag / "bin"
        triple = "aarch64-linux-android" if arch == "aarch64" else "x86_64-linux-android"
        options += ["--target-os=android", "--enable-cross-compile", f"--cc={tools / (triple + '28-clang')}",
                    f"--ar={tools / 'llvm-ar'}", f"--ranlib={tools / 'llvm-ranlib'}", "--disable-programs"]
    elif name.startswith("windows-"):
        options += ["--target-os=win32", "--toolchain=msvc", "--cc=cl", "--ar=lib", "--disable-x86asm"]
    elif name.startswith("macos-"):
        options += ["--target-os=darwin", "--cc=clang", f"--extra-cflags=-arch {'arm64' if arch == 'aarch64' else arch} -mmacosx-version-min=13.0", f"--extra-ldflags=-arch {'arm64' if arch == 'aarch64' else arch} -mmacosx-version-min=13.0"]
    else:
        options += ["--target-os=linux", "--disable-x86asm"]
        if name != host():
            compiler = os.environ.get("GUAVA_FFMPEG_CC")
            if not compiler:
                raise ValueError("Linux cross builds require GUAVA_FFMPEG_CC for the target compiler")
            options += ["--enable-cross-compile", f"--cc={compiler}"]
    return options


def triple(name):
    if name.startswith("ios-"):
        return name.replace("ios-", "").replace("-simulator", "") + "-apple-ios" + ("-simulator" if name.endswith("simulator") else "")
    arch = "aarch64" if name.endswith(("arm64", "aarch64")) else "x86_64"
    if name.startswith("macos-"):
        return ("arm64" if arch == "aarch64" else arch) + "-apple-macosx"
    suffix = "unknown-windows-msvc" if name.startswith("windows-") else "unknown-linux-android" if name.startswith("android-") else "unknown-linux-gnu"
    return arch + "-" + suffix


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", default=host())
    parser.add_argument("--vendor", type=Path, default=ROOT / "vendor")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    name = args.platform
    supported = ["macos-arm64", "macos-x86_64", "linux-aarch64", "linux-x86_64", "windows-arm64", "windows-x86_64",
                 "android-arm64", "android-x86_64", "ios-arm64", "ios-arm64-simulator", "ios-x86_64-simulator"]
    if name not in supported:
        parser.error("Unsupported FFmpeg target")
    bundle = args.vendor.resolve() / "FFmpeg.artifactbundle"
    variant = bundle / name
    stamp = variant / "provenance.json"
    if args.check:
        try:
            info = json.loads(stamp.read_text())
            ready = info["version"] == VERSION and info["source_sha256"] == SHA256 and bool(info["files"]) and all(hashlib.sha256((variant / path).read_bytes()).hexdigest() == digest for path, digest in info["files"].items())
        except (OSError, ValueError, KeyError):
            ready = False
        raise SystemExit(0 if ready else 1)
    cache = ROOT / "build/cache"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f"ffmpeg-{VERSION}.tar.xz"
    if not archive.exists():
        urllib.request.urlretrieve(f"https://ffmpeg.org/releases/ffmpeg-{VERSION}.tar.xz", archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise ValueError("FFmpeg source SHA256 mismatch")
    source = cache / f"ffmpeg-{VERSION}"
    if not source.exists():
        with tarfile.open(archive) as tar:
            tar.extractall(cache, filter="data")
    build = ROOT / "build" / name
    build.mkdir(parents=True, exist_ok=True)
    prefix = build / "install"
    options = [f"--prefix={prefix}", "--disable-shared", "--enable-static", "--enable-pic", "--disable-autodetect",
        "--disable-gpl", "--disable-nonfree", "--disable-doc", "--disable-debug", "--disable-network", "--disable-everything",
        "--enable-avformat", "--enable-avcodec", "--enable-avfilter", "--enable-swscale", "--enable-swresample",
        "--enable-ffmpeg", "--enable-ffprobe", "--enable-indev=lavfi", "--enable-protocol=file,pipe",
        "--enable-demuxer=mov,matroska,avi,wav,mp3,aac,ogg,flac,aiff,image2",
        "--enable-decoder=h264,hevc,mpeg4,mjpeg,png,vp8,vp9,av1,aac,mp3,vorbis,opus,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_s16be",
        "--enable-parser=h264,hevc,mpeg4video,mpegaudio,aac,vorbis,opus,flac,vp9,av1",
        "--enable-encoder=mpeg4,mjpeg,png,aac,flac,pcm_s16le,pcm_f32le",
        "--enable-muxer=mp4,ipod,mov,matroska,wav,flac,image2,null",
        "--enable-filter=buffer,abuffer,buffersink,abuffersink,trim,atrim,setpts,asetpts,concat,scale,format,aformat,aresample,anull,anullsrc,null,sine,color,volume,amix,pad,fps"]
    options += target_options(name)
    subprocess.run(["sh", str(source / "configure"), *options], cwd=build, check=True)
    subprocess.run(["make", "-j4"], cwd=build, check=True)
    subprocess.run(["make", "install"], cwd=build, check=True)
    variant.mkdir(parents=True, exist_ok=True)
    shutil.copytree(prefix / "include", variant / "include", dirs_exist_ok=True)
    shutil.copytree(prefix / "lib", variant / "lib", dirs_exist_ok=True)
    if (prefix / "bin").exists():
        shutil.copytree(prefix / "bin", variant / "bin", dirs_exist_ok=True)
    for license_name in ["COPYING.LGPLv2.1", "COPYING.LGPLv3", "LICENSE.md"]:
        shutil.copy2(source / license_name, bundle / license_name)
    artifacts = {}
    manifest = bundle / "info.json"
    if manifest.exists():
        artifacts = {k: v for k, v in json.loads(manifest.read_text())["artifacts"].items() if k == "FFmpeg"}
    windows = name.startswith("windows-")
    filename = "FFmpeg.lib" if windows else "libFFmpeg.a"
    archives = [variant / "lib" / (f"{lib}.lib" if windows else f"lib{lib}.a") for lib in LIBRARIES]
    combined = variant / "lib" / filename
    if windows:
        subprocess.run(["lib", f"/OUT:{combined}", *map(str, archives)], check=True)
    elif name.startswith(("ios-", "macos-")):
        subprocess.run(["xcrun", "libtool", "-static", "-o", str(combined), *map(str, archives)], check=True)
    else:
        ar = "ar"
        if name.startswith("android-"):
            ar = next(option.split("=", 1)[1] for option in options if option.startswith("--ar="))
        script = f"CREATE {combined}\n" + "".join(f"ADDLIB {archive}\n" for archive in archives) + "SAVE\nEND\n"
        subprocess.run([ar, "-M"], input=script, text=True, check=True)
    entry = artifacts.setdefault("FFmpeg", {"type": "staticLibrary", "version": VERSION, "variants": []})
    if entry["version"] != VERSION:
        raise ValueError("Remove old FFmpeg artifacts before changing versions")
    entry["variants"] = [v for v in entry["variants"] if triple(name) not in v["supportedTriples"]]
    entry["variants"].append({"path": f"{name}/lib/{filename}", "supportedTriples": [triple(name)],
                              "staticLibraryMetadata": {"headerPaths": [f"{name}/include"]}})
    files = {str(p.relative_to(variant)): hashlib.sha256(p.read_bytes()).hexdigest() for p in variant.rglob("*") if p.is_file() and p != stamp}
    stamp.write_text(json.dumps(dict(version=VERSION, source_sha256=SHA256, license="LGPL", files=files), indent=2) + "\n")
    temporary = manifest.with_suffix(".tmp")
    temporary.write_text(json.dumps(dict(schemaVersion="1.0", artifacts=artifacts), indent=2) + "\n")
    temporary.replace(manifest)


if __name__ == "__main__":
    main()
