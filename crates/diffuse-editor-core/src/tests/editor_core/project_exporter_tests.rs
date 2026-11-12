//! Ported from `Editor/Tests/EditorCoreTests/ProjectExporterTests.swift`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use cove_system::paths::PathIdentity;
use diffuse_assets::asset_registry::ImportableAssetKind;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::components::core::value::{ComponentValue, ManifestComponent};
use diffuse_script::core::script_component::{ScriptBinding, ScriptBindingID};
use diffuse_script::interop::component_registry_script_codec::encode_script_binding;

use crate::assets::asset_catalog::EditorAsset;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::game_save_document::GameSaveDocument;
use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;
use crate::scene::manifest::editor_scene_manifest::EditorSceneManifest;
use crate::scene::manifest::node::EditorSceneManifestNode;
use crate::scene::project_exporter::{
    ProjectExportAssetList, ProjectExportError, ProjectExporter, ProjectExporterError,
};
use crate::scripting::assets::script_asset_registry::ScriptAssetRegistry;
use crate::scripting::dynamic::project_compiled_scripts::{
    ProjectCompiledScripts, ProjectCompiledScriptsError, ProjectScriptBuildConfiguration,
    ProjectScriptDelivery,
};
use crate::scripting::dynamic::project_script_catalog::ProjectScriptCatalog;
use crate::scripting::static_::project_static_scripts::ProjectStaticScripts;

struct TempDirectory {
    url: PathBuf,
}

impl TempDirectory {
    fn new(prefix: &str) -> Self {
        let url =
            std::env::temp_dir().join(format!("{prefix}-{}", diffuse_kernel::codable::new_uuid()));
        std::fs::create_dir_all(&url).expect("temporary directory");
        TempDirectory { url }
    }

    fn path(&self) -> &Path {
        &self.url
    }

    fn join(&self, relative: &str) -> PathBuf {
        self.url.join(relative)
    }

    fn write(&self, relative: &str, contents: &str) -> PathBuf {
        self.write_bytes(relative, contents.as_bytes())
    }

    fn write_bytes(&self, relative: &str, contents: &[u8]) -> PathBuf {
        let url = self.join(relative);
        if let Some(parent) = url.parent() {
            std::fs::create_dir_all(parent).expect("parent directory");
        }
        std::fs::write(&url, contents).expect("fixture file");
        url
    }
}

impl Drop for TempDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.url);
    }
}

fn adapter() -> EditorSceneAdapter {
    EditorSceneAdapter::new(
        true,
        ComponentRegistry::new(),
        EditorInspectorRendererRegistry::new(),
    )
}

fn exporter_error(error: &ProjectExportError) -> Option<&ProjectExporterError> {
    match error {
        ProjectExportError::Exporter(inner) => Some(inner),
        ProjectExportError::Scripts(ProjectCompiledScriptsError::Exporter(inner)) => Some(inner),
        _ => None,
    }
}

fn script_manifest(node_name: &str, identifier: &str, is_enabled: bool) -> EditorSceneManifest {
    let binding =
        ScriptBinding::from_identifier(identifier, ScriptBindingID::new(), is_enabled, "{}");
    let script_value = ComponentValue::Object(BTreeMap::from([(
        "bindings".to_string(),
        ComponentValue::Array(vec![ComponentValue::Object(encode_script_binding(
            &binding,
        ))]),
    )]));
    let node = EditorSceneManifestNode::with_options(
        1,
        node_name,
        "empty",
        None,
        vec![ManifestComponent::new("script", script_value)],
        Vec::new(),
    );
    EditorSceneManifest::new(0, 1, vec![node])
}

fn make_executable(url: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(url, std::fs::Permissions::from_mode(0o755))
            .expect("executable permissions");
    }
    #[cfg(not(unix))]
    {
        let _ = url;
    }
}

#[cfg(target_os = "macos")]
fn is_executable(url: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(url)
        .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[test]
fn static_gameplay_export_stages_canonical_source_ids_and_validates_scene_bindings() {
    let project = TempDirectory::new("cove-export");
    let output = project.join("export");
    let source = "pub struct GameScript;\n";
    let file = project.write("Scripts/src/player.rs", source);
    let asset = ScriptAssetRegistry::new(&project.path().to_string_lossy())
        .resolve(vec![file])
        .expect("script asset resolution")
        .into_iter()
        .next()
        .expect("script asset");
    let runtime_identifier = asset.id.runtime_identifier();
    let manifest = script_manifest("Player", &runtime_identifier, true);
    let configuration = ProjectScriptBuildConfiguration::with_delivery(
        ProjectScriptDelivery::StaticLink,
        "cargo",
        BTreeMap::new(),
    );

    ProjectExporter::export(
        &manifest,
        "Mobile",
        &[],
        Some(project.path()),
        None,
        Some(&configuration),
        &output,
    )
    .expect("static export");

    let index: ProjectStaticScripts = serde_json::from_slice(
        &std::fs::read(output.join(ProjectStaticScripts::RELATIVE_PATH)).expect("static index"),
    )
    .expect("static index");
    let entry = index.entries.first().expect("static entry");
    assert_eq!(entry.identifier, runtime_identifier);
    assert_eq!(
        std::fs::read_to_string(output.join(&entry.source)).expect("staged source"),
        source
    );
    assert!(!output.join(ProjectCompiledScripts::RELATIVE_PATH).exists());

    let scene_url = GameSaveDocument::url(ProjectExporter::SCENE_SLOT, &output);
    let scene = GameSaveDocument::read(&scene_url)
        .expect("saved scene")
        .expect("saved scene");
    assert_eq!(scene.manifest, manifest);
}

#[test]
fn scripts_without_a_build_configuration_fail_instead_of_disappearing_from_the_game() {
    let project = TempDirectory::new("cove-export");
    let output = project.join("export");
    let manifest = adapter().manifest();
    ProjectExporter::export(&manifest, "Previous", &[], None, None, None, &output)
        .expect("initial export");
    let descriptor_url = output.join("build.json");
    let previous = std::fs::read(&descriptor_url).expect("previous descriptor");
    project.write("Scripts/src/player.rs", "pub struct GameScript;\n");

    let error = ProjectExporter::export(
        &manifest,
        "Next",
        &[],
        Some(project.path()),
        None,
        None,
        &output,
    )
    .expect_err("export requires a script build configuration");
    assert!(matches!(
        exporter_error(&error),
        Some(ProjectExporterError::MissingScriptBuildConfiguration)
    ));
    assert_eq!(
        std::fs::read(&descriptor_url).expect("descriptor"),
        previous
    );
}

#[test]
fn enabled_missing_bindings_reject_export_while_disabled_bindings_may_remain() {
    let output = TempDirectory::new("cove-export");

    let error = ProjectExporter::export(
        &script_manifest("Missing", "game.missing", true),
        "Demo",
        &[],
        None,
        None,
        None,
        output.path(),
    )
    .expect_err("unresolved enabled binding");
    match exporter_error(&error) {
        Some(ProjectExporterError::UnresolvedScriptBindings(bindings)) => {
            let expected = vec!["Missing: game.missing".to_string()];
            assert_eq!(bindings, &expected);
        }
        other => panic!("unexpected export error: {other:?}"),
    }

    ProjectExporter::export(
        &script_manifest("Missing", "game.missing", false),
        "Demo",
        &[],
        None,
        None,
        None,
        output.path(),
    )
    .expect("disabled binding export");
    assert_eq!(
        ProjectExporter::read_descriptor(output.path())
            .expect("descriptor")
            .entity_count,
        1
    );
}

#[test]
fn export_writes_a_descriptor_asset_list_and_player_loadable_scene() {
    let source = adapter();
    let manifest = source.manifest_for_selection(source.default_selection_id());
    let output = TempDirectory::new("cove-export");

    let descriptor =
        ProjectExporter::export(&manifest, "Demo", &[], None, None, None, output.path())
            .expect("export");
    assert_eq!(descriptor.app_name, "Demo");
    assert_eq!(descriptor.entity_count, manifest.entity_count);
    assert_eq!(descriptor.schema_version, ProjectExporter::SCHEMA_VERSION);

    assert!(output.join("build.json").is_file());
    assert!(output.join("assets.json").is_file());
    // Scene is written where the player's project loader reads it.
    let scene_url = GameSaveDocument::url(ProjectExporter::SCENE_SLOT, output.path());
    assert!(scene_url.is_file());

    // The descriptor reads back identically.
    assert_eq!(
        ProjectExporter::read_descriptor(output.path()).expect("descriptor"),
        descriptor
    );
}

#[test]
fn exported_scene_round_trips_and_a_fresh_adapter_loads_the_same_entity_count() {
    let source = adapter();
    let manifest = source.manifest_for_selection(source.default_selection_id());
    let output = TempDirectory::new("cove-export");

    ProjectExporter::export(&manifest, "Demo", &[], None, None, None, output.path())
        .expect("export");

    // Load exactly the way GameApplication does: GameSaveDocument at slot 0.
    let scene_url = GameSaveDocument::url(ProjectExporter::SCENE_SLOT, output.path());
    let document = GameSaveDocument::read(&scene_url)
        .expect("saved scene")
        .expect("saved scene");
    let restored = adapter();
    let result = restored.load(&document.manifest);
    assert_eq!(result.entity_count, manifest.entity_count);
}

#[test]
fn asset_list_captures_referenced_assets() {
    let output = TempDirectory::new("cove-export");
    let project = TempDirectory::new("cove-export");
    let model_url = project.write_bytes("models/barrel.glb", &[1, 2, 3]);

    let assets = [EditorAsset::new(
        "a1",
        "Barrel",
        "models/barrel.glb",
        model_url.to_string_lossy(),
        ImportableAssetKind::Glb,
        3,
    )];
    let descriptor = ProjectExporter::export(
        &adapter().manifest(),
        "Demo",
        &assets,
        None,
        None,
        None,
        output.path(),
    )
    .expect("export");
    assert_eq!(descriptor.asset_count, 1);

    let data = std::fs::read(output.join("assets.json")).expect("asset list");
    let list: ProjectExportAssetList = serde_json::from_slice(&data).expect("asset list");
    assert_eq!(list.assets.len(), 1);
    assert_eq!(
        list.assets.first().map(|asset| asset.id.as_str()),
        Some("a1")
    );
    assert_eq!(
        list.assets
            .first()
            .map(|asset| asset.relative_path.as_str()),
        Some("models/barrel.glb")
    );
}

#[test]
fn export_copies_model_dependencies_audio_resources_and_project_scripts() {
    let project = TempDirectory::new("cove-export");
    let output = project.join("export");
    let model_url = project.write(
        "Assets/Models/ship.gltf",
        r#"{"asset":{"version":"2.0"},"buffers":[{"uri":"ship.bin","byteLength":4}],"images":[{"uri":"textures/albedo.png"}]}"#,
    );
    project.write_bytes("Assets/Models/ship.bin", &[0, 1, 2, 3]);
    project.write_bytes(
        "Assets/Models/textures/albedo.png",
        &[0x89, 0x50, 0x4E, 0x47],
    );
    project.write_bytes("Assets/Audio/theme.wav", &[0x52, 0x49, 0x46, 0x46]);
    project.write(
        "Scripts/scripts.json",
        r#"{"schemaVersion":1,"scripts":[]}"#,
    );
    let asset = EditorAsset::new(
        "Assets/Models/ship.gltf",
        "ship",
        "Assets/Models/ship.gltf",
        model_url.to_string_lossy(),
        ImportableAssetKind::Gltf,
        9,
    );

    ProjectExporter::export(
        &adapter().manifest(),
        "Demo",
        std::slice::from_ref(&asset),
        Some(project.path()),
        None,
        None,
        &output,
    )
    .expect("export");

    assert!(output.join("Assets/Models/ship.gltf").is_file());
    assert!(output.join("Assets/Models/ship.bin").is_file());
    assert!(output.join("Assets/Models/textures/albedo.png").is_file());
    assert!(output.join("Assets/Audio/theme.wav").is_file());
    assert!(output.join(ProjectScriptCatalog::RELATIVE_PATH).is_file());
}

#[test]
fn export_includes_parent_relative_buffers_and_keeps_the_bundle_when_a_dependency_is_missing() {
    let project = TempDirectory::new("cove-export");
    let output = project.join("export");
    let model = project.write(
        "Assets/Models/ship.gltf",
        r#"{"buffers":[{"uri":"../Shared/ship.bin","byteLength":4}]}"#,
    );
    let buffer = project.write_bytes("Assets/Shared/ship.bin", &[0, 1, 2, 3]);
    let contents = std::fs::read(&buffer).expect("buffer");
    let asset = EditorAsset::new(
        "Assets/Models/ship.gltf",
        "ship",
        "Assets/Models/ship.gltf",
        model.to_string_lossy(),
        ImportableAssetKind::Gltf,
        9,
    );
    let manifest = adapter().manifest();

    ProjectExporter::export(
        &manifest,
        "Demo",
        std::slice::from_ref(&asset),
        Some(project.path()),
        None,
        None,
        &output,
    )
    .expect("export");
    let exported_buffer = output.join("Assets/Shared/ship.bin");
    assert_eq!(
        std::fs::read(&exported_buffer).expect("exported buffer"),
        contents
    );

    std::fs::remove_file(&buffer).expect("remove buffer");
    let error = ProjectExporter::export(
        &manifest,
        "Demo",
        std::slice::from_ref(&asset),
        Some(project.path()),
        None,
        None,
        &output,
    )
    .expect_err("missing dependency");
    match exporter_error(&error) {
        Some(ProjectExporterError::MissingAsset(path)) => {
            assert!(PathIdentity::same_location(Path::new(path), &buffer));
        }
        other => panic!("unexpected export error: {other:?}"),
    }
    assert_eq!(
        std::fs::read(&exported_buffer).expect("exported buffer"),
        contents
    );
}

#[test]
fn re_export_replaces_stale_bundle_contents() {
    let project = TempDirectory::new("cove-export");
    let output = project.join("export");
    let source = project.write_bytes("old.glb", &[1, 2, 3]);
    let asset = EditorAsset::new(
        "old.glb",
        "old",
        "old.glb",
        source.to_string_lossy(),
        ImportableAssetKind::Glb,
        2,
    );
    let manifest = adapter().manifest();

    ProjectExporter::export(
        &manifest,
        "Demo",
        std::slice::from_ref(&asset),
        None,
        None,
        None,
        &output,
    )
    .expect("export");
    assert!(output.join("old.glb").is_file());

    ProjectExporter::export(&manifest, "Demo", &[], None, None, None, &output).expect("re-export");
    assert!(!output.join("old.glb").exists());
}

#[test]
fn custom_project_local_output_is_excluded_from_runtime_resource_scanning() {
    let project = TempDirectory::new("cove-export");
    let output = project.join("Builds/Demo");

    project.write_bytes("Assets/Audio/theme.wav", &[0x52, 0x49, 0x46, 0x46]);
    // Simulate a previous export. Without explicitly excluding the requested
    // output directory, its stale resource is copied into Builds/Demo again.
    project.write("Builds/Demo/old.wav", "stale");

    ProjectExporter::export(
        &adapter().manifest(),
        "Demo",
        &[],
        Some(project.path()),
        None,
        None,
        &output,
    )
    .expect("export");

    assert!(output.join("Assets/Audio/theme.wav").is_file());
    assert!(
        !output.join("Builds/Demo/old.wav").exists(),
        "the previous bundle was rescanned and recopied into itself"
    );
    assert!(!output.join("old.wav").exists());
}

#[test]
fn export_rejects_replacing_a_directory_that_contains_the_source_project() {
    let container = TempDirectory::new("cove-export");
    let project = container.join("Project");
    let marker = container.write("Project/keep.txt", "keep");

    let error = ProjectExporter::export(
        &adapter().manifest(),
        "Demo",
        &[],
        Some(&project),
        None,
        None,
        container.path(),
    )
    .expect_err("output contains source project");
    match exporter_error(&error) {
        Some(ProjectExporterError::OutputContainsSourceProject(path)) => {
            assert!(PathIdentity::same_location(
                Path::new(path),
                container.path()
            ));
        }
        other => panic!("unexpected export error: {other:?}"),
    }
    assert!(marker.is_file());
}

#[test]
fn export_rejects_asset_destinations_that_traverse_outside_the_bundle() {
    let root = TempDirectory::new("cove-export");
    let output = root.join("Export");
    let source = root.write_bytes("source.glb", &[1, 2, 3]);
    let asset = EditorAsset::new(
        "asset",
        "asset",
        "../escaped.glb",
        source.to_string_lossy(),
        ImportableAssetKind::Glb,
        2,
    );

    let error = ProjectExporter::export(
        &adapter().manifest(),
        "Demo",
        &[asset],
        None,
        None,
        None,
        &output,
    )
    .expect_err("unsafe asset destination");
    match exporter_error(&error) {
        Some(ProjectExporterError::UnsafeRelativePath(path)) => {
            assert_eq!(path, "../escaped.glb");
        }
        other => panic!("unexpected export error: {other:?}"),
    }
    assert_eq!(std::fs::read(&source).expect("source"), [1, 2, 3]);
}

#[test]
fn export_normalizes_portable_asset_paths_and_rejects_duplicate_mesh_slots() {
    let root = TempDirectory::new("cove-export");
    let output = root.join("Export");
    let first_url = root.write_bytes("first.glb", &[1]);
    let second_url = root.write_bytes("second.glb", &[2]);
    let first = EditorAsset::new(
        "first",
        "first",
        "Assets\\first.glb",
        first_url.to_string_lossy(),
        ImportableAssetKind::Glb,
        3,
    );

    ProjectExporter::export(
        &adapter().manifest(),
        "Demo",
        std::slice::from_ref(&first),
        None,
        None,
        None,
        &output,
    )
    .expect("export");
    let list: ProjectExportAssetList =
        serde_json::from_slice(&std::fs::read(output.join("assets.json")).expect("asset list"))
            .expect("asset list");
    assert_eq!(
        list.assets
            .first()
            .map(|asset| asset.relative_path.as_str()),
        Some("Assets/first.glb")
    );
    assert!(output.join("Assets/first.glb").is_file());

    let second = EditorAsset::new(
        "second",
        "second",
        "Assets/second.glb",
        second_url.to_string_lossy(),
        ImportableAssetKind::Glb,
        3,
    );
    let error = ProjectExporter::export(
        &adapter().manifest(),
        "Demo",
        &[first, second],
        None,
        None,
        None,
        &output,
    )
    .expect_err("duplicate mesh index");
    match exporter_error(&error) {
        Some(ProjectExporterError::ConflictingMeshIndex(index)) => assert_eq!(*index, 3),
        other => panic!("unexpected export error: {other:?}"),
    }
}

#[test]
fn export_packages_a_self_contained_application_when_a_player_is_available() {
    let output = TempDirectory::new("cove-export");
    let player_directory = TempDirectory::new("cove-export");
    let player = player_directory.write("CovePlayer", "#!/bin/sh\nexit 0\n");
    make_executable(&player);
    player_directory.write("CoveUI_Test.bundle/marker.txt", "resource");
    player_directory.write("CoveUI_Test.resources/marker.txt", "resource");
    player_directory.write("runtime.dylib", "runtime");

    ProjectExporter::export(
        &adapter().manifest(),
        "Demo/Game",
        &[],
        None,
        Some(&player),
        None,
        output.path(),
    )
    .expect("export with player");

    #[cfg(not(target_os = "macos"))]
    {
        let player_root = output.join("Player");
        let executable = ProjectExporter::portable_player_executable_url(output.path());
        assert!(player_root.is_dir());
        assert!(executable.is_file());
        assert!(player_root.join("CoveUI_Test.bundle/marker.txt").is_file());
        assert!(
            player_root
                .join("CoveUI_Test.resources/marker.txt")
                .is_file()
        );
        assert!(player_root.join("runtime.dylib").is_file());
        assert!(output.join("build.json").is_file());
        assert!(GameSaveDocument::url(ProjectExporter::SCENE_SLOT, output.path()).is_file());
    }

    #[cfg(target_os = "macos")]
    {
        let app = ProjectExporter::application_bundle_url("Demo/Game", output.path());
        let executable = ProjectExporter::application_executable_url("Demo/Game", output.path());
        assert!(app.is_dir());
        assert!(is_executable(&executable));
        assert!(
            app.join("Contents/Resources/CoveUI_Test.bundle/marker.txt")
                .is_file()
        );
        assert!(
            app.join("Contents/Resources/CoveUI_Test.resources/marker.txt")
                .is_file()
        );
        assert!(app.join("Contents/MacOS/runtime.dylib").is_file());
        let embedded_project = app.join("Contents/Resources/CoveProject");
        assert!(embedded_project.join("build.json").is_file());
        assert!(GameSaveDocument::url(ProjectExporter::SCENE_SLOT, &embedded_project).is_file());
        let plist = std::fs::read_to_string(app.join("Contents/Info.plist"))
            .expect("application Info.plist");
        assert!(plist.contains("<key>CFBundleExecutable</key>"));
        assert!(plist.contains("<string>Demo_Game</string>"));
        assert!(plist.contains("<key>LSMinimumSystemVersion</key>"));
        assert!(plist.contains("<string>26.0</string>"));
    }
}

#[cfg(not(target_os = "macos"))]
#[test]
fn portable_player_layout_copies_executable_resources_and_runtime_libraries() {
    let project = TempDirectory::new("cove-export");
    let player_build = TempDirectory::new("cove-export");
    let player = player_build.write("custom-player", "#!/bin/sh\nexit 0\n");
    make_executable(&player);
    player_build.write("GameRuntime.resources/marker.txt", "resource");
    player_build.write("Lib/libswiftCore.so", "runtime");
    player_build.write("runtime.dll", "native");

    ProjectExporter::create_portable_player_bundle(&player, project.path())
        .expect("portable player bundle");

    let executable = ProjectExporter::portable_player_executable_url(project.path());
    assert!(executable.is_file());
    assert!(
        project
            .path()
            .join("Player/GameRuntime.resources/marker.txt")
            .is_file()
    );
    assert!(project.path().join("Player/Lib/libswiftCore.so").is_file());
    assert!(project.path().join("Player/runtime.dll").is_file());
    assert!(!project.path().join("Player/custom-player").exists());
}
