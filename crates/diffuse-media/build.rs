//! Builds the `CFFmpegBridge` C sources and links the pinned FFmpeg bundle.
//!
//! MIGRATION.md §2.3: the bridge stays C, lives in `native/`, and is compiled
//! with `cc`. FFmpeg itself is an artifact bundle staged by
//! `cargo xtask native-bootstrap`; `DIFFUSE_NATIVE_ROOT` (default `vendor/`,
//! resolved against the workspace root) names the directory that holds it.
//! A missing artifact is a hard error: skipping the link would produce a crate
//! that builds but cannot decode anything.

use std::env;
use std::path::PathBuf;

/// Artifact bundle variant directory for a target triple, matching the Swift
/// `Tools.swift` / `native-bootstrap` naming.
fn variant(target: &str) -> String {
    let arch = if target.starts_with("aarch64") || target.starts_with("arm64") {
        "arm64"
    } else if target.starts_with("x86_64") {
        "x86_64"
    } else {
        panic!(
            "FFmpeg artifacts are not published for target {target}: no known variant for its architecture. \
             Stage one under DIFFUSE_NATIVE_ROOT or extend `variant()` in crates/diffuse-media/build.rs."
        );
    };
    if target.contains("apple-darwin") {
        format!("macos-{arch}")
    } else if target.contains("apple-ios") {
        let simulator = target.ends_with("-sim") || target.starts_with("x86_64");
        format!("ios-{arch}{}", if simulator { "-simulator" } else { "" })
    } else if target.contains("android") {
        format!("android-{arch}")
    } else if target.contains("windows") {
        format!("windows-{arch}")
    } else if target.contains("linux") {
        // Swift names the 64-bit ARM Linux variant `linux-aarch64`.
        format!("linux-{arch}")
    } else {
        panic!(
            "FFmpeg artifacts are not published for target {target}. \
             Stage one under DIFFUSE_NATIVE_ROOT or extend `variant()` in crates/diffuse-media/build.rs."
        );
    }
}

fn main() {
    println!("cargo:rerun-if-env-changed=DIFFUSE_NATIVE_ROOT");
    println!("cargo:rerun-if-changed=native");

    let target = env::var("TARGET").expect("cargo sets TARGET for build scripts");
    let manifest_dir = PathBuf::from(
        env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR for build scripts"),
    );
    let workspace = manifest_dir
        .parent()
        .and_then(|path| path.parent())
        .expect("diffuse-media lives under crates/")
        .to_path_buf();

    // `DIFFUSE_NATIVE_ROOT` is relative to the workspace root unless absolute.
    let root = match env::var_os("DIFFUSE_NATIVE_ROOT") {
        Some(value) => {
            let path = PathBuf::from(value);
            if path.is_absolute() {
                path
            } else {
                workspace.join(path)
            }
        }
        None => workspace.join("vendor"),
    };

    let variant = variant(&target);
    let bundle = root.join("FFmpeg.artifactbundle").join(&variant);
    let include = bundle.join("include");
    let lib = bundle.join("lib");
    let msvc = target.contains("msvc");

    // The artifact bundle names the archive per platform: `libFFmpeg.a` on the
    // Unix-like targets and `FFmpeg.lib` on MSVC. Accept either spelling rather
    // than assuming how a cross-published bundle was packed.
    let candidates: [(&str, &str); 2] = if msvc {
        [("FFmpeg.lib", "FFmpeg"), ("libFFmpeg.a", "FFmpeg")]
    } else {
        [("libFFmpeg.a", "FFmpeg"), ("FFmpeg.lib", "FFmpeg")]
    };
    let archive = candidates
        .iter()
        .map(|(file, _)| lib.join(file))
        .find(|path| path.is_file());

    let Some(_archive) = archive else {
        let tried = candidates
            .iter()
            .map(|(file, _)| lib.join(file).display().to_string())
            .collect::<Vec<_>>()
            .join(", ");
        panic!(
            "FFmpeg artifacts for target {target} are missing.\n  artifact root: {}\n  headers:       {}\n  library:       tried {tried}\nRun `cargo xtask native-bootstrap` to stage them under vendor/, or point DIFFUSE_NATIVE_ROOT at an existing artifact root.",
            root.display(),
            include.display()
        );
    };
    if !include.is_dir() {
        panic!(
            "FFmpeg headers for target {target} are missing.\n  artifact root: {}\n  headers:       {}\nRun `cargo xtask native-bootstrap` to stage them under vendor/, or point DIFFUSE_NATIVE_ROOT at an existing artifact root.",
            root.display(),
            include.display()
        );
    }

    let mut build = cc::Build::new();
    build
        .file("native/Decoder.c")
        .file("native/Audio.c")
        .file("native/Video.c")
        .include("native")
        .include("native/include")
        .include(&include)
        .std("c11")
        .warnings(true);
    build.compile("cffmpeg_bridge");

    println!("cargo:rustc-link-search=native={}", lib.display());
    println!("cargo:rustc-link-lib=static=FFmpeg");

    // Mirrors the Swift target's linker settings in Engine/Media/Package.swift.
    let os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    match os.as_str() {
        "linux" => {
            println!("cargo:rustc-link-lib=m");
            println!("cargo:rustc-link-lib=pthread");
        }
        "android" => {
            println!("cargo:rustc-link-lib=m");
        }
        "windows" => {
            println!("cargo:rustc-link-lib=bcrypt");
        }
        _ => {
            println!("cargo:rustc-link-lib=m");
        }
    }
}
