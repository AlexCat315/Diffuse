//! Compiles the Apple Vision bridge on macOS/iOS (MIGRATION.md §2.3).
//!
//! Other targets have no Vision framework; the Rust worker reports the backend
//! as unavailable there instead of linking a stub.

use std::env;

fn main() {
    println!("cargo:rerun-if-changed=native/apple_vision.m");
    println!("cargo:rerun-if-changed=native/apple_vision.h");

    let target = env::var("TARGET").expect("cargo sets TARGET for build scripts");
    if !(target.contains("apple-darwin") || target.contains("apple-ios")) {
        return;
    }

    cc::Build::new()
        .file("native/apple_vision.m")
        .include("native")
        .flag("-fobjc-arc")
        .compile("diffuse_apple_vision");

    for framework in ["Foundation", "Vision"] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
}
