//! Ported from `Editor/Tests/EditorCoreTests/EditorRegistryInspectorTests.swift`.

use std::collections::BTreeSet;

use diffuse_scene::components::core::registry::{
    ComponentCategory, ComponentDecodeContext, ComponentEncodeContext, ComponentRegistry,
    ComponentSchema,
};
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::components::inspection::inspection::{
    ComponentFieldChoice, ComponentFieldDescriptor, ComponentFieldKind,
};
use diffuse_scene::entity_id::{EntityID, RuntimeComponent};
use diffuse_scene::runtime_world::RuntimeWorld;
use serde::{Deserialize, Serialize};

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::{
    EditorInspectorField, EditorInspectorFieldValue, EditorInspectorSection,
};
use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct ProbeSettings {
    gain: f32,
    enabled: bool,
    mode: String,
}

impl Default for ProbeSettings {
    fn default() -> Self {
        ProbeSettings {
            gain: 1.0,
            enabled: true,
            mode: "normal".to_string(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct InspectorProbe {
    settings: ProbeSettings,
    offset: Vec<f32>,
    seed: u64,
    items: Vec<i64>,
    source: String,
}

impl Default for InspectorProbe {
    fn default() -> Self {
        InspectorProbe {
            settings: ProbeSettings::default(),
            offset: vec![1.0, 2.0, 3.0],
            seed: u64::MAX,
            items: Vec::new(),
            source: "module".to_string(),
        }
    }
}

impl RuntimeComponent for InspectorProbe {}

fn encode_probe(
    world: &RuntimeWorld,
    entity: EntityID,
    _context: &mut ComponentEncodeContext,
) -> Option<ComponentValue> {
    let component = world.component::<InspectorProbe>(entity)?;
    let json = serde_json::to_value(component).ok()?;
    Some(ComponentValue::from_json_value(&json))
}

fn decode_probe(
    value: &ComponentValue,
    entity: EntityID,
    _context: &mut ComponentDecodeContext,
    world: &mut RuntimeWorld,
) {
    let Ok(component) = serde_json::from_value::<InspectorProbe>(value.to_json_value()) else {
        return;
    };
    world.set_component(component, entity);
}

fn probe_schema() -> ComponentSchema {
    let mut schema = ComponentSchema::for_component::<InspectorProbe>(
        "test.probe",
        "Probe",
        ComponentCategory::Gameplay,
        encode_probe,
        decode_probe,
        |entity, world| {
            world.set_component(InspectorProbe::default(), entity);
        },
    );
    let mut gain = ComponentFieldDescriptor::new(vec!["settings".to_string(), "gain".to_string()]);
    gain.numeric.minimum = Some(0.0);
    gain.numeric.maximum = Some(5.0);
    let mut mode = ComponentFieldDescriptor::new(vec!["settings".to_string(), "mode".to_string()]);
    mode.kind = ComponentFieldKind::Options;
    mode.choices = vec![
        ComponentFieldChoice::new("normal"),
        ComponentFieldChoice::new("fast"),
    ];
    let mut source = ComponentFieldDescriptor::new(vec!["source".to_string()]);
    source.is_read_only = true;
    schema.inspection.fields = vec![gain, mode, source];
    schema
}

fn adapter(renderers: EditorInspectorRendererRegistry) -> EditorSceneAdapter {
    let mut registry = ComponentRegistry::built_in();
    registry.register(probe_schema());
    EditorSceneAdapter::new(false, registry, renderers)
}

fn field(
    adapter: &EditorSceneAdapter,
    ids: &BTreeSet<u64>,
    section: &str,
    field_id: &str,
) -> EditorInspectorField {
    adapter
        .inspector_sections_for_selection(ids, None)
        .into_iter()
        .find(|candidate| candidate.id == section)
        .and_then(|section| {
            section
                .fields
                .into_iter()
                .find(|candidate| candidate.id == field_id)
        })
        .unwrap_or_else(|| panic!("missing {section}/{field_id}"))
}

/// A contributed schema gets a form, nested transactions and exact integer
/// editing without UI registration.
#[test]
fn contributed_form() {
    let adapter = adapter(EditorInspectorRendererRegistry::new());
    let entity = adapter.with_scene_mut(|scene| scene.create_entity());
    assert!(adapter.add_component("test.probe", entity.raw_value()));
    adapter.reset_edit_history();
    let descriptions = adapter.component_descriptions(Some("test.probe"));
    assert!(descriptions.first().is_some_and(|description| {
        description
            .fields
            .iter()
            .any(|field| field.id == "settings.gain")
    }));
    let ids = BTreeSet::from([entity.raw_value()]);
    let gain_field = field(&adapter, &ids, "test.probe", "settings.gain");
    let EditorInspectorFieldValue::ConstrainedNumber {
        binding: gain,
        min,
        max,
        ..
    } = gain_field.value
    else {
        panic!("expected constrained number");
    };
    assert_eq!(min, Some(0.0));
    assert_eq!(max, Some(5.0));
    let seed_field = field(&adapter, &ids, "test.probe", "seed");
    let EditorInspectorFieldValue::Text(seed) = seed_field.value else {
        panic!("expected text");
    };
    assert_eq!(seed.get(), u64::MAX.to_string());

    gain.set(12.0);
    let component = adapter
        .scene()
        .component::<InspectorProbe>(entity)
        .expect("probe");
    assert_eq!(component.settings.gain, 5.0);
    assert!(component.settings.enabled);
    assert_eq!(component.seed, u64::MAX);

    assert!(adapter.undo_edit());
    assert_eq!(gain.get(), 1.0);
    assert!(adapter.redo_edit());
    seed.set("18446744073709551614".to_string());
    assert_eq!(
        adapter
            .scene()
            .component::<InspectorProbe>(entity)
            .map(|component| component.seed),
        Some(u64::MAX - 1)
    );
    assert!(adapter.undo_edit());
    assert_eq!(seed.get(), u64::MAX.to_string());
}

/// Inferred vector axes preserve each selection's remaining coordinates and
/// undo as one edit.
#[test]
fn multi_selection_vector() {
    let adapter = adapter(EditorInspectorRendererRegistry::new());
    let (a, b) = adapter.with_scene_mut(|scene| (scene.create_entity(), scene.create_entity()));
    assert!(adapter.add_component_to_selection(
        "test.probe",
        &BTreeSet::from([a.raw_value(), b.raw_value()])
    ));
    adapter.with_scene_mut(|scene| {
        scene.update_component::<InspectorProbe>(b, |probe| {
            probe.offset = vec![4.0, 8.0, 16.0];
        });
    });
    adapter.reset_edit_history();
    let ids = BTreeSet::from([a.raw_value(), b.raw_value()]);
    let offset = field(&adapter, &ids, "test.probe", "offset");
    assert_eq!(
        adapter
            .inspector_sections_for_selection(&ids, None)
            .into_iter()
            .find(|section| section.id == "test.probe")
            .and_then(|section| section.component_type_id),
        Some("test.probe".to_string())
    );
    assert!(offset.is_mixed);
    assert_eq!(
        offset.mixed_axes,
        BTreeSet::from(["x".to_string(), "y".to_string(), "z".to_string()])
    );
    let EditorInspectorFieldValue::Vector3 { x, .. } = offset.value else {
        panic!("expected vector");
    };
    x.set(25.0);
    assert_eq!(
        adapter
            .scene()
            .component::<InspectorProbe>(a)
            .map(|probe| probe.offset),
        Some(vec![25.0, 2.0, 3.0])
    );
    assert_eq!(
        adapter
            .scene()
            .component::<InspectorProbe>(b)
            .map(|probe| probe.offset),
        Some(vec![25.0, 8.0, 16.0])
    );
    assert!(adapter.undo_edit());
    assert_eq!(
        adapter
            .scene()
            .component::<InspectorProbe>(a)
            .map(|probe| probe.offset),
        Some(vec![1.0, 2.0, 3.0])
    );
    assert_eq!(
        adapter
            .scene()
            .component::<InspectorProbe>(b)
            .map(|probe| probe.offset),
        Some(vec![4.0, 8.0, 16.0])
    );
    assert!(!adapter.can_undo_edit());
}

/// Stale and locked generic bindings reject whole selections.
#[test]
fn stale_and_locked_bindings() {
    let adapter = adapter(EditorInspectorRendererRegistry::new());
    let (a, b) = adapter.with_scene_mut(|scene| (scene.create_entity(), scene.create_entity()));
    assert!(adapter.add_component_to_selection(
        "test.probe",
        &BTreeSet::from([a.raw_value(), b.raw_value()])
    ));
    let ids = BTreeSet::from([a.raw_value(), b.raw_value()]);
    let enabled_field = field(&adapter, &ids, "test.probe", "settings.enabled");
    let EditorInspectorFieldValue::Bool(enabled) = enabled_field.value else {
        panic!("expected bool");
    };
    adapter.set_entity_locked(true, &BTreeSet::from([b.raw_value()]));
    let revision = adapter.revision();
    enabled.set(false);
    assert_eq!(adapter.revision(), revision);
    assert_eq!(
        adapter
            .scene()
            .component::<InspectorProbe>(a)
            .map(|probe| probe.settings.enabled),
        Some(true)
    );
    adapter.set_entity_locked(false, &BTreeSet::from([b.raw_value()]));
    assert!(adapter.remove_component("test.probe", b.raw_value()));
    let removed_revision = adapter.revision();
    enabled.set(false);
    assert_eq!(adapter.revision(), removed_revision);
    assert_eq!(
        adapter
            .scene()
            .component::<InspectorProbe>(a)
            .map(|probe| probe.settings.enabled),
        Some(true)
    );
}

/// Options, invalid JSON, read-only fields and interactive cancellation retain
/// authored values.
#[test]
fn validation_and_cancellation() {
    let adapter = adapter(EditorInspectorRendererRegistry::new());
    let entity = adapter.with_scene_mut(|scene| scene.create_entity());
    assert!(adapter.add_component("test.probe", entity.raw_value()));
    adapter.reset_edit_history();
    let ids = BTreeSet::from([entity.raw_value()]);
    let mode_field = field(&adapter, &ids, "test.probe", "settings.mode");
    let EditorInspectorFieldValue::StringOptions { binding: mode, .. } = mode_field.value else {
        panic!("expected options");
    };
    let items_field = field(&adapter, &ids, "test.probe", "items");
    let EditorInspectorFieldValue::Json { binding: items, .. } = items_field.value else {
        panic!("expected json");
    };
    assert!(matches!(
        field(&adapter, &ids, "test.probe", "source").value,
        EditorInspectorFieldValue::ReadOnly(_)
    ));
    mode.set("unsupported".to_string());
    items.set("{invalid".to_string());
    items.set("[false]".to_string());
    assert!(!adapter.can_undo_edit());
    assert_eq!(
        adapter.scene().component::<InspectorProbe>(entity),
        Some(InspectorProbe::default())
    );
    adapter.begin_interactive_edit_history_group();
    mode.set("fast".to_string());
    items.set("[2, 4]".to_string());
    adapter.cancel_interactive_edit_history_group();
    assert_eq!(
        adapter.scene().component::<InspectorProbe>(entity),
        Some(InspectorProbe::default())
    );
    assert!(!adapter.can_undo_edit());
}

/// A module renderer joins multi-selection and undo using the schema's
/// component identity.
#[test]
fn contributed_renderer() {
    use std::rc::Rc;

    let mut renderers = EditorInspectorRendererRegistry::new();
    renderers
        .register_standard(
            "test.probe",
            Rc::new(|adapter: &EditorSceneAdapter, entity: EntityID| {
                let form = adapter.registry_inspector_section(&probe_schema(), entity)?;
                let mut section =
                    EditorInspectorSection::new("module-form", "Module Form", form.fields);
                section.component_type_id = Some("incorrect-renderer-identity".to_string());
                Some(section)
            }),
        )
        .expect("register renderer");
    let adapter = adapter(renderers);
    let (a, b) = adapter.with_scene_mut(|scene| (scene.create_entity(), scene.create_entity()));
    assert!(
        !adapter
            .inspector_sections(Some(a.raw_value()))
            .iter()
            .any(|section| section.id == "module-form")
    );
    assert!(adapter.add_component_to_selection(
        "test.probe",
        &BTreeSet::from([a.raw_value(), b.raw_value()])
    ));
    adapter.with_scene_mut(|scene| {
        scene.update_component::<InspectorProbe>(b, |probe| {
            probe.settings.gain = 2.0;
        });
    });
    adapter.reset_edit_history();
    let before = adapter.manifest();
    let ids = BTreeSet::from([a.raw_value(), b.raw_value()]);
    let section = adapter
        .inspector_sections_for_selection(&ids, None)
        .into_iter()
        .find(|section| section.id == "module-form")
        .expect("module form");
    assert_eq!(section.component_type_id.as_deref(), Some("test.probe"));
    let after = adapter.manifest();
    assert_eq!(after.roots, before.roots);
    assert_eq!(after.revision, before.revision);
    let gain_field = section
        .fields
        .into_iter()
        .find(|field| field.id == "settings.gain")
        .expect("gain field");
    assert!(gain_field.is_mixed);
    let EditorInspectorFieldValue::ConstrainedNumber { binding: gain, .. } = gain_field.value
    else {
        panic!("expected module-rendered binding");
    };
    gain.set(4.0);
    assert_eq!(
        adapter
            .scene()
            .component::<InspectorProbe>(a)
            .map(|probe| probe.settings.gain),
        Some(4.0)
    );
    assert_eq!(
        adapter
            .scene()
            .component::<InspectorProbe>(b)
            .map(|probe| probe.settings.gain),
        Some(4.0)
    );
    assert!(adapter.undo_edit());
    assert_eq!(
        adapter
            .scene()
            .component::<InspectorProbe>(a)
            .map(|probe| probe.settings.gain),
        Some(1.0)
    );
    assert_eq!(
        adapter
            .scene()
            .component::<InspectorProbe>(b)
            .map(|probe| probe.settings.gain),
        Some(2.0)
    );
    assert!(!adapter.can_undo_edit());
    assert!(adapter.redo_edit());
    assert_eq!(
        adapter
            .scene()
            .component::<InspectorProbe>(b)
            .map(|probe| probe.settings.gain),
        Some(4.0)
    );
}
