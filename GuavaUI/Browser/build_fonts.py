#!/usr/bin/env python3
"""Build the pinned, unmodified FreeType/HarfBuzz submodules for Swift's WASI SDK."""
import json
import hashlib
import os
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
BUILD = HERE / ".build" / "fonts"
VENDOR = HERE / ".build" / "font-vendor"


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    fonts = ROOT / "Text" / "Fonts"
    for item in json.loads((fonts / "manifest.json").read_text())["fonts"]:
        data = (fonts / item["file"]).read_bytes()
        if len(data) != item["bytes"] or hashlib.sha256(data).hexdigest() != item["sha256"]:
            raise SystemExit(f"Font checksum mismatch: {item['file']}")
    sdk = os.environ.get("GUAVA_WASM_SDK", "swift-6.4.0-RELEASE_wasm")
    config = subprocess.check_output(["swift", "sdk", "configure", sdk, "--show-configuration"], text=True)
    sysroot = next(Path(line.split(": ", 1)[1]) for line in config.splitlines() if line.startswith("sdkRootPath: "))
    # On macOS /usr/bin/swift is an xcrun shim, not the actual toolchain.
    info = json.loads(subprocess.check_output(["swiftc", "-print-target-info"], text=True))
    compiler = Path(info["paths"]["runtimeResourcePath"]).parent.parent / "bin"
    def tool(name):
        candidate = compiler / name
        resolved = candidate if candidate.is_file() else shutil.which(name)
        if not resolved:
            raise SystemExit(f"Missing {name}: install a Swift/LLVM toolchain with Wasm support")
        return Path(resolved)
    clang, clangxx, ar, ranlib = (tool(name) for name in ("clang", "clang++", "llvm-ar", "llvm-ranlib"))
    toolchain = BUILD / "wasi.cmake"
    BUILD.mkdir(parents=True, exist_ok=True)
    toolchain.write_text(f'''set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR wasm32)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_C_COMPILER "{clang}")
set(CMAKE_CXX_COMPILER "{clangxx}")
set(CMAKE_AR "{ar}")
set(CMAKE_RANLIB "{ranlib}")
set(CMAKE_C_COMPILER_TARGET wasm32-unknown-wasip1)
set(CMAKE_CXX_COMPILER_TARGET wasm32-unknown-wasip1)
set(CMAKE_SYSROOT "{sysroot}")
set(CMAKE_FIND_ROOT_PATH "{sysroot}" "{BUILD / 'install'}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_C_FLAGS_INIT "-mllvm -wasm-enable-sjlj")
set(CMAKE_CXX_FLAGS_INIT "-mllvm -wasm-enable-sjlj -fno-exceptions -fno-threadsafe-statics -DHB_NO_MT")
''')
    common = ["-G", "Ninja", f"-DCMAKE_TOOLCHAIN_FILE={toolchain}",
              "-DCMAKE_C_FLAGS=-mllvm -wasm-enable-sjlj",
              "-DCMAKE_CXX_FLAGS=-mllvm -wasm-enable-sjlj -fno-exceptions -fno-threadsafe-statics -DHB_NO_MT",
              f"-DCMAKE_INSTALL_PREFIX={BUILD / 'install'}", "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF"]
    sources = ROOT / "third-party"
    for name, options in [
        ("freetype", [f"-DFT_DISABLE_{feature}=ON" for feature in ("ZLIB", "BZIP2", "PNG", "HARFBUZZ", "BROTLI")]),
        ("harfbuzz", [f"-DCMAKE_PREFIX_PATH={BUILD / 'install'}", "-DHB_HAVE_FREETYPE=ON",
                       "-DHAVE_SYS_MMAN_H=OFF", "-DHAVE_MMAP=OFF", "-DHAVE_MPROTECT=OFF",
                       "-DHB_BUILD_SUBSET=OFF", "-DHB_BUILD_UTILS=OFF", "-DHB_BUILD_TESTS=OFF",
                       "-DHB_HAVE_GLIB=OFF", "-DHB_HAVE_ICU=OFF", "-DHB_HAVE_GRAPHITE2=OFF", "-DHB_HAVE_CORETEXT=OFF"]),
    ]:
        if not (sources / name / "CMakeLists.txt").is_file():
            raise SystemExit(f"Missing {name}: run git submodule update --init GuavaUI/third-party/{name}")
        run("cmake", "-S", sources / name, "-B", BUILD / name, *common, *options)
        run("cmake", "--build", BUILD / name, "--parallel", os.environ.get("CMAKE_BUILD_PARALLEL_LEVEL", "4"))
        run("cmake", "--install", BUILD / name)

    for module, library, headers, version in [
        ("CFreeType", "freetype", "freetype2", "2.14.3"),
        ("CHarfBuzz", "harfbuzz", "harfbuzz", "14.5.1"),
    ]:
        bundle = VENDOR / f"{module}.artifactbundle"
        variant = bundle / "wasm32-wasip1"
        (variant / "lib").mkdir(parents=True, exist_ok=True)
        shutil.copytree(BUILD / "install" / "include" / headers, variant / "include", dirs_exist_ok=True)
        shutil.copy2(BUILD / "install" / "lib" / f"lib{library}.a", variant / "lib")
        for source, target in [(f"{module}.h", f"{module}.h"), (f"{module}.modulemap", "module.modulemap")]:
            shutil.copy2(sources / "cmake" / "templates" / source, variant / "include" / target)
        (bundle / "info.json").write_text(json.dumps({"schemaVersion": "1.0", "artifacts": {module: {
            "type": "staticLibrary", "version": version, "variants": [{
                "path": f"wasm32-wasip1/lib/lib{library}.a", "supportedTriples": ["wasm32-unknown-wasip1"],
                "staticLibraryMetadata": {"headerPaths": ["wasm32-wasip1/include"]},
            }],
        }}}, indent=2) + "\n")


if __name__ == "__main__":
    main()
