//! Ported from `Engine/Tests/IntentRuntimeTests/ComponentTransactionTests.swift`.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::{Float3, Float4};
use diffuse_scene::components::core::registry::{
    ComponentCategory, ComponentDecodeContext, ComponentEncodeContext, ComponentRegistry,
    ComponentSchema,
};
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::components::editing::ComponentWriteMode;
use diffuse_scene::entity_id::{EntityID, RuntimeComponent};
use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
use diffuse_scene::particles::emitter::particle_emitter_settings::ParticleEmitterSettings;
use diffuse_scene::particles::particle_modules::ParticleEmissionModule;
use diffuse_scene::physics::collider::{Collider, ColliderShape, ColliderShapeInstance};
use diffuse_scene::physics::joints::physics_joint::PhysicsJoint;
use diffuse_scene::physics::joints::physics_joint_configuration::{
    DistanceJointConfiguration, PhysicsJointConfiguration,
};
use diffuse_scene::physics::soft_bodies::cloth::{Cloth, ClothBendType};
use diffuse_scene::rendering::render_extraction::LightComponent;
use diffuse_scene::runtime_world::{LocalTransform, RuntimeWorld};
use diffuse_scene::scene_runtime::SceneRuntime;
use diffuse_scene::serialization::scene_serializer::SceneSerializer;
use diffuse_script::core::script_component::{
    ScriptBinding, ScriptBindingID, ScriptComponent, ScriptHandle,
};
use diffuse_script::interop::component_registry_script_codec::{
    ComponentRegistryScriptCodec, encode_script_binding_for_editing,
};

use crate::transactions::transaction_executor::{
    TransactionApplyResult, TransactionExecutionContext, TransactionExecutionError,
    TransactionExecutor, TransactionExecutorError,
};
use crate::transactions::transaction_ir::{
    SceneMutation, TransactionIR, TransactionOperation, TransactionProvenance,
    TransactionVerificationAssertion,
};
use crate::transactions::world_event::{WorldEvent, WorldPropertyValue};

#[derive(Clone, Debug, PartialEq)]
struct TransactionCounter {
    value: i64,
    enabled: bool,
}

impl RuntimeComponent for TransactionCounter {}

fn encode_counter(
    world: &RuntimeWorld,
    entity: EntityID,
    _context: &mut ComponentEncodeContext,
) -> Option<ComponentValue> {
    let counter = world.component::<TransactionCounter>(entity)?;
    Some(object(vec![
        ("value", ComponentValue::Number(counter.value as f64)),
        (
            "options",
            object(vec![("enabled", ComponentValue::Bool(counter.enabled))]),
        ),
    ]))
}

fn decode_counter(
    value: &ComponentValue,
    entity: EntityID,
    _context: &mut ComponentDecodeContext,
    world: &mut RuntimeWorld,
) {
    let Some(document) = value.object_value() else {
        return;
    };
    let value = document
        .get("value")
        .and_then(|value| match value {
            ComponentValue::Number(value) => Some(*value as i64),
            ComponentValue::SignedInteger(value) => Some(*value),
            ComponentValue::UnsignedInteger(value) => Some(*value as i64),
            _ => None,
        })
        .unwrap_or(7);
    let enabled = document
        .get("options")
        .and_then(|options| options.object_value())
        .and_then(|options| options.get("enabled"))
        .and_then(|enabled| match enabled {
            ComponentValue::Bool(value) => Some(*value),
            _ => None,
        })
        .unwrap_or(true);
    world.set_component(TransactionCounter { value, enabled }, entity);
}

fn make_default_counter(entity: EntityID, world: &mut RuntimeWorld) {
    world.set_component(
        TransactionCounter {
            value: 7,
            enabled: true,
        },
        entity,
    );
}

fn transaction_counter_schema() -> ComponentSchema {
    ComponentSchema::for_component::<TransactionCounter>(
        "test.counter",
        "Counter",
        ComponentCategory::Gameplay,
        encode_counter,
        decode_counter,
        make_default_counter,
    )
}

fn object(entries: Vec<(&str, ComponentValue)>) -> ComponentValue {
    ComponentValue::Object(
        entries
            .into_iter()
            .map(|(key, value)| (key.to_string(), value))
            .collect::<BTreeMap<_, _>>(),
    )
}

fn number(value: f64) -> ComponentValue {
    ComponentValue::Number(value)
}

fn scene() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

fn context(scene: SceneRuntime) -> TransactionExecutionContext {
    TransactionExecutionContext {
        scene_runtime: Some(scene),
        ..TransactionExecutionContext::default()
    }
}

fn apply(
    transaction: TransactionIR,
    context: &mut TransactionExecutionContext,
) -> Result<TransactionApplyResult, TransactionExecutionError> {
    TransactionExecutor::new().apply(&transaction, context)
}

fn cloth() -> Cloth {
    Cloth::new(
        3,
        2,
        0.2,
        vec![0, 2, 5],
        1.0e-5,
        1.0e-5,
        1.0e-5,
        ClothBendType::Distance,
    )
}

/// Normalized verification follows removal, default insertion and later indexed
/// edits.
#[test]
fn normalized_component_recreation() {
    for existing in [false, true] {
        let mut scene = scene();
        let entity = scene.create_entity();
        if existing {
            scene.set_component(cloth(), entity);
        }
        let index = object(vec![(
            "fixedVertexIndices",
            object(vec![("0", number(5.0))]),
        )]);
        let mut context = context(scene);
        let mut operations: Vec<TransactionOperation> = Vec::new();
        let mut assertions: Vec<TransactionVerificationAssertion> = Vec::new();
        if existing {
            operations.push(TransactionOperation::Scene(
                SceneMutation::RemoveComponentData {
                    entity_id: entity.raw_value(),
                    type_id: "cloth".to_string(),
                },
            ));
            assertions.push(TransactionVerificationAssertion::ComponentPresence {
                entity_id: entity.raw_value(),
                type_id: "cloth".to_string(),
                is_present: false,
            });
        }
        operations.push(TransactionOperation::Scene(SceneMutation::AddComponent {
            entity_id: entity.raw_value(),
            type_id: "cloth".to_string(),
        }));
        operations.push(TransactionOperation::Scene(
            SceneMutation::SetComponentData {
                entity_id: entity.raw_value(),
                type_id: "cloth".to_string(),
                value: index.clone(),
                mode: ComponentWriteMode::Merge,
            },
        ));
        assertions.push(TransactionVerificationAssertion::ComponentPresence {
            entity_id: entity.raw_value(),
            type_id: "cloth".to_string(),
            is_present: true,
        });
        assertions.push(TransactionVerificationAssertion::ComponentData {
            entity_id: entity.raw_value(),
            type_id: "cloth".to_string(),
            value: index,
            mode: ComponentWriteMode::Merge,
        });
        let mut transaction = TransactionIR::new(
            "Recreate cloth",
            operations,
            TransactionProvenance::Authored,
        );
        transaction.verification_assertions = assertions;

        apply(transaction, &mut context).expect("transaction applies");
        let restored = context
            .scene_runtime
            .as_ref()
            .and_then(|scene| scene.component::<Cloth>(entity))
            .expect("cloth");
        assert_eq!(restored.fixed_vertex_indices, (1..16).collect::<Vec<i64>>());
        assert_eq!(restored.grid_size_x, 16);
    }
}

/// Normalized component input verifies canonical arrays and publishes canonical
/// events.
#[test]
fn normalized_input_verification() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(cloth(), entity);
    let mut context = context(scene);
    let patch = object(vec![(
        "fixedVertexIndices",
        object(vec![("2", number(1.0))]),
    )]);
    let mut transaction = TransactionIR::new(
        "Edit fixed points",
        vec![TransactionOperation::Scene(
            SceneMutation::SetComponentData {
                entity_id: entity.raw_value(),
                type_id: "cloth".to_string(),
                value: patch.clone(),
                mode: ComponentWriteMode::Merge,
            },
        )],
        TransactionProvenance::Authored,
    );
    transaction.verification_assertions = vec![TransactionVerificationAssertion::ComponentData {
        entity_id: entity.raw_value(),
        type_id: "cloth".to_string(),
        value: patch,
        mode: ComponentWriteMode::Merge,
    }];
    let result = apply(transaction, &mut context).expect("transaction applies");
    assert_eq!(
        context
            .scene_runtime
            .as_ref()
            .and_then(|scene| scene.component::<Cloth>(entity))
            .expect("cloth")
            .fixed_vertex_indices,
        vec![0, 1, 2]
    );
    assert!(result.world_events.iter().any(|event| {
        matches!(
            event,
            WorldEvent::EntityAuthoredChanged {
                property,
                value: WorldPropertyValue::Json(data),
                ..
            } if property == "components.cloth"
                && data.value_at(&["fixedVertexIndices".to_string()])
                    == Some(&ComponentValue::Array(
                        [0.0, 1.0, 2.0].into_iter().map(number).collect()
                    ))
        )
    }));

    let edits = [
        object(vec![(
            "fixedVertexIndices",
            object(vec![("2", number(0.0))]),
        )]),
        object(vec![(
            "fixedVertexIndices",
            object(vec![("1", number(4.0))]),
        )]),
    ];
    let mut transaction = TransactionIR::new(
        "Sequential canonical indices",
        edits
            .iter()
            .map(|value| {
                TransactionOperation::Scene(SceneMutation::SetComponentData {
                    entity_id: entity.raw_value(),
                    type_id: "cloth".to_string(),
                    value: value.clone(),
                    mode: ComponentWriteMode::Merge,
                })
            })
            .collect(),
        TransactionProvenance::Authored,
    );
    transaction.verification_assertions = edits
        .iter()
        .map(|value| TransactionVerificationAssertion::ComponentData {
            entity_id: entity.raw_value(),
            type_id: "cloth".to_string(),
            value: value.clone(),
            mode: ComponentWriteMode::Merge,
        })
        .collect();
    apply(transaction, &mut context).expect("transaction applies");
    assert_eq!(
        context
            .scene_runtime
            .as_ref()
            .and_then(|scene| scene.component::<Cloth>(entity))
            .expect("cloth")
            .fixed_vertex_indices,
        vec![0, 4]
    );

    let fixed = object(vec![(
        "fixedVertexIndices",
        ComponentValue::Array(
            [5.0, 2.0, -1.0, 2.0, 999.0]
                .into_iter()
                .map(number)
                .collect(),
        ),
    )]);
    let grid = object(vec![("gridSizeX", number(2.0))]);
    let mut transaction = TransactionIR::new(
        "Resize edited topology",
        vec![
            TransactionOperation::Scene(SceneMutation::SetComponentData {
                entity_id: entity.raw_value(),
                type_id: "cloth".to_string(),
                value: fixed.clone(),
                mode: ComponentWriteMode::Merge,
            }),
            TransactionOperation::Scene(SceneMutation::SetComponentData {
                entity_id: entity.raw_value(),
                type_id: "cloth".to_string(),
                value: grid.clone(),
                mode: ComponentWriteMode::Merge,
            }),
        ],
        TransactionProvenance::Authored,
    );
    transaction.verification_assertions = vec![
        TransactionVerificationAssertion::ComponentData {
            entity_id: entity.raw_value(),
            type_id: "cloth".to_string(),
            value: fixed,
            mode: ComponentWriteMode::Merge,
        },
        TransactionVerificationAssertion::ComponentData {
            entity_id: entity.raw_value(),
            type_id: "cloth".to_string(),
            value: grid.clone(),
            mode: ComponentWriteMode::Merge,
        },
    ];
    apply(transaction, &mut context).expect("transaction applies");
    assert_eq!(
        context
            .scene_runtime
            .as_ref()
            .and_then(|scene| scene.component::<Cloth>(entity))
            .expect("cloth")
            .fixed_vertex_indices,
        vec![2]
    );

    let before = SceneSerializer::serialize(context.scene_runtime.as_ref().expect("scene").world())
        .expect("serialize");
    let mut transaction = TransactionIR::new(
        "Incorrect postcondition",
        vec![TransactionOperation::Scene(
            SceneMutation::SetComponentData {
                entity_id: entity.raw_value(),
                type_id: "cloth".to_string(),
                value: grid,
                mode: ComponentWriteMode::Merge,
            },
        )],
        TransactionProvenance::Authored,
    );
    transaction.verification_assertions = vec![TransactionVerificationAssertion::ComponentData {
        entity_id: entity.raw_value(),
        type_id: "cloth".to_string(),
        value: object(vec![("gridSizeX", number(4.0))]),
        mode: ComponentWriteMode::Merge,
    }];
    let error = apply(transaction, &mut context).expect_err("postcondition fails");
    assert!(matches!(
        error,
        TransactionExecutionError::Executor(TransactionExecutorError::VerificationFailed(_))
    ));
    assert_eq!(
        SceneSerializer::serialize(context.scene_runtime.as_ref().expect("scene").world())
            .expect("serialize"),
        before
    );
}

/// Component dependencies participate in transactions and produce component
/// events.
#[test]
fn required_component_events() {
    let mut scene = scene();
    let mut registry = scene.component_registry().clone();
    let mut counter = transaction_counter_schema();
    counter.requires = vec!["light".to_string()];
    registry.register(counter);
    scene.set_component_registry(registry);
    let entity = scene.create_entity();
    let mut context = context(scene);
    let result = apply(
        TransactionIR::new(
            "Add with dependencies",
            vec![TransactionOperation::Scene(SceneMutation::AddComponent {
                entity_id: entity.raw_value(),
                type_id: "test.counter".to_string(),
            })],
            TransactionProvenance::Authored,
        ),
        &mut context,
    )
    .expect("transaction applies");
    let restored = context.scene_runtime.as_ref().expect("scene");
    assert!(restored.has_component::<LightComponent>(entity));
    assert_eq!(
        restored.component::<LocalTransform>(entity),
        Some(LocalTransform::IDENTITY)
    );
    assert!(result.world_events.iter().any(|event| {
        matches!(
            event,
            WorldEvent::EntityAuthoredChanged {
                property,
                value: WorldPropertyValue::Json(_),
                ..
            } if property == "components.light"
        )
    }));
}

/// Camera and light spawn events report effective registry defaults and explicit
/// overrides.
#[test]
fn spawn_registry_defaults() {
    let mut context = context(scene());
    let result = apply(
        TransactionIR::new(
            "Create registry defaults",
            vec![
                TransactionOperation::Scene(SceneMutation::SpawnLightEntity {
                    label: "Light".to_string(),
                    light_type: diffuse_scene::rendering::render_extraction::LightType::Spot,
                    position: Float3::ZERO,
                    initial_intensity: Some(17.0),
                    initial_color: None,
                    initial_range: None,
                    initial_cast_shadows: None,
                    parent_id: None,
                }),
                TransactionOperation::Scene(SceneMutation::SpawnCameraEntity {
                    label: "Camera".to_string(),
                    position: Float3::ZERO,
                    initial_fov_y_degrees: None,
                    parent_id: None,
                }),
            ],
            TransactionProvenance::Authored,
        ),
        &mut context,
    )
    .expect("transaction applies");
    let scene = context.scene_runtime.as_ref().expect("scene");
    let light = EntityID::from_raw_value(result.created_entity_ids[0]);
    let camera = EntityID::from_raw_value(result.created_entity_ids[1]);
    let light_component = scene.component::<LightComponent>(light).expect("light");
    assert_eq!(light_component.intensity, 17.0);
    assert_eq!(
        light_component.light_type,
        diffuse_scene::rendering::render_extraction::LightType::Spot
    );
    let value = scene.component_data("camera", camera).expect("camera data");
    assert!(result.world_events.iter().any(|event| {
        matches!(
            event,
            WorldEvent::EntityAuthoredChanged {
                property,
                value: WorldPropertyValue::Json(data),
                ..
            } if property == "components.camera" && data == &value
        )
    }));
}

/// A contributed component supports add, sequential nested edits, duplication
/// and removal.
#[test]
fn contributed_component_lifecycle() {
    let mut scene = scene();
    let mut registry = scene.component_registry().clone();
    registry.register(transaction_counter_schema());
    scene.set_component_registry(registry);
    let entity = scene.create_entity();
    let id = entity.raw_value();
    let mut context = context(scene);
    let executor = TransactionExecutor::new();
    let operations = vec![
        TransactionOperation::Scene(SceneMutation::AddComponent {
            entity_id: id,
            type_id: "test.counter".to_string(),
        }),
        TransactionOperation::Scene(SceneMutation::component_fields(
            id,
            "test.counter",
            vec![("value".to_string(), Some(number(42.0)))],
        )),
        TransactionOperation::Scene(SceneMutation::component_fields(
            id,
            "test.counter",
            vec![(
                "options".to_string(),
                Some(object(vec![("enabled", ComponentValue::Bool(false))])),
            )],
        )),
        TransactionOperation::Scene(SceneMutation::component_fields(
            id,
            "test.counter",
            vec![("value".to_string(), Some(number(81.0)))],
        )),
        TransactionOperation::Scene(SceneMutation::DuplicateEntity { entity_id: id }),
    ];
    let result = executor
        .apply(
            &TransactionIR::new(
                "Edit contributed component",
                operations,
                TransactionProvenance::Authored,
            ),
            &mut context,
        )
        .expect("transaction applies");
    let restored = context.scene_runtime.as_ref().expect("scene");
    assert_eq!(
        restored.component::<TransactionCounter>(entity),
        Some(TransactionCounter {
            value: 81,
            enabled: false,
        })
    );
    let copy = EntityID::from_raw_value(*result.created_entity_ids.first().expect("copy"));
    assert_eq!(
        restored.component::<TransactionCounter>(copy),
        restored.component::<TransactionCounter>(entity)
    );
    assert!(result.world_events.iter().any(|event| {
        matches!(
            event,
            WorldEvent::EntityAuthoredChanged {
                property,
                value: WorldPropertyValue::Json(data),
                ..
            } if property == "components.test.counter"
                && data.contains_fields(&object(vec![("value", number(81.0))]))
        )
    }));

    executor
        .apply(
            &TransactionIR::new(
                "Remove contributed component",
                vec![TransactionOperation::Scene(
                    SceneMutation::RemoveComponentData {
                        entity_id: id,
                        type_id: "test.counter".to_string(),
                    },
                )],
                TransactionProvenance::Authored,
            ),
            &mut context,
        )
        .expect("transaction applies");
    let restored = context.scene_runtime.as_ref().expect("scene");
    assert!(!restored.has_component::<TransactionCounter>(entity));
    assert!(restored.has_component::<TransactionCounter>(copy));
}

/// An invalid component write rolls back preceding structural and component
/// edits.
#[test]
fn atomic_failure() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(LightComponent::default(), entity);
    let before = SceneSerializer::serialize(scene.world()).expect("serialize");
    let invalid_values = [
        SceneMutation::SetComponentData {
            entity_id: entity.raw_value(),
            type_id: "unknown".to_string(),
            value: object(Vec::new()),
            mode: ComponentWriteMode::Replace,
        },
        SceneMutation::SetComponentData {
            entity_id: entity.raw_value(),
            type_id: "light".to_string(),
            value: ComponentValue::Null,
            mode: ComponentWriteMode::Replace,
        },
        SceneMutation::SetComponentData {
            entity_id: entity.raw_value(),
            type_id: "light".to_string(),
            value: object(vec![("typo", ComponentValue::Bool(true))]),
            mode: ComponentWriteMode::Replace,
        },
        SceneMutation::SetComponentData {
            entity_id: u64::MAX,
            type_id: "light".to_string(),
            value: object(Vec::new()),
            mode: ComponentWriteMode::Replace,
        },
    ];
    for invalid in invalid_values {
        let mut context = context(scene.clone());
        let transaction = TransactionIR::new(
            "Must roll back",
            vec![
                TransactionOperation::Scene(SceneMutation::SpawnEmptyEntity {
                    label: "Temporary".to_string(),
                    position: Float3::ZERO,
                    parent_id: None,
                }),
                TransactionOperation::Scene(SceneMutation::component_fields(
                    entity.raw_value(),
                    "light",
                    vec![("intensity".to_string(), Some(number(7.0)))],
                )),
                TransactionOperation::Scene(invalid),
            ],
            TransactionProvenance::Authored,
        );
        assert!(apply(transaction, &mut context).is_err());
        assert_eq!(
            SceneSerializer::serialize(context.scene_runtime.as_ref().expect("scene").world())
                .expect("serialize"),
            before
        );
    }
}

/// Non-finite numbers and out-of-range integer fields reject without trapping.
#[test]
fn invalid_numeric_values() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 1.0,
            center: Float3::ZERO,
        }),
        entity,
    );
    let before = scene
        .component_data("collider", entity)
        .expect("collider data");
    for value in [
        object(vec![("layerID", number(65_536.0))]),
        object(vec![("layerMask", number(-1.0))]),
        object(vec![("friction", number(f64::INFINITY))]),
        object(vec![("friction", number(f64::NAN))]),
    ] {
        assert!(
            scene
                .set_component_data(&value, "collider", entity, ComponentWriteMode::Merge)
                .is_err()
        );
        assert_eq!(
            scene.component_data("collider", entity),
            Some(before.clone())
        );
    }
}

/// Compound shape field edits preserve other instances and their transforms.
#[test]
fn compound_collider_editing() {
    let mut scene = scene();
    let entity = scene.create_entity();
    let second = ColliderShapeInstance::with_transform(
        ColliderShape::Box {
            half_extents: Float3::splat(2.0),
            center: Float3::ZERO,
        },
        Float3::new(3.0, 4.0, 5.0),
        Float4::new(0.0, 0.0, 0.0, 1.0),
        Float3::ONE,
    );
    scene.set_component(
        Collider::with_shapes(vec![
            ColliderShapeInstance::new(ColliderShape::Sphere {
                radius: 1.0,
                center: Float3::new(1.0, 2.0, 3.0),
            }),
            second.clone(),
        ]),
        entity,
    );
    scene
        .set_component_data(
            &object(vec![(
                "shapes",
                object(vec![("0", object(vec![("radius", number(4.0))]))]),
            )]),
            "collider",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("merge applies");
    let edited = scene.component::<Collider>(entity).expect("collider");
    assert_eq!(edited.shapes[1], second);
    assert_eq!(
        edited.shapes[0].shape,
        ColliderShape::Sphere {
            radius: 4.0,
            center: Float3::new(1.0, 2.0, 3.0),
        }
    );
    let before = scene
        .component_data("collider", entity)
        .expect("collider data");
    assert!(
        scene
            .set_component_data(
                &object(vec![(
                    "shapes",
                    object(vec![("9", object(vec![("radius", number(4.0))]))]),
                )]),
                "collider",
                entity,
                ComponentWriteMode::Merge,
            )
            .is_err()
    );
    assert_eq!(scene.component_data("collider", entity), Some(before));
}

/// Reference edits use entity generations and duplication remaps self
/// references.
#[test]
fn reference_identity() {
    let mut scene = scene();
    let removed = scene.create_entity();
    scene.destroy_entity(removed);
    let target = scene.create_entity();
    let joint = scene.create_entity();
    scene.set_component(
        PhysicsJoint::new(
            PhysicsJointConfiguration::Distance(DistanceJointConfiguration::default()),
            joint,
            target,
            Float3::ZERO,
            Float3::ZERO,
            true,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
        ),
        joint,
    );
    let data = scene
        .component_data("constraint", joint)
        .expect("constraint data");
    let unrelated = scene.create_entity();
    scene.destroy_entity(unrelated);
    scene
        .set_component_data(&data, "constraint", joint, ComponentWriteMode::Replace)
        .expect("round-trip data");
    let mut context = context(scene);
    let result = apply(
        TransactionIR::new(
            "Duplicate reference component",
            vec![TransactionOperation::Scene(
                SceneMutation::DuplicateEntity {
                    entity_id: joint.raw_value(),
                },
            )],
            TransactionProvenance::Authored,
        ),
        &mut context,
    )
    .expect("transaction applies");
    let copy = EntityID::from_raw_value(*result.created_entity_ids.first().expect("copy"));
    let constraint = context
        .scene_runtime
        .as_ref()
        .and_then(|scene| scene.component::<PhysicsJoint>(copy))
        .expect("constraint");
    assert_eq!(constraint.entity_a, copy);
    assert_eq!(constraint.entity_b, target);
    assert_ne!(target.generation, removed.generation);

    let scene = context.scene_runtime.as_mut().expect("scene");
    assert!(
        scene
            .set_component_data(
                &object(vec![(
                    "entityB",
                    ComponentValue::SignedInteger(removed.raw_value() as i64),
                )]),
                "constraint",
                joint,
                ComponentWriteMode::Merge,
            )
            .is_err()
    );
    assert_eq!(
        scene
            .component::<PhysicsJoint>(joint)
            .map(|joint| joint.entity_b),
        Some(target)
    );
}

/// Particle edits retain the running pool and RNG while reseeding resets
/// simulation.
#[test]
fn particle_simulation_state() {
    let mut emitter = ParticleEmitter::new(ParticleEmitterSettings {
        emission: ParticleEmissionModule::configured(|module| module.seed = 345),
        ..ParticleEmitterSettings::default()
    });
    emitter.emit(5, None);
    let expected = emitter.clone();
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(emitter.clone(), entity);
    scene
        .set_component_data(
            &object(vec![(
                "settings",
                object(vec![(
                    "emission",
                    object(vec![("emissionRate", number(8.0))]),
                )]),
            )]),
            "particleEmitter",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("edit applies");
    let mut actual = scene.component::<ParticleEmitter>(entity).expect("emitter");
    assert_eq!(actual.particles(), emitter.particles());
    let mut expected = expected;
    expected.settings.emission.emission_rate = 8.0;
    actual.emit(3, None);
    expected.emit(3, None);
    assert_eq!(actual.particles(), expected.particles());

    scene
        .set_component_data(
            &object(vec![(
                "settings",
                object(vec![(
                    "emission",
                    object(vec![("seed", ComponentValue::UnsignedInteger(u64::MAX))]),
                )]),
            )]),
            "particleEmitter",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("seed applies");
    let reseeded = scene.component::<ParticleEmitter>(entity).expect("emitter");
    assert!(reseeded.particles().is_empty());
    assert_eq!(reseeded.settings.emission.seed, u64::MAX);
}

/// Script edits retain live handles while scene persistence excludes them.
#[test]
fn script_handle_boundary() {
    let mut registry = ComponentRegistry::built_in();
    registry.register_script_codec("cove.rotator");
    let mut scene = SceneRuntime::new(registry.clone());
    let entity = scene.create_entity();
    let binding = ScriptBinding::new(
        ScriptHandle::new(123),
        ScriptBindingID::new(),
        Some("project.counter".to_string()),
        true,
        "{}",
    );
    scene.set_component(ScriptComponent::new(vec![binding.clone()]), entity);
    let mut edited = binding;
    edited.is_enabled = false;
    let value = object(vec![(
        "bindings",
        ComponentValue::Array(vec![ComponentValue::Object(
            encode_script_binding_for_editing(&edited),
        )]),
    )]);
    scene
        .set_component_data(&value, "script", entity, ComponentWriteMode::Merge)
        .expect("script edit applies");
    let component = scene.component::<ScriptComponent>(entity).expect("script");
    assert_eq!(component.bindings[0].script.raw_value, 123);
    assert!(!component.bindings[0].is_enabled);

    let document = SceneSerializer::serialize(scene.world()).expect("serialize");
    assert!(!document.contains("scriptHandle"));
    let mut restored = SceneRuntime::new(registry);
    SceneSerializer::deserialize(&document, restored.world_mut()).expect("deserialize");
    let restored_entity = restored.entities()[0];
    assert_eq!(
        restored
            .component::<ScriptComponent>(restored_entity)
            .expect("script")
            .bindings[0]
            .script
            .raw_value,
        0
    );
}
