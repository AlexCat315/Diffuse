"""Stage a complete variant transactionally without discarding other targets."""
import json
import shutil
import tempfile
import time
import uuid
from pathlib import Path
from contextlib import contextmanager
from staging.archive import digest


@contextmanager
def staging_lock(vendor):
    vendor.mkdir(parents=True, exist_ok=True)
    lock = vendor / ".wasmtime-staging.lock"
    deadline = time.monotonic() + 30
    while True:
        try:
            lock.mkdir()
            break
        except FileExistsError:
            if time.monotonic() > deadline:
                raise TimeoutError(f"Wasmtime staging is locked: {lock}")
            time.sleep(0.2)
    try:
        yield
    finally:
        lock.rmdir()


def ready(vendor, name, platform, version, source_checksum):
    bundle = vendor / "Wasmtime.artifactbundle"
    try:
        metadata = json.loads((bundle / "info.json").read_text())["artifacts"]["Wasmtime"]
        provenance = json.loads((bundle / name / "provenance.json").read_text())
        variant = next(item for item in metadata["variants"] if platform["triple"] in item["supportedTriples"])
        files = provenance["files"]
        return (metadata["version"] == version == provenance["version"]
                and provenance["source"]["sha256"] == source_checksum
                and variant["path"].startswith(name + "/lib/")
                and provenance["execution"] == ("pulley" if name.startswith("ios-") else "native-or-pulley")
                and bool(files) and "include/wasmtime.h" in files
                and all(digest(bundle / name / path) == checksum for path, checksum in files.items()))
    except (OSError, KeyError, StopIteration, ValueError):
        return False


def stage(installed, vendor, name, platform, version, source):
    with staging_lock(vendor):
        _stage(installed, vendor, name, platform, version, source)


def _stage(installed, vendor, name, platform, version, source):
    bundle = vendor / "Wasmtime.artifactbundle"
    bundle.mkdir(parents=True, exist_ok=True)
    manifest = bundle / "info.json"
    info = json.loads(manifest.read_text()) if manifest.exists() else {"schemaVersion": "1.0", "artifacts": {}}
    artifact = info["artifacts"].setdefault("Wasmtime", {"type": "staticLibrary", "version": version, "variants": []})
    if artifact["version"] != version:
        raise ValueError("Remove the old Wasmtime artifact bundle before changing versions")
    library_name = "wasmtime.lib" if name.startswith("windows-") else "libwasmtime.a"
    relative_library = f"lib/{library_name}"
    with tempfile.TemporaryDirectory(prefix=".stage-", dir=bundle) as directory:
        candidate = Path(directory) / name
        shutil.copytree(installed / "include", candidate / "include")
        (candidate / "lib").mkdir()
        shutil.copy2(installed / "lib" / library_name, candidate / relative_library)
        files = {str(path.relative_to(candidate)): digest(path) for path in candidate.rglob("*") if path.is_file()}
        provenance = dict(version=version, source=source, sha256=files[relative_library], files=files, linkage="static",
                          execution="pulley" if name.startswith("ios-") else "native-or-pulley")
        (candidate / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
        shutil.copy2(installed / "LICENSE", bundle / "LICENSE")
        artifact["variants"] = [item for item in artifact["variants"] if platform["triple"] not in item["supportedTriples"]]
        artifact["variants"].append({"path": f"{name}/{relative_library}", "supportedTriples": [platform["triple"]],
                                     "staticLibraryMetadata": {"headerPaths": [f"{name}/include"]}})
        artifact["variants"].sort(key=lambda item: item["path"])
        temporary = manifest.with_suffix(".tmp")
        temporary.write_text(json.dumps(info, indent=2) + "\n")
        variant = bundle / name
        backup = bundle / (".previous-" + uuid.uuid4().hex)
        existed = variant.exists()
        if existed:
            variant.rename(backup)
        try:
            candidate.rename(variant)
            temporary.replace(manifest)
        except BaseException:
            shutil.rmtree(variant, ignore_errors=True)
            if existed:
                backup.rename(variant)
            raise
        shutil.rmtree(backup, ignore_errors=True)
    # Remove only files owned by the replaced dynamic integration.
    shutil.rmtree(vendor / "Wasmtime.xcframework", ignore_errors=True)
    for old in ("Wasmtime-build-manifest.json", "Wasmtime-LICENSE"):
        (vendor / old).unlink(missing_ok=True)
    print(f"Staged Wasmtime {version}: {name} ({provenance['execution']})", flush=True)
