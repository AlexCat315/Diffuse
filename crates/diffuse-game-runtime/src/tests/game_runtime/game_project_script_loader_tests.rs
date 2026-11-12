//! Ported from `Editor/Tests/GameRuntimeTests/GameProjectScriptLoaderTests.swift`.

use std::path::{Path, PathBuf};
use std::process::Command;

use diffuse_assets::swift_json;
use diffuse_editor_core::scripting::dynamic::project_compiled_scripts::{
    ProjectCompiledScriptEntry, ProjectCompiledScripts,
};
use diffuse_kernel::codable::new_uuid;
use diffuse_script::ScriptRuntime;

use crate::game_project_script_loader::{GameProjectScriptLoadError, GameProjectScriptLoader};

struct TemporaryProject(PathBuf);

impl TemporaryProject {
    fn new(prefix: &str) -> Self {
        let url = std::env::temp_dir().join(format!("{prefix}-{}", new_uuid()));
        std::fs::create_dir_all(&url).expect("temporary project");
        Self(url)
    }

    fn path(&self) -> &Path {
        &self.0
    }

    fn write_manifest(&self, manifest: &ProjectCompiledScripts) {
        let url = self.0.join(ProjectCompiledScripts::RELATIVE_PATH);
        if let Some(parent) = url.parent() {
            std::fs::create_dir_all(parent).expect("manifest directory");
        }
        let text = swift_json::to_sorted_pretty(manifest).expect("encode manifest");
        std::fs::write(url, text).expect("write manifest");
    }
}

impl Drop for TemporaryProject {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn entry(
    identifier: &str,
    display_name: &str,
    library_path: &str,
    sha256: &str,
) -> ProjectCompiledScriptEntry {
    ProjectCompiledScriptEntry::new(identifier, display_name, Vec::new(), library_path, sha256)
}

fn load_error(project: &TemporaryProject) -> GameProjectScriptLoadError {
    GameProjectScriptLoader::new()
        .load(project.path(), &ScriptRuntime::new())
        .expect_err("invalid compiled scripts")
}

/// Projects without compiled scripts retain preset-only playback.
#[test]
fn missing_manifest() {
    let project = TemporaryProject::new("cove-script-export");
    let entries = GameProjectScriptLoader::new()
        .load(project.path(), &ScriptRuntime::new())
        .expect("preset-only playback");
    assert!(entries.is_empty());
}

/// Incompatible script artifacts are rejected before loading.
#[test]
fn incompatible_target() {
    let project = TemporaryProject::new("cove-script-export");
    project.write_manifest(&ProjectCompiledScripts::with_target(
        Vec::new(),
        ProjectCompiledScripts::CURRENT_VERSION,
        "different-platform".to_string(),
    ));

    let error = load_error(&project);
    assert!(matches!(
        error,
        GameProjectScriptLoadError::IncompatibleTarget(ref target)
            if target == "different-platform"
    ));
}

/// Unsupported manifest versions are rejected before loading.
#[test]
fn unsupported_version() {
    let project = TemporaryProject::new("cove-script-export");
    project.write_manifest(&ProjectCompiledScripts::with_target(
        Vec::new(),
        ProjectCompiledScripts::CURRENT_VERSION + 1,
        ProjectCompiledScripts::current_target(),
    ));

    let error = load_error(&project);
    assert!(matches!(
        error,
        GameProjectScriptLoadError::UnsupportedVersion(value)
            if value == ProjectCompiledScripts::CURRENT_VERSION + 1
    ));
}

/// Library paths cannot traverse outside the export.
#[test]
fn escaping_library_path() {
    let project = TemporaryProject::new("cove-script-export");
    project.write_manifest(&ProjectCompiledScripts::new(vec![entry(
        "scripts.asset.test",
        "Test",
        "../outside.dylib",
        "",
    )]));

    let error = load_error(&project);
    assert!(matches!(
        error,
        GameProjectScriptLoadError::InvalidLibraryPath(ref path) if path == "../outside.dylib"
    ));
}

/// Libraries must live under `Scripts/Compiled/`.
#[test]
fn library_outside_compiled_directory() {
    let project = TemporaryProject::new("cove-script-export");
    project.write_manifest(&ProjectCompiledScripts::new(vec![entry(
        "scripts.asset.test",
        "Test",
        "Scripts/other.dylib",
        "",
    )]));

    let error = load_error(&project);
    assert!(matches!(
        error,
        GameProjectScriptLoadError::InvalidLibraryPath(ref path) if path == "Scripts/other.dylib"
    ));
}

/// Identifiers must use the project script namespace and stay unique.
#[test]
fn invalid_identifier() {
    let project = TemporaryProject::new("cove-script-export");
    project.write_manifest(&ProjectCompiledScripts::new(vec![entry(
        "game.test",
        "Test",
        "Scripts/Compiled/test.dylib",
        "",
    )]));

    let error = load_error(&project);
    assert!(matches!(
        error,
        GameProjectScriptLoadError::InvalidIdentifier(ref identifier) if identifier == "game.test"
    ));
}

/// Legacy identifiers repeat the namespace and uniqueness checks.
#[test]
fn duplicate_identifier() {
    let project = TemporaryProject::new("cove-script-export");
    project.write_manifest(&ProjectCompiledScripts::new(vec![
        ProjectCompiledScriptEntry::new(
            "scripts.asset.one",
            "One",
            vec!["scripts.asset.one".to_string()],
            "Scripts/Compiled/test.dylib",
            "",
        ),
    ]));

    let error = load_error(&project);
    assert!(matches!(
        error,
        GameProjectScriptLoadError::InvalidIdentifier(ref identifier)
            if identifier == "scripts.asset.one"
    ));
}

/// Corrupted libraries never register partially loaded gameplay.
#[test]
fn corrupted_artifact() {
    let project = TemporaryProject::new("cove-script-export");
    let path = "Scripts/Compiled/test.dylib";
    let library = project.path().join(path);
    std::fs::create_dir_all(library.parent().expect("compiled directory"))
        .expect("compiled directory");
    std::fs::write(&library, "corrupted").expect("library fixture");
    project.write_manifest(&ProjectCompiledScripts::new(vec![entry(
        "scripts.asset.test",
        "Test",
        path,
        "not-the-digest",
    )]));
    let runtime = ScriptRuntime::new();

    let error = GameProjectScriptLoader::new()
        .load(project.path(), &runtime)
        .expect_err("corrupted library");
    assert!(matches!(
        error,
        GameProjectScriptLoadError::CorruptedLibrary(ref value) if value == path
    ));
    assert!(runtime.registered_script_identifiers().is_empty());
}

/// A manifest entry whose library is absent fails instead of registering it.
#[test]
fn missing_library() {
    let project = TemporaryProject::new("cove-script-export");
    project.write_manifest(&ProjectCompiledScripts::new(vec![entry(
        "scripts.asset.test",
        "Test",
        "Scripts/Compiled/missing.dylib",
        "",
    )]));

    let error = load_error(&project);
    assert!(matches!(error, GameProjectScriptLoadError::Io(_)));
}

/// Loads a precompiled Rust cdylib, validates its digest, and registers every
/// identifier without a compiler or project sources in the export.
#[test]
fn exported_gameplay_loads_and_registers() {
    let fixture = TemporaryProject::new("cove-script-fixture");
    write_fixture_crate(fixture.path());
    let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".to_string());
    let status = Command::new(cargo)
        .arg("build")
        .arg("--quiet")
        .arg("--manifest-path")
        .arg(fixture.path().join("Cargo.toml"))
        .arg("--target-dir")
        .arg(fixture.path().join("target"))
        .status()
        .expect("run cargo for the script fixture");
    assert!(status.success(), "script fixture failed to build");

    let library_name = format!(
        "{}game_script_fixture{}",
        std::env::consts::DLL_PREFIX,
        std::env::consts::DLL_SUFFIX
    );
    let built = fixture
        .path()
        .join("target")
        .join("debug")
        .join(&library_name);
    let project = TemporaryProject::new("cove-script-export");
    let relative_path = format!("Scripts/Compiled/{library_name}");
    let destination = project.path().join(&relative_path);
    std::fs::create_dir_all(destination.parent().expect("compiled directory"))
        .expect("compiled directory");
    std::fs::copy(&built, &destination).expect("stage compiled library");
    let digest =
        ProjectCompiledScripts::digest(&std::fs::read(&destination).expect("library bytes"));
    let manifest = ProjectCompiledScripts::new(vec![ProjectCompiledScriptEntry::new(
        "scripts.asset.valid",
        "GameScript",
        vec!["scripts.game-script".to_string()],
        relative_path.clone(),
        digest.clone(),
    )]);
    project.write_manifest(&manifest);
    let runtime = ScriptRuntime::new();

    let entries = GameProjectScriptLoader::new()
        .load(project.path(), &runtime)
        .expect("compiled gameplay");

    assert_eq!(entries, manifest.entries);
    let identifiers = runtime.registered_script_identifiers();
    assert!(identifiers.contains(&"scripts.asset.valid".to_string()));
    assert!(identifiers.contains(&"scripts.game-script".to_string()));

    // D1 compiles every project script into one shared cdylib. The manifest
    // records file stems, so a shared library selects the catalog entry by its
    // PascalCase form.
    let shared = ProjectCompiledScripts::new(vec![
        ProjectCompiledScriptEntry::new(
            "scripts.asset.game",
            "game_script",
            Vec::new(),
            relative_path.clone(),
            digest.clone(),
        ),
        ProjectCompiledScriptEntry::new(
            "scripts.asset.hud",
            "hud_script",
            vec!["scripts.hud-script".to_string()],
            relative_path,
            digest,
        ),
    ]);
    project.write_manifest(&shared);
    let shared_runtime = ScriptRuntime::new();
    let shared_entries = GameProjectScriptLoader::new()
        .load(project.path(), &shared_runtime)
        .expect("shared compiled gameplay");

    assert_eq!(shared_entries, shared.entries);
    let identifiers = shared_runtime.registered_script_identifiers();
    assert!(identifiers.contains(&"scripts.asset.game".to_string()));
    assert!(identifiers.contains(&"scripts.asset.hud".to_string()));
    assert!(identifiers.contains(&"scripts.hud-script".to_string()));
}

fn write_fixture_crate(directory: &Path) {
    std::fs::create_dir_all(directory.join("src")).expect("fixture source directory");
    let api = Path::new(env!("CARGO_MANIFEST_DIR")).join("../diffuse-script-api");
    let api = std::fs::canonicalize(&api).unwrap_or(api);
    let mut api_text = api.to_string_lossy().replace('\\', "/");
    if let Some(stripped) = api_text.strip_prefix("//?/") {
        api_text = stripped.to_string();
    }
    let manifest = format!(
        r#"[package]
name = "game_script_fixture"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["cdylib"]

[dependencies]
diffuse-script-api = {{ path = "{api_text}" }}
"#
    );
    std::fs::write(directory.join("Cargo.toml"), manifest).expect("fixture manifest");
    std::fs::write(
        directory.join("src").join("lib.rs"),
        r#"use std::sync::OnceLock;

use diffuse_script_api::{
    ScriptAuthoring, ScriptBehavior, ScriptDefinition, ScriptDefinitionBuilder,
    ScriptPropertyValue,
};

#[derive(Default)]
pub struct GameScript;

impl ScriptBehavior for GameScript {}

impl ScriptAuthoring for GameScript {
    fn definition() -> &'static ScriptDefinition {
        static DEFINITION: OnceLock<ScriptDefinition> = OnceLock::new();
        DEFINITION.get_or_init(|| {
            ScriptDefinitionBuilder::new()
                .property("speed", ScriptPropertyValue::Number(2.0))
                .build()
        })
    }
}

#[derive(Default)]
pub struct HudScript;

impl ScriptBehavior for HudScript {}

impl ScriptAuthoring for HudScript {
    fn definition() -> &'static ScriptDefinition {
        static DEFINITION: OnceLock<ScriptDefinition> = OnceLock::new();
        DEFINITION.get_or_init(|| ScriptDefinitionBuilder::new().build())
    }
}

diffuse_script_api::diffuse_scripts!(GameScript, HudScript);
"#,
    )
    .expect("fixture source");
}
