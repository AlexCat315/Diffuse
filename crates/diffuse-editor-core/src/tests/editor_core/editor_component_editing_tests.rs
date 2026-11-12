//! Ported from `Editor/Tests/EditorCoreTests/EditorComponentEditingTests.swift`.

use std::collections::BTreeSet;
use std::rc::Rc;

use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::AnimationGraphPlayer;
use diffuse_scene::rendering::render_extraction::LightComponent;

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::adapter::spawn::EditorEntityTemplate;
use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

fn adapter() -> EditorSceneAdapter {
    EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    )
}

fn make_entity(adapter: &EditorSceneAdapter) -> u64 {
    adapter
        .with_scene_mut(|scene| scene.create_entity())
        .raw_value()
}

fn selection(ids: &[u64]) -> BTreeSet<u64> {
    ids.iter().copied().collect()
}

/// Adding a component reports presence and updates the addable set.
#[test]
fn add_component() {
    let adapter = adapter();
    let id = make_entity(&adapter);

    assert!(!adapter.has_component("particleEmitter", id));
    assert!(
        adapter
            .addable_component_schemas(id)
            .iter()
            .any(|schema| schema.type_id == "particleEmitter")
    );

    assert!(adapter.add_component("particleEmitter", id));
    assert!(adapter.has_component("particleEmitter", id));
    assert!(
        adapter
            .component_type_ids(id)
            .iter()
            .any(|type_id| type_id == "particleEmitter")
    );
    assert!(
        !adapter
            .addable_component_schemas(id)
            .iter()
            .any(|schema| schema.type_id == "particleEmitter")
    );
}

/// Adding an animation graph creates a default graph player.
#[test]
fn add_animation_graph_player() {
    let adapter = adapter();
    let id = make_entity(&adapter);
    let entity = EntityID::from_raw_value(id);

    assert!(adapter.add_component("animationGraphPlayer", id));
    let player = adapter
        .scene()
        .component::<AnimationGraphPlayer>(entity)
        .expect("graph player");
    assert_eq!(player.graph.state_machine.initial_state, "Default");
    assert_eq!(player.graph.state_machine.states.len(), 1);
    assert!(
        adapter
            .component_type_ids(id)
            .iter()
            .any(|type_id| type_id == "animationGraphPlayer")
    );

    assert!(adapter.remove_component("animationGraphPlayer", id));
    assert!(
        adapter
            .scene()
            .component::<AnimationGraphPlayer>(entity)
            .is_none()
    );
}

/// Adding an existing component does not overwrite and returns false.
#[test]
fn add_existing_is_no_op() {
    let adapter = adapter();
    let id = make_entity(&adapter);

    assert!(adapter.add_component("light", id));
    adapter.with_scene_mut(|scene| {
        scene.update_component::<LightComponent>(EntityID::from_raw_value(id), |light| {
            light.intensity = 42.0;
        });
    });
    assert!(!adapter.add_component("light", id));
    assert_eq!(
        adapter
            .scene()
            .component::<LightComponent>(EntityID::from_raw_value(id))
            .map(|light| light.intensity),
        Some(42.0)
    );
}

/// Removing a component clears it.
#[test]
fn remove_component() {
    let adapter = adapter();
    let id = make_entity(&adapter);
    let _ = adapter.add_component("audioSource", id);

    assert!(adapter.remove_component("audioSource", id));
    assert!(!adapter.has_component("audioSource", id));
    assert!(!adapter.remove_component("audioSource", id));
}

/// Add and remove bump the scene revision.
#[test]
fn mutations_bump_revision() {
    let adapter = adapter();
    let id = make_entity(&adapter);
    let revisions: Rc<std::cell::RefCell<Vec<u64>>> = Rc::new(std::cell::RefCell::new(Vec::new()));
    {
        let revisions = revisions.clone();
        adapter
            .on_revision_changed
            .replace(Some(Rc::new(move |revision| {
                revisions.borrow_mut().push(revision);
            })));
    }

    let _ = adapter.add_component("camera", id);
    let _ = adapter.remove_component("camera", id);
    assert_eq!(revisions.borrow().len(), 2);
}

/// Operations on an unknown entity fail safely.
#[test]
fn unknown_entity() {
    let adapter = adapter();
    let bogus: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    assert!(!adapter.add_component("light", bogus));
    assert!(!adapter.remove_component("light", bogus));
    assert!(!adapter.has_component("light", bogus));
    assert!(adapter.component_type_ids(bogus).is_empty());
}

/// Multi-selection component add is atomic and one undo step.
#[test]
fn multi_selection_add_is_atomic_and_undoable() {
    let adapter = adapter();
    let first = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("first");
    let second = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("second");
    let selection = selection(&[first, second]);

    assert!(
        adapter
            .addable_component_schemas_on_selection(&selection)
            .iter()
            .any(|schema| schema.type_id == "audioSource")
    );
    assert!(adapter.add_component_to_selection("audioSource", &selection));
    assert!(
        selection
            .iter()
            .all(|id| adapter.has_component("audioSource", *id))
    );

    assert!(adapter.undo_edit());
    assert!(
        selection
            .iter()
            .all(|id| !adapter.has_component("audioSource", *id))
    );
    assert!(adapter.redo_edit());
    assert!(
        selection
            .iter()
            .all(|id| adapter.has_component("audioSource", *id))
    );
}

/// Multi-selection add fills missing members without resetting existing data.
#[test]
fn multi_selection_add_fills_missing_members() {
    let adapter = adapter();
    let first = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("first");
    let second = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("second");
    assert!(adapter.add_component("light", first));
    let first_entity = EntityID::from_raw_value(first);
    adapter.with_scene_mut(|scene| {
        scene.update_component::<LightComponent>(first_entity, |light| {
            light.intensity = 42.0;
        });
    });
    adapter.notify_revision_changed_default();
    let selection = selection(&[first, second]);

    assert!(
        adapter
            .addable_component_schemas_on_selection(&selection)
            .iter()
            .any(|schema| schema.type_id == "light")
    );
    assert!(adapter.add_component_to_selection("light", &selection));
    assert_eq!(
        adapter
            .scene()
            .component::<LightComponent>(first_entity)
            .map(|light| light.intensity),
        Some(42.0)
    );
    assert!(adapter.has_component("light", second));

    assert!(adapter.undo_edit());
    assert_eq!(
        adapter
            .scene()
            .component::<LightComponent>(first_entity)
            .map(|light| light.intensity),
        Some(42.0)
    );
    assert!(!adapter.has_component("light", second));
}

/// Multi-selection add rejects a locked member without partial mutation.
#[test]
fn multi_selection_add_rejects_locked_member() {
    let adapter = adapter();
    let first = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("first");
    let second = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("second");
    let selection = selection(&[first, second]);
    adapter.set_entity_locked(true, &BTreeSet::from([second]));
    let revision_count = Rc::new(std::cell::Cell::new(0));
    {
        let revision_count = revision_count.clone();
        adapter.on_revision_changed.replace(Some(Rc::new(move |_| {
            revision_count.set(revision_count.get() + 1);
        })));
    }

    assert!(!adapter.add_component_to_selection("light", &selection));
    assert!(
        selection
            .iter()
            .all(|id| !adapter.has_component("light", *id))
    );
    assert_eq!(revision_count.get(), 0);
}

/// Multi-selection remove and reset are atomic undoable operations.
#[test]
fn multi_selection_remove_and_reset_are_undoable() {
    let adapter = adapter();
    let first = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("first");
    let second = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("second");
    let selection = selection(&[first, second]);
    assert!(adapter.add_component_to_selection("light", &selection));

    for raw_id in &selection {
        adapter.with_scene_mut(|scene| {
            scene.update_component::<LightComponent>(EntityID::from_raw_value(*raw_id), |light| {
                light.intensity = 42.0;
            });
        });
    }
    adapter.notify_revision_changed_default();

    assert!(adapter.reset_component("light", &selection));
    assert!(selection.iter().all(|raw_id| {
        adapter
            .scene()
            .component::<LightComponent>(EntityID::from_raw_value(*raw_id))
            .map(|light| light.intensity)
            == Some(LightComponent::default().intensity)
    }));
    assert!(adapter.undo_edit());
    assert!(selection.iter().all(|raw_id| {
        adapter
            .scene()
            .component::<LightComponent>(EntityID::from_raw_value(*raw_id))
            .map(|light| light.intensity)
            == Some(42.0)
    }));

    assert!(adapter.remove_component_from_selection("light", &selection));
    assert!(
        selection
            .iter()
            .all(|id| !adapter.has_component("light", *id))
    );
    assert!(adapter.undo_edit());
    assert!(
        selection
            .iter()
            .all(|id| adapter.has_component("light", *id))
    );
}
