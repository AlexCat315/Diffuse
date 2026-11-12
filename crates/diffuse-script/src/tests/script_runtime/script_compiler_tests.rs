//! Rewritten for Rust scripts from `Engine/Tests/ScriptRuntimeTests/SwiftScriptCompilerTests.swift`.
//!
//! The Swift suite verified Clang module-map discovery for the Swift toolchain.
//! Rust scripts build a `cdylib` through cargo, so this suite covers the pieces
//! that are stable to test without invoking a real build: manifest discovery,
//! argument construction, executable resolution, cancellation and the
//! precondition errors.

use std::collections::BTreeMap;
use std::path::PathBuf;

use diffuse_kernel::codable::new_uuid;

use crate::dynamic_script::script_compiler::{
    ScriptCompilationCancellationToken, ScriptCompileError, ScriptCompiler,
};

struct TempDirectory {
    path: PathBuf,
}

impl TempDirectory {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("diffuse-script-compiler-{}", new_uuid()));
        std::fs::create_dir_all(&path).expect("create temporary directory");
        TempDirectory { path }
    }

    fn write(&self, relative: &str, contents: &str) -> PathBuf {
        let file = self.path.join(relative);
        if let Some(parent) = file.parent() {
            std::fs::create_dir_all(parent).expect("create parent directory");
        }
        std::fs::write(&file, contents).expect("write fixture file");
        file
    }
}

impl Drop for TempDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

/// A project directory resolves to its `Scripts/Cargo.toml` first.
#[test]
fn manifest_path_prefers_scripts_manifest() {
    let root = TempDirectory::new();
    let scripts_manifest = root.write("Scripts/Cargo.toml", "[package]\nname = \"scripts\"\n");
    root.write("Cargo.toml", "[package]\nname = \"project\"\n");

    let found = ScriptCompiler::manifest_path(&root.path).expect("manifest");
    assert_eq!(
        std::fs::canonicalize(found).expect("canonical manifest"),
        std::fs::canonicalize(scripts_manifest).expect("canonical scripts manifest")
    );
}

/// A directory without `Scripts/` falls back to its own manifest.
#[test]
fn manifest_path_falls_back_to_crate_manifest() {
    let root = TempDirectory::new();
    let manifest = root.write("Cargo.toml", "[package]\nname = \"project\"\n");

    let found = ScriptCompiler::manifest_path(&root.path).expect("manifest");
    assert_eq!(
        std::fs::canonicalize(found).expect("canonical manifest"),
        std::fs::canonicalize(manifest).expect("canonical fixture")
    );
}

/// A source file resolves through its ancestors.
#[test]
fn manifest_path_from_source_file() {
    let root = TempDirectory::new();
    let manifest = root.write("Cargo.toml", "[package]\nname = \"project\"\n");
    let source = root.write("src/lib.rs", "pub fn tick() {}\n");

    let found = ScriptCompiler::manifest_path(&source).expect("manifest");
    assert_eq!(
        std::fs::canonicalize(found).expect("canonical manifest"),
        std::fs::canonicalize(manifest).expect("canonical fixture")
    );
}

/// A directory without any manifest reports the missing manifest.
#[test]
fn manifest_path_reports_missing_manifest() {
    let root = TempDirectory::new();
    let error = ScriptCompiler::manifest_path(&root.path).expect_err("missing manifest");
    assert!(matches!(error, ScriptCompileError::ManifestNotFound(_)));
}

/// Cargo arguments keep the release JSON cdylib shape and append a target triple.
#[test]
fn build_arguments_include_release_library_and_target() {
    let root = TempDirectory::new();
    let manifest = root.write("Cargo.toml", "[package]\nname = \"project\"\n");
    let mut compiler = ScriptCompiler::new(root.path.join("out"));
    compiler.target_triple = Some("x86_64-unknown-linux-gnu".to_string());

    let arguments = compiler.build_arguments(&manifest);
    assert_eq!(
        arguments,
        vec![
            "build".to_string(),
            "--release".to_string(),
            "--message-format=json".to_string(),
            "--lib".to_string(),
            "--manifest-path".to_string(),
            manifest.to_string_lossy().into_owned(),
            "--target".to_string(),
            "x86_64-unknown-linux-gnu".to_string(),
        ]
    );
}

/// Executable resolution finds cargo on the current PATH.
#[test]
fn resolves_cargo_from_path() {
    let environment: BTreeMap<String, String> = std::env::vars().collect();
    let resolved = ScriptCompiler::resolve_executable_url("cargo", &environment)
        .expect("cargo must be resolvable while tests run");
    assert!(resolved.is_file());
}

/// Executable resolution reports a missing program.
#[test]
fn missing_executable_reports_error() {
    let environment: BTreeMap<String, String> = std::env::vars().collect();
    let error = ScriptCompiler::resolve_executable_url(
        "diffuse-definitely-missing-executable",
        &environment,
    )
    .expect_err("missing executable");
    assert!(matches!(error, ScriptCompileError::ExecutableNotFound(_)));
}

/// A cancelled token stops before any build work starts.
#[test]
fn cancelled_compilation_stops_before_build() {
    let root = TempDirectory::new();
    root.write("Cargo.toml", "[package]\nname = \"project\"\n");
    let compiler = ScriptCompiler::new(root.path.join("out"));
    let token = ScriptCompilationCancellationToken::new();
    token.cancel();

    let error = compiler
        .compile(&root.path, "scripts", Some(&token))
        .expect_err("cancelled");
    assert!(matches!(error, ScriptCompileError::Cancelled));
}

/// Script identifiers cannot escape the output directory.
#[test]
fn invalid_script_identifiers_are_rejected() {
    let root = TempDirectory::new();
    root.write("Cargo.toml", "[package]\nname = \"project\"\n");
    let compiler = ScriptCompiler::new(root.path.join("out"));

    for identifier in ["", ".", "..", "a/b", "a\\b"] {
        let error = compiler
            .compile(&root.path, identifier, None)
            .expect_err("invalid identifier");
        assert!(
            matches!(error, ScriptCompileError::InvalidScriptID(_)),
            "{identifier:?} must be rejected"
        );
    }
}

/// Compiling a directory without a manifest fails with `ManifestNotFound`.
#[test]
fn compilation_reports_missing_manifest() {
    let root = TempDirectory::new();
    let compiler = ScriptCompiler::new(root.path.join("out"));
    let error = compiler
        .compile(&root.path, "scripts", None)
        .expect_err("missing manifest");
    assert!(matches!(error, ScriptCompileError::ManifestNotFound(_)));
}
