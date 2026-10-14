"""Build the pinned C API with the portable Pulley interpreter for iOS."""
import os
import re
import shutil
import subprocess

FEATURES = ("cranelift", "component-model", "pulley", "wat")


def build(source, target, cache):
    build_root = (cache / "ios-target").resolve()
    environment = dict(os.environ, CARGO_TARGET_DIR=str(build_root), IPHONEOS_DEPLOYMENT_TARGET="16.0")
    subprocess.run([
        "cargo", "build", "--manifest-path", str(source / "Cargo.toml"),
        "--locked", "--package", "wasmtime-c-api", "--target", target, "--release",
        "--no-default-features", "--features", ",".join(FEATURES), "--jobs", "4",
    ], env=environment, check=True)
    installed = cache / (target + "-install")
    headers = installed / "include"
    shutil.copytree(source / "crates/c-api/include", headers, dirs_exist_ok=True)
    config = (headers / "wasmtime/conf.h.in").read_text()
    enabled = {"WASMTIME_FEATURE_" + name.upper().replace("-", "_") for name in FEATURES}
    config = re.sub(r"#cmakedefine (\w+)", lambda match:
                    "#define " + match[1] if match[1] in enabled else "/* " + match[1] + " disabled */", config)
    (headers / "wasmtime/conf.h").write_text(config)
    (headers / "wasmtime/conf.h.in").unlink()
    (installed / "lib").mkdir(parents=True, exist_ok=True)
    shutil.copy2(build_root / target / "release/libwasmtime.a", installed / "lib/libwasmtime.a")
    shutil.copy2(source / "LICENSE", installed / "LICENSE")
    return installed
