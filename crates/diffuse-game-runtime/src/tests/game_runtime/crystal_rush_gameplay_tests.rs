//! Ported from `Editor/Tests/GameRuntimeTests/CrystalRushGameplayTests.swift`.
//!
//! The Swift case compiles `examples/CrystalRush/Scripts/CrystalRush.swift`
//! through `DynamicScriptManager` and runs the compiled artifacts. D1 replaces
//! the Swift script with a Rust `Scripts/` crate; `Docs/rust-migration-files.json`
//! still marks `examples/CrystalRush/Scripts/src/lib.rs` as pending, so the full
//! translation is kept with its original assertions and ignored until that
//! example and its `Scripts/Cargo.toml` exist (MIGRATION.md §5).
//!
//! Two mechanical differences from the Swift test are part of the port rather
//! than the fixture gap:
//! - the export directory sits beside the temporary project, because
//!   `ProjectExporter` rejects an output nested inside its source project;
//! - the export runs without `playerExecutableURL`, since the gameplay under
//!   test is loaded by `GameApplication` and does not need the player bundle.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use diffuse_editor_core::scene::manifest::editor_scene_manifest::EditorSceneManifest;
use diffuse_editor_core::scene::manifest::node::EditorSceneManifestNode;
use diffuse_editor_core::scene::project_exporter::ProjectExporter;
use diffuse_editor_core::scripting::assets::script_asset_registry::ScriptAssetRegistry;
use diffuse_editor_core::scripting::dynamic::project_compiled_scripts::ProjectScriptBuildConfiguration;
use diffuse_kernel::input_event::{InputEvent, KeyEvent, KeyModifiers};
use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::components::core::value::{ComponentValue, ManifestComponent};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::input_action::Scancode;
use diffuse_scene::rendering::render_extraction::RenderMeshComponent;
use diffuse_script::ScriptDebugState;
use diffuse_script::core::script_component::{ScriptBinding, ScriptBindingID};
use diffuse_script::interop::component_registry_script_codec::encode_script_binding;

use crate::game_application::GameApplication;

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
}

impl Drop for TempDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.url);
    }
}

fn copy_directory(from: &Path, to: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_directory(&entry.path(), &target)?;
        } else {
            std::fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}

fn tick(game: &GameApplication, frame: &mut u64, count: i64, events: Vec<InputEvent>) {
    for index in 0..count.max(0) {
        *frame = frame.wrapping_add(1);
        game.scene.tick_scene(
            1.0 / 60.0,
            *frame,
            if index == 0 {
                events.clone()
            } else {
                Vec::new()
            },
            false,
        );
    }
}

fn key(scan: u32, down: bool) -> InputEvent {
    let event = KeyEvent {
        scancode: scan,
        keycode: scan,
        modifiers: KeyModifiers::default(),
        is_repeat: false,
    };
    if down {
        InputEvent::KeyDown(event)
    } else {
        InputEvent::KeyUp(event)
    }
}

fn values(game: &GameApplication) -> BTreeMap<String, String> {
    game.scene
        .scene()
        .resource::<ScriptDebugState>()
        .and_then(|state| state.entities.values().next().cloned())
        .unwrap_or_default()
}

fn entity(game: &GameApplication, name: &str) -> EntityID {
    game.scene
        .scene()
        .find_entity_named(name)
        .unwrap_or_else(|| panic!("missing entity {name}"))
}

fn position(game: &GameApplication, name: &str, point: Float3) {
    game.scene
        .set_entity_local_translation(entity(game, name).raw_value(), point);
}

fn translation(game: &GameApplication, name: &str) -> Float3 {
    game.scene
        .entity_local_translation(entity(game, name).raw_value())
        .unwrap_or_else(|| panic!("{name} has no local transform"))
}

#[test]
#[ignore = "blocked: examples/CrystalRush/Scripts/src/lib.rs (Rust script) is still pending"]
fn playable_loop() -> Result<(), Box<dyn std::error::Error>> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("crate lives under the workspace root");
    let project = TempDirectory::new("cove-crystal-rules");
    let export_root = TempDirectory::new("cove-crystal-rules-export");
    let output = export_root.join("export");
    let scripts = root.join("examples").join("CrystalRush").join("Scripts");
    copy_directory(&scripts, &project.join("Scripts"))?;

    let source = project.join("Scripts").join("src").join("lib.rs");
    assert!(
        source.is_file(),
        "the Rust CrystalRush script is missing: {}",
        source.display()
    );
    let registry = ScriptAssetRegistry::new(&project.path().to_string_lossy());
    let identifier = registry
        .resolve(vec![source])?
        .into_iter()
        .next()
        .expect("script asset")
        .id
        .runtime_identifier();
    let binding = ScriptBinding::from_identifier(identifier, ScriptBindingID::new(), true, "{}");
    let script_value = ComponentValue::Object(BTreeMap::from([(
        "bindings".to_string(),
        ComponentValue::Array(vec![ComponentValue::Object(encode_script_binding(
            &binding,
        ))]),
    )]));
    let node = EditorSceneManifestNode::with_options(
        0,
        "Game Controller",
        "empty",
        None,
        vec![ManifestComponent::new("script", script_value)],
        Vec::new(),
    );
    let manifest = EditorSceneManifest::new(0, 1, vec![node]);

    let configuration =
        ProjectScriptBuildConfiguration::discover_default(&std::env::current_exe()?);
    ProjectExporter::export(
        &manifest,
        "CrystalRules",
        &[],
        Some(project.path()),
        None,
        Some(&configuration),
        &output,
    )?;

    // Gameplay must work solely from compiled artifacts, without its source.
    std::fs::remove_dir_all(project.join("Scripts"))?;

    let game = GameApplication::new(Some(&output), None, None, None)?;
    let mut frame = 0u64;

    tick(&game, &mut frame, 120, Vec::new());
    let state = values(&game);
    assert_eq!(state.get("phase").map(String::as_str), Some("ready"));
    assert_eq!(
        state.get("remaining_seconds").map(String::as_str),
        Some("50.00")
    );
    assert_eq!(game.scene.manifest().entity_count, 60);
    assert!(!game.scene.current_in_game_canvas().commands.is_empty());

    tick(&game, &mut frame, 1, vec![key(Scancode::SPACE, true)]);
    tick(
        &game,
        &mut frame,
        1,
        vec![key(Scancode::SPACE, false), key(Scancode::D, true)],
    );
    tick(&game, &mut frame, 10, Vec::new());
    let player_x: f32 = values(&game)
        .get("player_x")
        .expect("player_x")
        .parse()
        .expect("player_x is a float");
    assert!(player_x > 0.0);
    tick(&game, &mut frame, 1, vec![key(Scancode::D, false)]);

    for index in 1..=8 {
        let name = format!("Crystal {index}");
        let gem_translation = translation(&game, &name);
        position(&game, &name, gem_translation);
        tick(&game, &mut frame, 1, Vec::new());
        let gem = entity(&game, &name);
        assert_eq!(
            game.scene
                .scene()
                .component::<RenderMeshComponent>(gem)
                .map(|component| component.is_visible),
            Some(false)
        );
    }
    assert_eq!(values(&game).get("score").map(String::as_str), Some("8"));
    assert_eq!(values(&game).get("phase").map(String::as_str), Some("won"));

    tick(&game, &mut frame, 1, vec![key(Scancode::R, true)]);
    tick(&game, &mut frame, 1, vec![key(Scancode::R, false)]);
    assert_eq!(values(&game).get("score").map(String::as_str), Some("0"));
    assert_eq!(values(&game).get("hearts").map(String::as_str), Some("3"));
    assert_eq!(
        values(&game).get("phase").map(String::as_str),
        Some("playing")
    );

    for expected_hearts in [2, 1, 0] {
        let enemy_translation = translation(&game, "Sentinel 1");
        position(&game, "Sentinel 1", enemy_translation);
        tick(&game, &mut frame, 1, Vec::new());
        let expected = expected_hearts.to_string();
        assert_eq!(
            values(&game).get("hearts").map(String::as_str),
            Some(expected.as_str())
        );
        if expected_hearts > 0 {
            position(&game, "Player", Float3::new(8.0, 0.6, 6.0));
            tick(&game, &mut frame, 86, Vec::new());
        }
    }
    assert_eq!(values(&game).get("phase").map(String::as_str), Some("lost"));

    tick(&game, &mut frame, 1, vec![key(Scancode::R, true)]);
    tick(&game, &mut frame, 1, vec![key(Scancode::R, false)]);
    position(&game, "Player", Float3::new(8.0, 0.6, 6.0));
    tick(&game, &mut frame, 120, vec![key(Scancode::D, true)]);
    assert_eq!(
        values(&game).get("player_x").map(String::as_str),
        Some("8.25")
    );
    tick(&game, &mut frame, 1, vec![key(Scancode::D, false)]);
    tick(&game, &mut frame, 3100, Vec::new());
    assert_eq!(values(&game).get("phase").map(String::as_str), Some("lost"));
    assert_eq!(
        values(&game).get("remaining_seconds").map(String::as_str),
        Some("0.00")
    );
    Ok(())
}
