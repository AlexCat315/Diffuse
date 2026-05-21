#!/usr/bin/env python3
# Build Engine + GuavaUI native C/C++ dependencies.
# Usage: python bootstrap.py [--force]

import os
import sys
import subprocess
import shutil
import tempfile
from pathlib import Path

# ── Args ──────────────────────────────────────────────────────────────────────

force = "--force" in sys.argv[1:]

# ── Repository root ───────────────────────────────────────────────────────────

root = Path(sys.argv[0]).resolve().parent

# ── Build environment ─────────────────────────────────────────────────────────

env = os.environ.copy()
env["MIMALLOC_DISABLE_REDIRECT"] = "1"

if sys.platform == "win32" and "VCToolsInstallDir" not in env:
    x86 = env.get("ProgramFiles(x86)", "C:\\Program Files (x86)")
    pf  = env.get("ProgramFiles",       "C:\\Program Files")
    vcvars = None

    # Locate via vswhere.exe
    vswhere = os.path.join(x86, "Microsoft Visual Studio", "Installer", "vswhere.exe")
    if os.path.exists(vswhere):
        r = subprocess.run(
            [vswhere, "-latest", "-products", "*",
             "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
             "-property", "installationPath"],
            capture_output=True, text=True
        )
        path = r.stdout.strip()
        if path:
            c = os.path.join(path, "VC", "Auxiliary", "Build", "vcvarsall.bat")
            if os.path.exists(c):
                vcvars = c

    # Fallback: well-known VS 2022 edition paths
    if vcvars is None:
        for ed in ["Community", "Professional", "Enterprise", "BuildTools"]:
            c = os.path.join(pf, "Microsoft Visual Studio", "2022", ed,
                             "VC", "Auxiliary", "Build", "vcvarsall.bat")
            if os.path.exists(c):
                vcvars = c
                break

    if vcvars:
        comspec = env.get("ComSpec", "C:\\Windows\\System32\\cmd.exe")
        r = subprocess.run(
            [comspec, "/s", "/c", f'"{vcvars}" x64 >nul 2>&1 && set'],
            capture_output=True
        )
        raw = r.stdout
        text = raw.decode("utf-8", errors="replace") if raw else ""
        for line in text.splitlines():
            if "=" in line:
                k, _, v = line.partition("=")
                env[k] = v
    else:
        print("warning: VS 2022 C++ tools not found — cmake may fail to link.", file=sys.stderr)

# ── Sentinels ─────────────────────────────────────────────────────────────────

engine_done   = root / "Engine"  / "vendor" / "SDL3.artifactbundle"
guava_ui_done = root / "GuavaUI" / "vendor" / "CFreeType.artifactbundle"

if not force and engine_done.exists() and guava_ui_done.exists():
    print("Native deps already built. Run `python bootstrap.py --force` to rebuild.")
    sys.exit(0)

# ── cmake ─────────────────────────────────────────────────────────────────────

cmake = shutil.which("cmake", path=env.get("PATH"))
if cmake is None:
    print("error: cmake not found on PATH — install CMake 3.20+ first.", file=sys.stderr)
    sys.exit(1)

# ── Helpers ───────────────────────────────────────────────────────────────────

def shell(*args: str) -> None:
    print("$", " ".join(args))
    r = subprocess.run(list(args), env=env)
    if r.returncode != 0:
        print(f"error: {Path(args[0]).name} exited {r.returncode}", file=sys.stderr)
        sys.exit(r.returncode)

# ── Engine ────────────────────────────────────────────────────────────────────

engine_src     = str(root / "Engine"  / "third-party")
engine_bld     = str(root / "Engine"  / "build" / "native")
install_prefix = str(Path(tempfile.gettempdir()) / "guava-native-install")

print("\n── Engine ───────────────────────────────────────────────────────────")
shell(cmake, "-S", engine_src, "-B", engine_bld, "-DCMAKE_BUILD_TYPE=Release")
shell(cmake, "--build", engine_bld, "--parallel")
shell(cmake, "--install", engine_bld, "--prefix", install_prefix)

# ── GuavaUI ───────────────────────────────────────────────────────────────────

guava_src = str(root / "GuavaUI" / "third-party")
guava_bld = str(root / "GuavaUI" / "build" / "native")

print("\n── GuavaUI ──────────────────────────────────────────────────────────")
shell(cmake, "-S", guava_src, "-B", guava_bld, "-DCMAKE_BUILD_TYPE=Release")
shell(cmake, "--build", guava_bld, "--parallel")
shell(cmake, "--install", guava_bld, "--prefix", install_prefix)

print("\nDone. Run: swift build --package-path Editor")
