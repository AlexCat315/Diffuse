//! Ported from `Editor/Tests/EditorCoreTests/Inspector/PhysicsForms.swift`.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::physics::rigid_body::{
    RigidBody, RigidBodyMotionQuality, RigidBodyMotionType, RigidBodyOptions,
};
use diffuse_scene::physics::soft_bodies::cloth::{Cloth, ClothBendType};
use diffuse_scene::physics::soft_bodies::soft_body::{
    SoftBody, SoftBodyMeshState, SoftBodyStateFrameResource,
};

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::{EditorInspectorFieldValue, EditorInspectorSection};
use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

fn adapter() -> EditorSceneAdapter {
    EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::built_in(),
    )
}

fn entity(adapter: &EditorSceneAdapter) -> u64 {
    adapter
        .with_scene_mut(|scene| scene.create_entity())
        .raw_value()
}

fn section(adapter: &EditorSceneAdapter, id: u64, component: &str) -> EditorInspectorSection {
    adapter
        .inspector_sections(Some(id))
        .into_iter()
        .find(|candidate| candidate.component_type_id.as_deref() == Some(component))
        .expect("generated form")
}

fn field(section: &EditorInspectorSection, id: &str) -> EditorInspectorFieldValue {
    section
        .fields
        .iter()
        .find(|candidate| candidate.id == id)
        .expect("generated field")
        .value
        .clone()
}

/// Rigid-body generated controls preserve state, coalesce and undo the CCD
/// companion value.
#[test]
fn rigid_body_form() {
    let adapter = adapter();
    let id = entity(&adapter);
    let entity = EntityID::from_raw_value(id);
    let original = RigidBody::new(RigidBodyOptions {
        linear_velocity: Float3::new(1.0, 2.0, 3.0),
        accumulated_force: Float3::new(4.0, 5.0, 6.0),
        is_sleeping: true,
        ..RigidBodyOptions::default()
    });
    adapter.with_scene_mut(|scene| scene.set_component(original.clone(), entity));
    adapter.reset_edit_history();

    assert!(
        adapter
            .inspector_renderers
            .borrow()
            .renderer("rigidbody")
            .is_none()
    );
    let form = section(&adapter, id, "rigidbody");
    let EditorInspectorFieldValue::StringOptions {
        binding: motion,
        options,
    } = field(&form, "motion")
    else {
        panic!("expected motion choices");
    };
    let EditorInspectorFieldValue::Vector3 { x, y: _, z: _ } = field(&form, "linear-velocity")
    else {
        panic!("expected velocity");
    };
    let EditorInspectorFieldValue::ConstrainedNumber { binding: mass, .. } = field(&form, "mass")
    else {
        panic!("expected mass");
    };
    let EditorInspectorFieldValue::Bool(ccd) = field(&form, "continuous-collision-detection")
    else {
        panic!("expected ccd");
    };
    assert!(matches!(
        field(&form, "sleeping"),
        EditorInspectorFieldValue::ReadOnly(_)
    ));
    assert!(matches!(
        field(&form, "accumulatedForce"),
        EditorInspectorFieldValue::ReadOnly(_)
    ));
    assert_eq!(
        options
            .iter()
            .map(|option| option.value.clone())
            .collect::<Vec<_>>(),
        RigidBodyMotionType::ALL
            .iter()
            .map(|kind| kind.raw_value().to_string())
            .collect::<Vec<_>>()
    );

    let revision = adapter.revision();
    motion.set("unsupported".to_string());
    mass.set(f32::INFINITY);
    assert_eq!(adapter.revision(), revision);

    adapter.begin_interactive_edit_history_group();
    motion.set("kinematic".to_string());
    mass.set(-1.0);
    x.set(8.0);
    ccd.set(true);
    adapter.end_interactive_edit_history_group();

    let mut expected = original.clone();
    expected.motion_type = RigidBodyMotionType::Kinematic;
    expected.mass = 0.0;
    expected.linear_velocity.x = 8.0;
    expected.continuous_collision_detection = true;
    expected.motion_quality = RigidBodyMotionQuality::LinearCast;
    assert_eq!(
        adapter.scene().component::<RigidBody>(entity),
        Some(expected)
    );

    assert!(adapter.undo_edit());
    assert_eq!(
        adapter.scene().component::<RigidBody>(entity),
        Some(original)
    );
    assert!(!adapter.can_undo_edit());
    assert!(adapter.redo_edit());
    ccd.set(false);
    assert_eq!(
        adapter
            .scene()
            .component::<RigidBody>(entity)
            .expect("rigid body")
            .motion_quality,
        RigidBodyMotionQuality::Discrete
    );
    assert!(adapter.undo_edit());
    assert_eq!(
        adapter
            .scene()
            .component::<RigidBody>(entity)
            .expect("rigid body")
            .motion_quality,
        RigidBodyMotionQuality::LinearCast
    );
}

/// Bounded integer controls round and clamp; soft-body diagnostics remain
/// outside persistence.
#[test]
fn soft_body_form() {
    let adapter = adapter();
    let id = entity(&adapter);
    let entity = EntityID::from_raw_value(id);
    adapter.with_scene_mut(|scene| {
        let _ = scene.set_component(SoftBody::default(), entity);
        scene.set_resource(SoftBodyStateFrameResource::new(BTreeMap::from([(
            entity,
            SoftBodyMeshState::with_state(
                entity,
                vec![Float3::ZERO, Float3::new(1.0, 2.0, 3.0)],
                Vec::new(),
                true,
            ),
        )])));
    });
    adapter.reset_edit_history();

    let form = section(&adapter, id, "softBody");
    let EditorInspectorFieldValue::ConstrainedNumber {
        binding: iterations,
        ..
    } = field(&form, "soft-body-iterations")
    else {
        panic!("expected iterations");
    };
    let EditorInspectorFieldValue::ConstrainedNumber { binding: layer, .. } =
        field(&form, "soft-body-layer")
    else {
        panic!("expected layer");
    };
    let EditorInspectorFieldValue::ConstrainedNumber { binding: mask, .. } =
        field(&form, "soft-body-layer-mask")
    else {
        panic!("expected layer mask");
    };
    let EditorInspectorFieldValue::ReadOnly(vertices) = field(&form, "soft-body-streamed-vertices")
    else {
        panic!("expected streamed vertices");
    };
    assert_eq!(vertices, "2");
    assert!(
        adapter
            .scene()
            .component_data("softBody", entity)
            .and_then(|value| value.value_at(&["positions".to_string()]).cloned())
            .is_none()
    );

    iterations.set(11.6);
    assert_eq!(
        adapter
            .scene()
            .component::<SoftBody>(entity)
            .expect("soft body")
            .solver_iterations,
        12
    );
    iterations.set(f32::MAX);
    layer.set(200.0);
    mask.set(100_000.0);
    let body = adapter
        .scene()
        .component::<SoftBody>(entity)
        .expect("soft body");
    assert_eq!(body.solver_iterations, 128);
    assert_eq!(body.layer_id, 15);
    assert_eq!(body.layer_mask, u16::MAX);

    let revision = adapter.revision();
    iterations.set(f32::NAN);
    layer.set(f32::NEG_INFINITY);
    assert_eq!(adapter.revision(), revision);
    assert_eq!(
        adapter.scene().soft_body_state_frame().states[&entity]
            .positions
            .len(),
        2
    );

    assert!(
        adapter
            .inspector_renderers
            .borrow_mut()
            .remove("softBody")
            .is_some()
    );
    let fallback = section(&adapter, id, "softBody");
    assert!(
        fallback
            .fields
            .iter()
            .any(|field| field.id == "soft-body-iterations")
    );
    assert!(
        !fallback
            .fields
            .iter()
            .any(|field| field.id == "soft-body-streamed-vertices")
    );
}

/// Cloth forms use numeric enum values, normalize JSON and undo topology
/// pruning for every selection.
#[test]
fn cloth_forms() {
    let adapter = adapter();
    let a = entity(&adapter);
    let b = entity(&adapter);
    let a_entity = EntityID::from_raw_value(a);
    let b_entity = EntityID::from_raw_value(b);
    let original = Cloth::new(
        3,
        2,
        0.2,
        vec![0, 5],
        1.0e-5,
        1.0e-5,
        1.0e-5,
        ClothBendType::Distance,
    );
    adapter.with_scene_mut(|scene| {
        let _ = scene.set_component(original.clone(), a_entity);
        let _ = scene.set_component(original.clone(), b_entity);
    });
    adapter.reset_edit_history();

    let selection = BTreeSet::from([a, b]);
    let form = adapter
        .inspector_sections_for_selection(&selection, None)
        .into_iter()
        .find(|candidate| candidate.component_type_id.as_deref() == Some("cloth"))
        .expect("cloth form");
    let EditorInspectorFieldValue::ConstrainedNumber { binding: grid, .. } =
        field(&form, "cloth-grid-x")
    else {
        panic!("expected grid");
    };
    let EditorInspectorFieldValue::StringOptions {
        binding: bend,
        options,
    } = field(&form, "cloth-bend-type")
    else {
        panic!("expected bend choices");
    };
    let EditorInspectorFieldValue::Json {
        binding: indices, ..
    } = field(&form, "cloth-fixed-vertices")
    else {
        panic!("expected fixed vertices");
    };
    assert_eq!(
        options
            .iter()
            .map(|option| option.value.clone())
            .collect::<Vec<_>>(),
        ["none", "distance", "dihedral"]
    );

    grid.set(2.2);
    assert_eq!(
        adapter
            .scene()
            .component::<Cloth>(a_entity)
            .expect("cloth a")
            .fixed_vertex_indices,
        [0]
    );
    assert_eq!(
        adapter
            .scene()
            .component::<Cloth>(b_entity)
            .expect("cloth b")
            .grid_size_x,
        2
    );
    assert!(adapter.undo_edit());
    assert_eq!(
        adapter.scene().component::<Cloth>(a_entity),
        Some(original.clone())
    );
    assert_eq!(
        adapter.scene().component::<Cloth>(b_entity),
        Some(original.clone())
    );
    assert!(!adapter.can_undo_edit());

    bend.set("dihedral".to_string());
    assert_eq!(
        adapter
            .scene()
            .component_data("cloth", a_entity)
            .and_then(|value| value.value_at(&["bendType".to_string()]).cloned()),
        Some(ComponentValue::Number(2.0))
    );
    indices.set("[5,2,-1,5,999]".to_string());
    assert_eq!(
        adapter
            .scene()
            .component::<Cloth>(a_entity)
            .expect("cloth a")
            .fixed_vertex_indices,
        [2, 5]
    );
    let revision = adapter.revision();
    indices.set("[true]".to_string());
    assert_eq!(adapter.revision(), revision);
    assert_eq!(
        adapter
            .scene()
            .component::<Cloth>(b_entity)
            .expect("cloth b")
            .fixed_vertex_indices,
        [2, 5]
    );
    let EditorInspectorFieldValue::ReadOnly(vertices) =
        field(&section(&adapter, a, "cloth"), "cloth-vertex-count")
    else {
        panic!("expected cloth vertex count");
    };
    assert_eq!(vertices, "6");
}
