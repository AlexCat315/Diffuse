//! Builds the `COpenEXRBridge` C++ sources and links the pinned OpenEXR/Imath
//! bundle.
//!
//! MIGRATION.md §2.3: the bridge stays C++17, lives in `native/`, and is
//! compiled with `cc`. OpenEXR itself is an artifact bundle staged by
//! `cargo xtask native-bootstrap`; `DIFFUSE_NATIVE_ROOT` (default `vendor/`,
//! resolved against the workspace root) names the directory that holds it.
//! A missing artifact is a hard error rather than a silent skip.

use std::env;
use std::path::PathBuf;

/// Artifact bundle variant directory for a target triple, matching the Swift
/// `native-bootstrap` naming.
fn variant(target: &str) -> String {
    let arch = if target.starts_with("aarch64") || target.starts_with("arm64") {
        "arm64"
    } else if target.starts_with("x86_64") {
        "x86_64"
    } else {
        panic!(
            "OpenEXR artifacts are not published for target {target}: no known variant for its architecture. \
             Stage one under DIFFUSE_NATIVE_ROOT or extend `variant()` in crates/diffuse-exr/build.rs."
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
        format!("linux-{arch}")
    } else {
        panic!(
            "OpenEXR artifacts are not published for target {target}. \
             Stage one under DIFFUSE_NATIVE_ROOT or extend `variant()` in crates/diffuse-exr/build.rs."
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
        .expect("diffuse-exr lives under crates/")
        .to_path_buf();

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
    let bundle = root.join("ocio_openexr.artifactbundle").join(&variant);
    let include = bundle.join("include");
    let lib = bundle.join("lib");
    let msvc = target.contains("msvc");

    // `libOpenEXR_combined.a` on the Unix-like targets, `OpenEXR_combined.lib`
    // on MSVC. Both spellings are accepted so a cross-published bundle works.
    let candidates: [&str; 2] = if msvc {
        ["OpenEXR_combined.lib", "libOpenEXR_combined.a"]
    } else {
        ["libOpenEXR_combined.a", "OpenEXR_combined.lib"]
    };
    let archive = candidates
        .iter()
        .map(|file| lib.join(file))
        .find(|path| path.is_file());

    let Some(_archive) = archive else {
        let tried = candidates
            .iter()
            .map(|file| lib.join(file).display().to_string())
            .collect::<Vec<_>>()
            .join(", ");
        panic!(
            "OpenEXR artifacts for target {target} are missing.\n  artifact root: {}\n  headers:       {}\n  library:       tried {tried}\nRun `cargo xtask native-bootstrap` to stage them under vendor/, or point DIFFUSE_NATIVE_ROOT at an existing artifact root.",
            root.display(),
            include.display()
        );
    };
    if !include.is_dir() {
        panic!(
            "OpenEXR headers for target {target} are missing.\n  artifact root: {}\n  headers:       {}\nRun `cargo xtask native-bootstrap` to stage them under vendor/, or point DIFFUSE_NATIVE_ROOT at an existing artifact root.",
            root.display(),
            include.display()
        );
    }

    let mut build = cc::Build::new();
    build
        .cpp(true)
        .file("native/openexr_bridge.cpp")
        .include("native")
        .include("native/include")
        .include(&include)
        .include(include.join("OpenEXR"))
        .include(include.join("Imath"))
        .std("c++17")
        .warnings(true);
    build.compile("copenexr_bridge");

    println!("cargo:rustc-link-search=native={}", lib.display());
    println!("cargo:rustc-link-lib=static=OpenEXR_combined");

    // Mirrors the C++ runtime selection Cove uses in Text/rust/build.rs.
    let os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if msvc {
        // The MSVC C++ runtime is selected by the compiler flags.
    } else if os == "android" {
        println!("cargo:rustc-link-lib=c++_shared");
    } else {
        println!("cargo:rustc-link-lib=c++");
        if os == "linux" {
            println!("cargo:rustc-link-lib=stdc++");
        }
    }
    if os != "windows" {
        println!("cargo:rustc-link-lib=m");
    }
}
