//! Ported from `Editor/Tests/EditorCoreTests/EditorProjectLifecycleTests.swift`
//! (lifecycle and empty-viewport portions; application-owned cases live with
//! `EditorApplication`).

use std::path::{Path, PathBuf};

use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::components::core::registry::ComponentRegistry;

use crate::projects::editor_project_lifecycle::{
    EditorProjectLifecycle, EditorProjectLifecycleError, EditorProjectTemplate,
};
use crate::rendering::viewport::viewport_host::ViewportScreenFrame;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::adapter::spawn::EditorEntityTemplate;
use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

fn parent() -> PathBuf {
    let url = std::env::temp_dir().join(format!(
        "cove-project-lifecycle-{}",
        diffuse_kernel::codable::new_uuid()
    ));
    std::fs::create_dir(&url).expect("temporary parent");
    crate::projects::standardized_path(&url)
}

fn adapter() -> EditorSceneAdapter {
    EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::built_in(),
    )
}

fn bundle_available() -> bool {
    crate::editor_core_resource_bundle::EditorCoreResourceBundle::bundle_if_available().is_some()
}

/// Any folder opens as a project, gaining only a descriptor.
#[test]
fn adopt_folder() {
    let parent = parent();
    let folder = parent.join("Existing Work");
    std::fs::create_dir(&folder).expect("folder");
    std::fs::write(folder.join("main.swift"), "main").expect("main script");

    let adopted = EditorProjectLifecycle::adopt(&folder).expect("adopt");
    assert_eq!(adopted.name(), "Existing Work");
    let mut names = std::fs::read_dir(&folder)
        .expect("folder listing")
        .map(|entry| {
            entry
                .expect("entry")
                .file_name()
                .to_string_lossy()
                .into_owned()
        })
        .collect::<Vec<_>>();
    names.sort();
    assert_eq!(names, [".cove", "main.swift"]);
    let cove = std::fs::read_dir(folder.join(".cove"))
        .expect(".cove listing")
        .map(|entry| {
            entry
                .expect("entry")
                .file_name()
                .to_string_lossy()
                .into_owned()
        })
        .collect::<Vec<_>>();
    assert_eq!(cove, ["project.json"]);
    assert_eq!(
        EditorProjectLifecycle::adopt(&folder)
            .expect("second adopt")
            .descriptor,
        adopted.descriptor
    );

    let created = EditorProjectLifecycle::create("Made", &parent, EditorProjectTemplate::Blank)
        .expect("create");
    assert_eq!(
        EditorProjectLifecycle::adopt(&created.directory)
            .expect("adopt created")
            .descriptor,
        created.descriptor
    );
    assert!(EditorProjectLifecycle::adopt(&parent.join("missing")).is_err());
    std::fs::remove_dir_all(parent).ok();
}

/// Blank projects open empty and never create default scripts.
#[test]
fn blank_project() {
    let parent = parent();
    let created =
        EditorProjectLifecycle::create(" My Game ", &parent, EditorProjectTemplate::Blank)
            .expect("create");
    assert_eq!(
        created.directory.file_name().and_then(|name| name.to_str()),
        Some("My Game")
    );
    assert_eq!(
        EditorProjectLifecycle::inspect(&created.directory, true)
            .expect("inspect")
            .descriptor,
        created.descriptor
    );
    assert!(
        std::fs::read_dir(created.directory.join("Scripts"))
            .expect("scripts")
            .next()
            .is_none()
    );
    assert!(created.directory.join("Assets").is_dir());
    std::fs::remove_dir_all(parent).ok();
}

/// Creation rejects collisions and traversal without touching existing contents.
#[test]
fn creation_boundaries() {
    let parent = parent();
    let existing = parent.join("Existing");
    std::fs::create_dir(&existing).expect("existing");
    let sentinel = existing.join("keep.txt");
    std::fs::write(&sentinel, "keep").expect("sentinel");

    assert!(
        EditorProjectLifecycle::create("Existing", &parent, EditorProjectTemplate::Blank).is_err()
    );
    for name in [
        "",
        ".",
        "..",
        "../Escape",
        "A/B",
        "A\\B",
        ".hidden",
        "bad:",
        "bad\nname",
    ] {
        assert!(
            EditorProjectLifecycle::create(name, &parent, EditorProjectTemplate::Blank).is_err(),
            "{name:?} must be rejected"
        );
    }
    assert_eq!(std::fs::read(&sentinel).expect("sentinel"), b"keep");
    let names = std::fs::read_dir(&parent)
        .expect("parent listing")
        .map(|entry| {
            entry
                .expect("entry")
                .file_name()
                .to_string_lossy()
                .into_owned()
        })
        .collect::<Vec<_>>();
    assert_eq!(names, ["Existing"]);
    std::fs::remove_dir_all(parent).ok();
}

/// Opening validates first and supports legacy empty project folders.
#[test]
fn validation() {
    let parent = parent();
    assert!(EditorProjectLifecycle::inspect(&parent, true).is_err());
    assert!(
        std::fs::read_dir(&parent)
            .expect("listing")
            .next()
            .is_none()
    );

    std::fs::create_dir(parent.join(".cove")).expect(".cove");
    assert!(
        EditorProjectLifecycle::inspect(&parent, true)
            .expect("legacy project")
            .descriptor
            .is_none()
    );

    let scene = parent.join(EditorProjectLifecycle::SCENE_PATH);
    std::fs::write(&scene, "corrupt").expect("corrupt scene");
    assert!(EditorProjectLifecycle::inspect(&parent, true).is_err());
    assert_eq!(std::fs::read(&scene).expect("scene"), b"corrupt");

    std::fs::remove_dir_all(parent.join(".cove")).expect("remove .cove");

    #[cfg(unix)]
    {
        let outside = self_parent();
        std::os::unix::fs::symlink(&outside, parent.join(".cove")).expect(".cove symlink");
        assert!(EditorProjectLifecycle::inspect(&parent, true).is_err());
        assert!(
            std::fs::read_dir(&outside)
                .expect("outside listing")
                .next()
                .is_none()
        );
        std::fs::remove_dir_all(outside).ok();
    }
    std::fs::remove_dir_all(parent).ok();
}

#[cfg(unix)]
fn self_parent() -> PathBuf {
    let url = std::env::temp_dir().join(format!(
        "cove-project-lifecycle-outside-{}",
        diffuse_kernel::codable::new_uuid()
    ));
    std::fs::create_dir(&url).expect("outside parent");
    crate::projects::standardized_path(&url)
}

/// The bundled example is a writable independent copy.
#[test]
fn example() {
    if !bundle_available() {
        return;
    }
    let parent = parent();
    let first =
        EditorProjectLifecycle::create("First", &parent, EditorProjectTemplate::CrystalRush)
            .expect("first example");
    let second =
        EditorProjectLifecycle::create("Second", &parent, EditorProjectTemplate::CrystalRush)
            .expect("second example");
    assert_ne!(
        first.descriptor.as_ref().map(|descriptor| &descriptor.id),
        second.descriptor.as_ref().map(|descriptor| &descriptor.id)
    );
    let source = first.directory.join("Scripts/CrystalRush.swift");
    let repo = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../examples/CrystalRush/Scripts/CrystalRush.swift");
    assert_eq!(
        std::fs::read(&source).expect("example script"),
        std::fs::read(repo).expect("repository script")
    );
    let data = std::fs::read(first.directory.join(EditorProjectLifecycle::SCENE_PATH))
        .expect("example scene");
    let scene: crate::scene::manifest::editor_scene_manifest::EditorSceneManifest =
        serde_json::from_slice(&data).expect("decode example scene");
    assert_eq!(scene.entity_count, 1);
    assert_eq!(
        scene.roots.first().map(|root| root.name.as_str()),
        Some("Game Controller")
    );
    std::fs::write(&source, "modified").expect("modify copy");
    assert_ne!(
        std::fs::read(second.directory.join("Scripts/CrystalRush.swift")).expect("second copy"),
        b"modified"
    );
    std::fs::remove_dir_all(parent).ok();
}

/// Deletion is recoverable and legacy folders are never deleted.
#[test]
fn recoverable_deletion() {
    let parent = parent();
    let created =
        EditorProjectLifecycle::create("Trash Test", &parent, EditorProjectTemplate::Blank)
            .expect("create");
    let corrupt_scene = b"corrupt but recoverable";
    std::fs::write(
        created.directory.join(EditorProjectLifecycle::SCENE_PATH),
        corrupt_scene,
    )
    .expect("corrupt scene");

    let trash = EditorProjectLifecycle::move_to_trash(&created.directory).expect("trash");
    assert!(!created.directory.exists());
    assert_eq!(
        EditorProjectLifecycle::inspect(&trash, false)
            .expect("inspect trashed")
            .descriptor,
        created.descriptor
    );
    // Restore the test artifact so cleanup leaves no extra project behind.
    std::fs::rename(&trash, &created.directory).expect("restore");
    assert_eq!(
        EditorProjectLifecycle::inspect(&created.directory, false)
            .expect("inspect restored")
            .descriptor,
        created.descriptor
    );
    assert_eq!(
        std::fs::read(created.directory.join(EditorProjectLifecycle::SCENE_PATH))
            .expect("corrupt scene retained"),
        corrupt_scene
    );

    std::fs::create_dir(parent.join(".cove")).expect("legacy .cove");
    let error: Result<PathBuf, EditorProjectLifecycleError> =
        EditorProjectLifecycle::move_to_trash(&parent);
    assert!(error.is_err());
    assert!(created.directory.exists());
    std::fs::remove_dir_all(parent).ok();
}

/// Empty scenes can navigate and frame objects without adding camera entities
/// or dirtying the scene.
#[test]
fn empty_viewport_navigation() {
    let scene = adapter();
    scene.tick_scene_default();
    let original_revision = scene.revision();
    let original = scene.current_render_camera();
    let refreshes = std::rc::Rc::new(std::cell::Cell::new(0usize));
    let sink = refreshes.clone();
    *scene.on_viewport_camera_changed.borrow_mut() = Some(std::rc::Rc::new(move || {
        sink.set(sink.get() + 1);
    }));
    let frame = ViewportScreenFrame::new(0.0, 0.0, 800.0, 600.0);
    scene.orbit_camera(30.0, 10.0, frame);
    scene.pan_camera(20.0, 10.0, frame);
    scene.zoom_camera(0.8);
    scene.freelook_camera(
        5.0,
        5.0,
        &std::collections::BTreeSet::from([26]),
        cove_platform::KeyModifiers(0),
        1.0 / 60.0,
    );
    assert!(scene.current_render_camera() != original);
    assert_eq!(
        scene.current_render_scene().camera,
        scene.current_render_camera()
    );
    assert_eq!(scene.entity_count(), 0);
    assert_eq!(scene.revision(), original_revision);
    assert_eq!(refreshes.get(), 4);

    let cube = scene
        .spawn_entity(EditorEntityTemplate::Cube, None, None)
        .expect("cube");
    scene.set_entity_local_translation(cube, Float3::new(12.0, 4.0, 2.0));
    scene.tick_scene_default();
    scene.frame_entity_default(cube);
    assert_eq!(
        scene.current_render_camera().target,
        Float3::new(12.0, 4.0, 2.0)
    );
    assert_eq!(scene.manifest().entity_count, 1);
    let root = scene.manifest().roots.first().cloned().expect("root");
    assert!(
        root.components
            .iter()
            .find(|component| component.type_id == "camera")
            .is_none_or(|component| component.value.object_value().is_none())
    );
}
