//! Ported from `Engine/Tests/SceneRuntimeTests/Physics/ComponentEditingTests.swift`.
//!
//! Coverage for the registry-backed partial edits that the physics components
//! expose: CCD quality inheritance, cloth vertex-index normalization and the
//! soft-body mesh document rules sent by the editor.

use crate::components::core::registry::ComponentRegistry;
use crate::components::core::value::ComponentValue;
use crate::components::editing::{ComponentEditError, ComponentWriteMode};
use crate::entity_id::EntityID;
use crate::physics::rigid_body::{RigidBody, RigidBodyMotionQuality};
use crate::physics::soft_bodies::cloth::{Cloth, ClothBendType};
use crate::physics::soft_bodies::soft_body::SoftBodyMesh;
use crate::scene_runtime::SceneRuntime;
use crate::serialization::scene_serializer::SceneSerializer;

fn object<const N: usize>(entries: [(&str, ComponentValue); N]) -> ComponentValue {
    ComponentValue::Object(
        entries
            .into_iter()
            .map(|(key, value)| (key.to_string(), value))
            .collect::<std::collections::BTreeMap<_, _>>(),
    )
}

/// Swift `.array([0, 5, 2].map { .number(Double($0)) })`.
fn integer_array<const N: usize>(values: [i64; N]) -> ComponentValue {
    ComponentValue::Array(
        values
            .into_iter()
            .map(|value| ComponentValue::Number(value as f64))
            .collect(),
    )
}

/// `#expect(throws: ComponentEditError.invalidValue(typeID))`.
fn expect_invalid_value(
    scene: &mut SceneRuntime,
    value: &ComponentValue,
    type_id: &str,
    entity: EntityID,
    mode: ComponentWriteMode,
) {
    let error = scene
        .set_component_data(value, type_id, entity, mode)
        .expect_err("the edit must be rejected");
    assert_eq!(
        error.edit_error().cloned(),
        Some(ComponentEditError::InvalidValue(type_id.to_string()))
    );
}

#[test]
fn ccd_quality() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(RigidBody::default(), entity);

    scene
        .set_component_data(
            &object([("continuousCollisionDetection", ComponentValue::Bool(true))]),
            "rigidbody",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("merge ccd on");
    assert_eq!(
        scene
            .component::<RigidBody>(entity)
            .map(|body| body.motion_quality),
        Some(RigidBodyMotionQuality::LinearCast)
    );

    scene
        .set_component_data(
            &object([("continuousCollisionDetection", ComponentValue::Bool(false))]),
            "rigidbody",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("merge ccd off");
    assert_eq!(
        scene
            .component::<RigidBody>(entity)
            .map(|body| body.motion_quality),
        Some(RigidBodyMotionQuality::Discrete)
    );

    scene
        .set_component_data(
            &object([(
                "motionQuality",
                ComponentValue::String("linearCast".to_string()),
            )]),
            "rigidbody",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("merge explicit motion quality");

    // An unrelated edit must not reset the explicitly authored quality.
    scene
        .set_component_data(
            &object([
                ("continuousCollisionDetection", ComponentValue::Bool(false)),
                ("mass", ComponentValue::Number(3.0)),
            ]),
            "rigidbody",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("merge unrelated field");
    assert_eq!(
        scene
            .component::<RigidBody>(entity)
            .map(|body| body.motion_quality),
        Some(RigidBodyMotionQuality::LinearCast)
    );

    scene
        .set_component_data(
            &object([("continuousCollisionDetection", ComponentValue::Bool(true))]),
            "rigidbody",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("merge ccd on again");
    // A false CCD toggle in the same document does not clear the explicit quality.
    scene
        .set_component_data(
            &object([
                ("continuousCollisionDetection", ComponentValue::Bool(false)),
                (
                    "motionQuality",
                    ComponentValue::String("linearCast".to_string()),
                ),
            ]),
            "rigidbody",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("merge ccd off with explicit quality");
    assert_eq!(
        scene
            .component::<RigidBody>(entity)
            .map(|body| body.motion_quality),
        Some(RigidBodyMotionQuality::LinearCast)
    );
}

#[test]
fn cloth_indices() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        Cloth::new(
            3,
            2,
            0.2,
            Vec::new(),
            1.0e-5,
            1.0e-5,
            1.0e-5,
            ClothBendType::Distance,
        ),
        entity,
    );

    scene
        .set_component_data(
            &object([("fixedVertexIndices", integer_array([0, 5, 2, -1, 5, 999]))]),
            "cloth",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("merge fixed vertex indices");
    assert_eq!(
        scene
            .component::<Cloth>(entity)
            .map(|cloth| cloth.fixed_vertex_indices),
        Some(vec![0, 2, 5])
    );

    scene
        .set_component_data(
            &object([(
                "fixedVertexIndices",
                object([("1", ComponentValue::Number(1.0))]),
            )]),
            "cloth",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("patch one index");
    assert_eq!(
        scene
            .component::<Cloth>(entity)
            .map(|cloth| cloth.fixed_vertex_indices),
        Some(vec![0, 1, 5])
    );

    // Shrinking the grid drops indices the new topology no longer has.
    scene
        .set_component_data(
            &object([("gridSizeX", ComponentValue::Number(2.0))]),
            "cloth",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("shrink grid");
    assert_eq!(
        scene
            .component::<Cloth>(entity)
            .map(|cloth| cloth.fixed_vertex_indices),
        Some(vec![0, 1])
    );

    let before = SceneSerializer::serialize(scene.world()).expect("serialize");

    // A boolean inside the index array is rejected and leaves the scene untouched.
    expect_invalid_value(
        &mut scene,
        &object([
            ("spacing", ComponentValue::Number(2.0)),
            (
                "fixedVertexIndices",
                ComponentValue::Array(vec![ComponentValue::Bool(true)]),
            ),
        ]),
        "cloth",
        entity,
        ComponentWriteMode::Merge,
    );
    assert_eq!(
        SceneSerializer::serialize(scene.world()).expect("serialize"),
        before
    );

    // Fractional indices are rejected as well.
    expect_invalid_value(
        &mut scene,
        &object([(
            "fixedVertexIndices",
            ComponentValue::Array(vec![ComponentValue::Number(1.5)]),
        )]),
        "cloth",
        entity,
        ComponentWriteMode::Merge,
    );
    assert_eq!(
        SceneSerializer::serialize(scene.world()).expect("serialize"),
        before
    );
}

#[test]
fn mesh_input() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(SoftBodyMesh::default(), entity);

    scene
        .set_component_data(
            &object([
                (
                    "resourceID",
                    ComponentValue::String("  mesh.tetra\n".to_string()),
                ),
                ("fixedVertexIndices", integer_array([7, 2, -1, 2])),
            ]),
            "softBodyMesh",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("merge mesh input");
    assert_eq!(
        scene
            .component::<SoftBodyMesh>(entity)
            .and_then(|mesh| mesh.resource_id),
        Some("mesh.tetra".to_string())
    );
    assert_eq!(
        scene
            .component::<SoftBodyMesh>(entity)
            .map(|mesh| mesh.fixed_vertex_indices),
        Some(vec![2, 7])
    );

    let before = SceneSerializer::serialize(scene.world()).expect("serialize");

    // Unknown fields are not hidden: they survive the merge and fail verification.
    expect_invalid_value(
        &mut scene,
        &object([
            (
                "resourceID",
                ComponentValue::String(" changed ".to_string()),
            ),
            ("typo", ComponentValue::Bool(true)),
        ]),
        "softBodyMesh",
        entity,
        ComponentWriteMode::Merge,
    );
    // A full replacement skips normalization, so the untrimmed value no longer
    // matches what the component decodes and re-encodes.
    expect_invalid_value(
        &mut scene,
        &object([(
            "resourceID",
            ComponentValue::String(" changed ".to_string()),
        )]),
        "softBodyMesh",
        entity,
        ComponentWriteMode::Replace,
    );
    assert_eq!(
        SceneSerializer::serialize(scene.world()).expect("serialize"),
        before
    );

    // A blank resource identifier normalizes to `null`, which drops the key.
    scene
        .set_component_data(
            &object([("resourceID", ComponentValue::String("  \n".to_string()))]),
            "softBodyMesh",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("clear resource id");
    assert!(
        scene
            .component::<SoftBodyMesh>(entity)
            .expect("soft body mesh")
            .resource_id
            .is_none()
    );
    assert!(
        scene
            .component_data("softBodyMesh", entity)
            .and_then(|value| value.value_at(&[String::from("resourceID")]).cloned())
            .is_none()
    );

    let encoded = SceneSerializer::serialize(scene.world()).expect("serialize");
    let mut restored = SceneRuntime::new(ComponentRegistry::built_in());
    SceneSerializer::deserialize(&encoded, restored.world_mut()).expect("deserialize");
    assert_eq!(
        SceneSerializer::serialize(restored.world()).expect("serialize"),
        encoded
    );
}
