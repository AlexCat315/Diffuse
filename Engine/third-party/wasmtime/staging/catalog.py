"""One pinned platform catalog shared by standalone and CMake staging."""
import json
import platform
import sys
from pathlib import Path


def read():
    return json.loads((Path(__file__).resolve().parents[1] / "catalog.json").read_text())


def host():
    architecture = platform.machine().lower()
    if architecture not in ("arm64", "aarch64", "x86_64", "amd64"):
        raise ValueError(f"Unsupported native architecture: {architecture}")
    arm = architecture in ("arm64", "aarch64")
    if sys.platform == "darwin":
        return "macos-arm64" if arm else "macos-x86_64"
    if sys.platform == "win32":
        return "windows-arm64" if arm else "windows-x86_64"
    if sys.platform.startswith("linux"):
        return "linux-aarch64" if arm else "linux-x86_64"
    raise ValueError("Specify a supported --platform for this host")
