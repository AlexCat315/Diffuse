//! Compiles the screenshot decoder the Android and browser validations use.
//!
//! `CImageDecoder` in the Swift package was a separate C target that linked
//! `stb_image` directly; the workspace has no engine dependency for `xtask`, so
//! the same two functions are built here from the vendored header.

fn main() {
    println!("cargo:rerun-if-changed=native/decode.c");
    println!("cargo:rerun-if-changed=native/decode.h");
    println!("cargo:rerun-if-changed=native/stb_image.h");
    cc::Build::new()
        .file("native/decode.c")
        .include("native")
        .warnings(false)
        .compile("cove_tool_image_decode");
}
