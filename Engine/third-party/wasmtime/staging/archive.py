"""Verified upstream downloads. Never execute code from an unverified archive."""
import hashlib
import subprocess
from pathlib import Path


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fetch(url, checksum, cache):
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / url.rsplit("/", 1)[-1]
    if not archive.exists() or digest(archive) != checksum:
        temporary = archive.with_suffix(archive.suffix + ".partial")
        subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--output", str(temporary), url], check=True)
        if digest(temporary) != checksum:
            temporary.unlink()
            raise ValueError(f"SHA256 mismatch: {url}")
        temporary.replace(archive)
    destination = cache / archive.name.removesuffix(".tar.xz").removesuffix(".tar.gz").removesuffix(".zip")
    if not (destination / ".extracted").exists():
        destination.mkdir(parents=True, exist_ok=True)
        subprocess.run(["cmake", "-E", "tar", "xf", str(archive.resolve())], cwd=destination, check=True)
        (destination / ".extracted").touch()
    roots = [child for child in destination.iterdir() if child.is_dir()]
    if len(roots) != 1:
        raise ValueError(f"Unexpected upstream archive layout: {archive}")
    return roots[0]
