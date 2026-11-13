//! `Editor/Tests/EditorCoreTests/Scripting/SourceKitLSP/AnalysisCacheTests.swift`.
//!
//! D1 rewrite: the analysis cache now belongs to rust-analyzer's cargo scratch
//! directory (`.cove/rust-analyzer/.build`) instead of SourceKit-LSP's SwiftPM
//! one, the tracked compiler is `RUSTC` and the Rust sysroot instead of
//! `SWIFT_EXEC`, and "engine modules" are the cargo crates' `Cargo.toml`/`src`
//! rather than `.swiftmodule` binaries. The invariants are unchanged: an
//! unknown or changed environment discards generated caches, a matching
//! environment retains them, and neither the workspace nor the cache may be a
//! symbolic link that would let generation write outside the project.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

use crate::scripting::rust_analyzer::language::script_language_models::ScriptLanguageSupportError;
use crate::scripting::rust_analyzer::language::script_language_workspace::ScriptLanguageWorkspace;

/// Mirrors the Swift `defer { try? removeItem(at: root) }` cleanup.
struct TempRoot {
    url: PathBuf,
}

impl TempRoot {
    fn new(prefix: &str) -> Self {
        let url =
            std::env::temp_dir().join(format!("{prefix}-{}", diffuse_kernel::codable::new_uuid()));
        std::fs::create_dir_all(&url).expect("create temp root");
        Self { url }
    }
}

impl Drop for TempRoot {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.url);
    }
}

fn workspace_at(project_root: &Path, engine_modules: Vec<String>) -> ScriptLanguageWorkspace {
    ScriptLanguageWorkspace::new(
        project_root.join("Scripts"),
        engine_modules,
        Vec::new(),
        Vec::new(),
        None,
        None,
    )
}

fn environment(compiler: &str) -> BTreeMap<String, String> {
    let mut environment = BTreeMap::new();
    environment.insert("RUSTC".to_string(), compiler.to_string());
    environment
}

fn copy_dir_all(from: &Path, to: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_dir_all(&entry.path(), &target)?;
        } else {
            std::fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}

#[cfg(windows)]
fn try_symlink_dir(target: &Path, link: &Path) -> bool {
    std::os::windows::fs::symlink_dir(target, link).is_ok()
}

#[cfg(unix)]
fn try_symlink_dir(target: &Path, link: &Path) -> bool {
    std::os::unix::fs::symlink(target, link).is_ok()
}

#[cfg(not(any(unix, windows)))]
fn try_symlink_dir(_target: &Path, _link: &Path) -> bool {
    false
}

#[test]
fn invalidates_only_when_environment_changes() {
    let root = TempRoot::new("diffuse-analysis-cache");
    let workspace = workspace_at(&root.url, Vec::new());
    workspace.synchronize(&[], &[]).expect("synchronize");

    let scratch = workspace.root_url().join(".build");
    std::fs::create_dir_all(&scratch).expect("create scratch");
    let stale = scratch.join("stale.swiftmodule");
    std::fs::write(&stale, "stale cache").expect("write stale cache");

    let executable = root
        .url
        .join("Toolchain")
        .join("usr")
        .join("bin")
        .join("rust-analyzer");
    workspace
        .prepare_scratch(&executable, &environment("/host/toolchain-a/rustc"))
        .expect("prepare scratch with toolchain a");
    assert!(
        !stale.exists(),
        "an unknown environment should discard generated caches"
    );

    let current = scratch.join("current.swiftmodule");
    std::fs::write(&current, "current cache").expect("write current cache");
    workspace
        .prepare_scratch(&executable, &environment("/host/toolchain-a/rustc"))
        .expect("prepare scratch with toolchain a again");
    assert!(
        current.exists(),
        "a matching environment should retain generated caches"
    );

    workspace
        .prepare_scratch(&executable, &environment("/host/toolchain-b/rustc"))
        .expect("prepare scratch with toolchain b");
    assert!(
        !current.exists(),
        "a changed environment should discard generated caches"
    );
}

#[test]
fn changed_engine_module_invalidates_cached_analysis() {
    let root = TempRoot::new("diffuse-analysis-cache");
    let products = root.url.join("Products");
    let module = products.join("engine");
    std::fs::create_dir_all(&module).expect("create engine module");
    let manifest = module.join("Cargo.toml");
    std::fs::write(&manifest, "first").expect("write first module");

    let workspace = workspace_at(&root.url, vec![module.to_string_lossy().into_owned()]);
    workspace.synchronize(&[], &[]).expect("synchronize");

    let executable = root.url.join("rust-analyzer");
    let scratch = workspace
        .prepare_scratch(&executable, &BTreeMap::new())
        .expect("prepare scratch");
    let cached = scratch.join("cached.swiftmodule");
    std::fs::write(&cached, "old module").expect("write cached analysis");

    // D1: rebuilding a Cove module rewrites its `Cargo.toml`.
    std::fs::write(&manifest, "second module build").expect("rebuild engine module");
    workspace
        .prepare_scratch(&executable, &BTreeMap::new())
        .expect("prepare scratch after rebuild");
    assert!(
        !cached.exists(),
        "rebuilding an engine module should invalidate cached analysis"
    );
}

#[test]
fn moved_workspace_cannot_reuse_caches() {
    let root = TempRoot::new("diffuse-analysis-cache");
    let original = workspace_at(&root.url.join("First"), Vec::new());
    original
        .synchronize(&[], &[])
        .expect("synchronize original");

    let executable = root.url.join("rust-analyzer");
    let scratch = original
        .prepare_scratch(&executable, &BTreeMap::new())
        .expect("prepare original scratch");
    std::fs::write(scratch.join("old.swiftmodule"), "old workspace paths")
        .expect("write old cache");

    let copied = workspace_at(&root.url.join("Second"), Vec::new());
    std::fs::create_dir_all(copied.project_root_url()).expect("create copied project root");
    copy_dir_all(
        &original.project_root_url().join(".cove"),
        &copied.project_root_url().join(".cove"),
    )
    .expect("copy generated workspace");

    let next = copied
        .prepare_scratch(&executable, &BTreeMap::new())
        .expect("prepare copied scratch");
    assert!(
        !next.join("old.swiftmodule").exists(),
        "a copied project cannot reuse caches that embed the old workspace path"
    );
    assert!(
        scratch.join("old.swiftmodule").exists(),
        "the original workspace cache stays intact"
    );
}

#[test]
fn refuses_linked_workspace() {
    for linked_directory in ["rust-analyzer", "Sources"] {
        let root = TempRoot::new("diffuse-analysis-cache");
        let workspace = workspace_at(&root.url, Vec::new());
        let outside = root.url.join("Unrelated");
        std::fs::create_dir_all(&outside).expect("create outside directory");
        let keep = outside.join("Cargo.toml");
        std::fs::write(&keep, "unrelated package").expect("write unrelated package");

        let link = if linked_directory == "Sources" {
            workspace.root_url().join("Sources")
        } else {
            workspace.root_url()
        };
        if let Some(parent) = link.parent() {
            std::fs::create_dir_all(parent).expect("create link parent");
        }
        if !try_symlink_dir(&outside, &link) {
            eprintln!(
                "analysis_cache_tests: symlinks are unavailable; skipping linked-workspace case `{linked_directory}`"
            );
            continue;
        }

        let result = workspace.synchronize(&[], &[]);
        assert!(
            matches!(result, Err(ScriptLanguageSupportError::Unavailable(_))),
            "a linked workspace directory must fail to synchronize"
        );
        assert_eq!(
            std::fs::read_to_string(&keep).expect("read unrelated package"),
            "unrelated package"
        );
        let mut entries: Vec<OsString> = std::fs::read_dir(&outside)
            .expect("read outside directory")
            .map(|entry| entry.expect("outside entry").file_name())
            .collect();
        entries.sort();
        assert_eq!(
            entries,
            vec![OsString::from("Cargo.toml")],
            "generation must not write through the linked directory"
        );
    }
}

#[test]
fn refuses_linked_cache() {
    let root = TempRoot::new("diffuse-analysis-cache");
    let workspace = workspace_at(&root.url, Vec::new());
    workspace.synchronize(&[], &[]).expect("synchronize");

    let outside = root.url.join("Unrelated");
    std::fs::create_dir_all(&outside).expect("create outside directory");
    let file = outside.join("keep.txt");
    std::fs::write(&file, "keep").expect("write keep");

    let link = workspace.root_url().join(".build");
    if let Some(parent) = link.parent() {
        std::fs::create_dir_all(parent).expect("create link parent");
    }
    if !try_symlink_dir(&outside, &link) {
        eprintln!("analysis_cache_tests: symlinks are unavailable; skipping linked-cache case");
        return;
    }

    let executable = root.url.join("rust-analyzer");
    let result = workspace.prepare_scratch(&executable, &BTreeMap::new());
    assert!(
        matches!(result, Err(ScriptLanguageSupportError::Unavailable(_))),
        "a linked cache directory must fail to prepare"
    );
    assert_eq!(
        std::fs::read_to_string(&file).expect("read keep"),
        "keep",
        "cache cleanup must not touch the linked target"
    );
}
