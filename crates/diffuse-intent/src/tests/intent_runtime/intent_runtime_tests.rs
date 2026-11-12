//! Ported from `Engine/Tests/IntentRuntimeTests/IntentRuntimeTests.swift`.
//!
//! Partial migration: scene/sequence/asset transaction cases and the intent
//! builder land first; capability-planning and observation-bus cases follow in
//! later batches.

use std::sync::Arc;

use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::components::editing::ComponentWriteMode;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::audio::AudioListener;
use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
use diffuse_scene::particles::emitter::particle_emitter_settings::ParticleEmitterSettings;
use diffuse_scene::particles::particle_curve::{ParticleCurve, ParticleCurveKeyframe};
use diffuse_scene::particles::particle_modules::{
    ParticleEmissionModule, ParticleForcesModule, ParticleGPUSimulationModule,
    ParticleRendererModule, ParticleSubEmittersModule, ParticleTextureSheetModule,
    ParticleTrailsModule, ParticleVelocityModule,
};
use diffuse_scene::particles::particle_types::{
    ParticleForceMode, ParticleRenderAlignment, ParticleSimulationSpace, ParticleSubEmitterTrigger,
};
use diffuse_scene::physics::rigid_body::{RigidBody, RigidBodyMotionType, RigidBodyOptions};
use diffuse_scene::rendering::render_extraction::{CameraComponent, RenderMeshComponent};
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_bootstrap::SceneNameComponent;
use diffuse_scene::scene_runtime::SceneRuntime;
use diffuse_script::core::script_component::{
    ScriptBinding, ScriptBindingID, ScriptComponent, ScriptHandle,
};
use diffuse_script::interop::component_registry_script_codec::{
    ComponentRegistryScriptCodec, encode_script_binding_for_editing,
};
use diffuse_sequence::sequence_document::{FrameRange, SequenceDocument, SequenceRevision};

use crate::planning::intent_ir::{IntentArgumentValue, IntentIR, IntentSource, IntentVector3};
use crate::transactions::intent_transaction_builder::{
    IntentTransactionBuildContext, IntentTransactionBuilder,
};
use crate::transactions::transaction_executor::{
    TransactionExecutionContext, TransactionExecutionError, TransactionExecutor,
    TransactionExecutorError,
};
use crate::transactions::transaction_ir::{
    SceneMutation, SequenceMutation, TransactionBaseRevisions, TransactionDomain, TransactionIR,
    TransactionOperation, TransactionProvenance,
};

pub(crate) fn scene() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

fn scene_with_script_codec() -> SceneRuntime {
    let mut scene = scene();
    let mut registry = scene.component_registry().clone();
    registry.register_default_script_codec();
    scene.set_component_registry(registry);
    scene
}

pub(crate) fn transaction(
    intent: IntentIR,
    summary: &str,
    operations: Vec<TransactionOperation>,
    base_revisions: TransactionBaseRevisions,
) -> TransactionIR {
    let mut transaction = TransactionIR::new(summary, operations, TransactionProvenance::Authored);
    transaction.intent = Some(intent);
    transaction.base_revisions = base_revisions;
    transaction
}

pub(crate) fn scene_context(scene: SceneRuntime) -> TransactionExecutionContext {
    TransactionExecutionContext {
        scene_runtime: Some(scene),
        ..TransactionExecutionContext::default()
    }
}

fn object(entries: Vec<(&str, ComponentValue)>) -> ComponentValue {
    ComponentValue::Object(
        entries
            .into_iter()
            .map(|(key, value)| (key.to_string(), value))
            .collect(),
    )
}

/// Scene mutation target projection includes the offset duplication source.
#[test]
fn scene_mutation_target_projection() {
    assert_eq!(
        SceneMutation::DuplicateEntityWithOffset {
            entity_id: 42,
            position_offset: Float3::new(1.0, 0.0, 0.0),
        }
        .entity_id(),
        Some(42)
    );
    assert_eq!(
        SceneMutation::SpawnEmptyEntity {
            label: "New".to_string(),
            position: Float3::ZERO,
            parent_id: None,
        }
        .entity_id(),
        None
    );
}

/// Scene transactions preview without mutating the base scene and apply
/// cleanly.
#[test]
fn scene_transactions_preview_and_apply() {
    let executor = TransactionExecutor::new();
    let transaction = transaction(
        IntentIR::new(
            "scene.spawn_entity",
            "Spawn imported mesh",
            IntentSource::Human,
        ),
        "Spawn imported mesh",
        vec![TransactionOperation::Scene(
            SceneMutation::SpawnImportedMeshEntity {
                label: "Hero".to_string(),
                kind_label: "Static Mesh".to_string(),
                mesh_index: 9,
                position: Float3::new(0.0, 1.0, 0.0),
                parent_id: None,
            },
        )],
        TransactionBaseRevisions {
            scene_revision: Some(0),
            ..TransactionBaseRevisions::default()
        },
    );
    let base_context = scene_context(scene());

    let preview = executor
        .preview(&transaction, &base_context)
        .expect("preview");
    assert_eq!(preview.changed_domains, vec![TransactionDomain::Scene]);
    assert_eq!(preview.created_entity_ids.len(), 1);
    assert_eq!(
        base_context
            .scene_runtime
            .as_ref()
            .map(|scene| scene.snapshot().entity_count),
        Some(0)
    );

    let mut apply_context = base_context.clone();
    let applied = executor
        .apply(&transaction, &mut apply_context)
        .expect("apply");
    let scene = apply_context.scene_runtime.as_ref().expect("scene");
    let entity = EntityID::from_raw_value(*applied.created_entity_ids.first().expect("entity"));

    assert_eq!(scene.snapshot().entity_count, 1);
    assert_eq!(applied.scene_revision, Some(scene.snapshot().revision));
    assert_eq!(
        scene
            .component::<SceneNameComponent>(entity)
            .map(|name| name.value),
        Some("Hero".to_string())
    );
    assert_eq!(
        scene
            .component::<RenderMeshComponent>(entity)
            .map(|mesh| mesh.mesh_index),
        Some(9)
    );
    assert_eq!(
        scene
            .local_transform(entity)
            .map(|transform| transform.translation()),
        Some(Float3::new(0.0, 1.0, 0.0))
    );
}

/// Scene transactions reject stale base revisions.
#[test]
fn scene_transactions_reject_stale_base_revisions() {
    let executor = TransactionExecutor::new();
    let mut scene = scene();
    scene.create_entity();
    let actual_revision = scene.snapshot().revision;
    let mut context = scene_context(scene);
    let transaction = transaction(
        IntentIR::new(
            "scene.spawn_entity",
            "Spawn imported mesh",
            IntentSource::Human,
        ),
        "Spawn imported mesh",
        vec![TransactionOperation::Scene(
            SceneMutation::SpawnImportedMeshEntity {
                label: "Hero".to_string(),
                kind_label: "Static Mesh".to_string(),
                mesh_index: 3,
                position: Float3::ZERO,
                parent_id: None,
            },
        )],
        TransactionBaseRevisions {
            scene_revision: Some(actual_revision + 1),
            ..TransactionBaseRevisions::default()
        },
    );

    let error = executor
        .apply(&transaction, &mut context)
        .expect_err("stale revision");
    assert!(matches!(
        error,
        TransactionExecutionError::Executor(
            TransactionExecutorError::SceneBaseRevisionMismatch { .. }
        )
    ));
}

/// Scene transactions update script binding parameters.
#[test]
fn scene_transactions_update_script_bindings() {
    let executor = TransactionExecutor::new();
    let mut scene = scene_with_script_codec();
    let entity = scene.create_entity();
    let initial = ScriptBinding::new(
        ScriptHandle::new(7),
        ScriptBindingID::new(),
        None,
        false,
        "{}",
    );
    scene.set_component(ScriptComponent::new(vec![initial]), entity);

    let next = ScriptBinding::new(
        ScriptHandle::new(7),
        ScriptBindingID::new(),
        None,
        true,
        r#"{"speed":3}"#,
    );
    let value = object(vec![(
        "bindings",
        ComponentValue::Array(vec![ComponentValue::Object(
            encode_script_binding_for_editing(&next),
        )]),
    )]);
    let transaction = transaction(
        IntentIR::new(
            "scene.set_script_parameters",
            "Update script parameters",
            IntentSource::Human,
        ),
        "Update script parameters",
        vec![TransactionOperation::Scene(
            SceneMutation::SetComponentData {
                entity_id: entity.raw_value(),
                type_id: "script".to_string(),
                value,
                mode: ComponentWriteMode::Replace,
            },
        )],
        TransactionBaseRevisions {
            scene_revision: Some(scene.snapshot().revision),
            ..TransactionBaseRevisions::default()
        },
    );
    let mut context = scene_context(scene);

    let applied = executor.apply(&transaction, &mut context).expect("apply");
    let updated = context
        .scene_runtime
        .as_ref()
        .and_then(|scene| scene.component::<ScriptComponent>(entity))
        .expect("script component");

    assert_eq!(applied.changed_domains, vec![TransactionDomain::Scene]);
    assert_eq!(updated.bindings.len(), 1);
    assert!(updated.bindings[0].is_enabled);
    assert_eq!(updated.bindings[0].parameters_json, r#"{"speed":3}"#);
}

/// Scene transactions set a particle emitter component.
#[test]
fn scene_transactions_set_particle_emitter() {
    let executor = TransactionExecutor::new();
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(
        ParticleEmitter::new(ParticleEmitterSettings {
            emission: ParticleEmissionModule::configured(|module| module.emission_rate = 10.0),
            ..ParticleEmitterSettings::default()
        }),
        entity,
    );

    let emitter = ParticleEmitter::new(ParticleEmitterSettings {
        emission: ParticleEmissionModule::configured(|module| {
            module.duration = 2.5;
            module.prewarm_time = 1.5;
            module.prewarm_step = 0.05;
            module.emission_rate = 55.0;
            module.emission_rate_curve = ParticleCurve::Constant(1.25);
            module.distance_emission_rate = 7.0;
            module.distance_emission_rate_curve = ParticleCurve::Keyframes(vec![
                ParticleCurveKeyframe::new(0.0, 0.0),
                ParticleCurveKeyframe::new(1.0, 2.0),
            ]);
            module.max_particles = 200;
            module.seed = 99;
        }),
        appearance:
            diffuse_scene::particles::particle_modules::ParticleAppearanceModule::configured(
                |module| module.lifetime = 3.0,
            ),
        sub_emitters: ParticleSubEmittersModule::configured(|module| {
            module.legacy_trigger = ParticleSubEmitterTrigger::Death;
            module.legacy_burst_count = 5;
            module.legacy_probability = 0.7;
            module.legacy_max_depth = 2;
            module.legacy_inherit_velocity = 0.35;
            module.legacy_lifetime = 0.4;
            module.legacy_start_velocity = Float3::new(1.0, 2.0, 3.0);
            module.legacy_velocity_randomness = Float3::new(0.1, 0.2, 0.3);
            module.legacy_start_size = 0.25;
            module.legacy_end_size = 0.05;
        }),
        velocity: ParticleVelocityModule::configured(|module| {
            module.velocity_inheritance = 0.45;
        }),
        forces: ParticleForcesModule::configured(|module| {
            module.force_mode = ParticleForceMode::Radial;
            module.force_center = Float3::new(1.0, 2.0, 3.0);
            module.force_axis = Float3::new(0.0, 1.0, 0.0);
            module.force_radius = 9.0;
            module.force_strength = -4.0;
            module.force_falloff = 2.0;
        }),
        gpu_simulation: ParticleGPUSimulationModule::configured(|module| {
            module.simulation_space = ParticleSimulationSpace::World;
        }),
        renderer: ParticleRendererModule::configured(|module| {
            module.render_alignment = ParticleRenderAlignment::Velocity;
            module.velocity_stretch_scale = 0.2;
            module.velocity_stretch_max = 5.0;
        }),
        texture_sheet: ParticleTextureSheetModule::configured(|module| {
            module.columns = 4;
            module.rows = 2;
            module.frame_count = 8;
            module.frame_rate = 16.0;
        }),
        trails: ParticleTrailsModule::configured(|module| {
            module.trail_length = 0.5;
            module.trail_segments = 3;
            module.trail_end_size_scale = 0.25;
            module.trail_end_alpha_scale = 0.1;
        }),
        ..ParticleEmitterSettings::default()
    });
    let registry = scene.component_registry().clone();
    let transaction = transaction(
        IntentIR::new(
            "scene.set_particle_emitter",
            "Update emitter",
            IntentSource::Human,
        ),
        "Update emitter",
        vec![TransactionOperation::Scene(SceneMutation::component_data(
            entity.raw_value(),
            "particleEmitter",
            emitter,
            registry,
        ))],
        TransactionBaseRevisions {
            scene_revision: Some(scene.snapshot().revision),
            ..TransactionBaseRevisions::default()
        },
    );
    let mut context = scene_context(scene);
    let applied = executor.apply(&transaction, &mut context).expect("apply");
    let updated = context
        .scene_runtime
        .as_ref()
        .and_then(|scene| scene.component::<ParticleEmitter>(entity))
        .expect("emitter");

    assert_eq!(applied.changed_domains, vec![TransactionDomain::Scene]);
    assert_eq!(updated.settings.emission.duration, 2.5);
    assert_eq!(updated.settings.emission.prewarm_time, 1.5);
    assert_eq!(updated.settings.emission.prewarm_step, 0.05);
    assert_eq!(updated.settings.emission.emission_rate, 55.0);
    assert_eq!(
        updated.settings.emission.emission_rate_curve,
        ParticleCurve::Constant(1.25)
    );
    assert_eq!(updated.settings.emission.distance_emission_rate, 7.0);
    assert_eq!(updated.settings.emission.max_particles, 200);
    assert_eq!(
        updated.settings.sub_emitters.legacy_trigger,
        ParticleSubEmitterTrigger::Death
    );
    assert_eq!(updated.settings.sub_emitters.legacy_burst_count, 5);
    assert_eq!(
        updated.settings.forces.force_mode,
        ParticleForceMode::Radial
    );
    assert_eq!(updated.settings.forces.force_strength, -4.0);
    assert_eq!(
        updated.settings.gpu_simulation.simulation_space,
        ParticleSimulationSpace::World
    );
    assert_eq!(
        updated.settings.renderer.render_alignment,
        ParticleRenderAlignment::Velocity
    );
    assert_eq!(updated.settings.texture_sheet.columns, 4);
    assert_eq!(updated.settings.trails.trail_length, 0.5);
    assert_eq!(updated.settings.emission.seed, 99);
}

/// Scene transactions set an audio listener master volume.
#[test]
fn scene_transactions_set_audio_listener() {
    let executor = TransactionExecutor::new();
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(AudioListener::new(1.0), entity);

    let transaction = transaction(
        IntentIR::new(
            "scene.set_audio_listener",
            "Update listener",
            IntentSource::Human,
        ),
        "Update listener",
        vec![TransactionOperation::Scene(
            SceneMutation::component_fields(
                entity.raw_value(),
                "audioListener",
                vec![(
                    "masterVolume".to_string(),
                    Some(ComponentValue::Number(0.3)),
                )],
            ),
        )],
        TransactionBaseRevisions {
            scene_revision: Some(scene.snapshot().revision),
            ..TransactionBaseRevisions::default()
        },
    );
    let mut context = scene_context(scene);
    let applied = executor.apply(&transaction, &mut context).expect("apply");
    let updated = context
        .scene_runtime
        .as_ref()
        .and_then(|scene| scene.component::<AudioListener>(entity))
        .expect("listener");

    assert_eq!(applied.changed_domains, vec![TransactionDomain::Scene]);
    assert_eq!(updated.master_volume, 0.3);
}

/// Scene transactions update rigid body inspector fields.
#[test]
fn scene_transactions_update_rigid_body_inspector_fields() {
    let executor = TransactionExecutor::new();
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(
        RigidBody::new(RigidBodyOptions {
            mass: 80.0,
            ..RigidBodyOptions::default()
        }),
        entity,
    );

    let transaction = transaction(
        IntentIR::new(
            "scene.update_rigidbody",
            "Update rigid body inspector fields",
            IntentSource::Human,
        ),
        "Update rigid body inspector fields",
        vec![
            TransactionOperation::Scene(SceneMutation::component_fields(
                entity.raw_value(),
                "rigidbody",
                vec![(
                    "motionType".to_string(),
                    Some(ComponentValue::String(
                        RigidBodyMotionType::Kinematic.raw_value().to_string(),
                    )),
                )],
            )),
            TransactionOperation::Scene(SceneMutation::component_fields(
                entity.raw_value(),
                "rigidbody",
                vec![("mass".to_string(), Some(ComponentValue::Number(42.0)))],
            )),
            TransactionOperation::Scene(SceneMutation::component_fields(
                entity.raw_value(),
                "rigidbody",
                vec![(
                    "gravityScale".to_string(),
                    Some(ComponentValue::Number(0.5)),
                )],
            )),
        ],
        TransactionBaseRevisions {
            scene_revision: Some(scene.snapshot().revision),
            ..TransactionBaseRevisions::default()
        },
    );
    let mut context = scene_context(scene);
    let applied = executor.apply(&transaction, &mut context).expect("apply");
    let updated = context
        .scene_runtime
        .as_ref()
        .and_then(|scene| scene.component::<RigidBody>(entity))
        .expect("rigid body");

    assert_eq!(applied.changed_domains, vec![TransactionDomain::Scene]);
    assert_eq!(updated.motion_type, RigidBodyMotionType::Kinematic);
    assert_eq!(updated.mass, 42.0);
    assert_eq!(updated.gravity_scale, 0.5);
}

/// Sequence transactions replace the document and issue a new revision.
#[test]
fn sequence_transactions_advance_revisions() {
    let executor = TransactionExecutor::new();
    let mut previous_revision = SequenceRevision::new("rev.0001".to_string());
    previous_revision.author = "human".to_string();
    previous_revision.transaction_ids = vec!["tx.old".to_string()];
    let mut current = SequenceDocument::new(
        diffuse_sequence::sequence_document::new_uuid(),
        "Sequence A",
        "scene://main",
        FrameRange::new(0, 48),
    );
    current.revision = previous_revision.clone();
    let replacement = SequenceDocument::new(
        diffuse_sequence::sequence_document::new_uuid(),
        "Sequence B",
        "scene://main",
        FrameRange::new(0, 96),
    );
    let transaction = transaction(
        IntentIR::new(
            "sequence.replace_document",
            "Replace sequence document",
            IntentSource::Human,
        ),
        "Replace sequence document",
        vec![TransactionOperation::Sequence(
            SequenceMutation::ReplaceDocument(Box::new(replacement)),
        )],
        TransactionBaseRevisions {
            sequence_revision_id: Some(previous_revision.id.clone()),
            ..TransactionBaseRevisions::default()
        },
    );
    let mut context = TransactionExecutionContext {
        sequence_document: Some(current),
        ..TransactionExecutionContext::default()
    };

    let applied = executor.apply(&transaction, &mut context).expect("apply");
    let document = context.sequence_document.as_ref().expect("document");

    assert_eq!(applied.changed_domains, vec![TransactionDomain::Sequence]);
    assert_eq!(document.name, "Sequence B");
    assert_ne!(document.revision.id, "draft.0002");
    assert_eq!(
        document.revision.parent_id.as_deref(),
        Some(previous_revision.id.as_str())
    );
    assert_eq!(
        document.revision.base_sequence_revision_id.as_deref(),
        Some(previous_revision.id.as_str())
    );
    assert_eq!(
        document.revision.transaction_ids,
        vec!["tx.old".to_string(), transaction.id.clone()]
    );
}

/// Asset transactions rescan a project directory through `AssetRegistry`.
#[test]
fn asset_transactions_scan_projects() {
    let executor = TransactionExecutor::new();
    let registry = AssetRegistry::new();
    let root = std::env::temp_dir().join(format!(
        "diffuse-intent-assets-{}",
        diffuse_sequence::sequence_document::new_uuid()
    ));
    std::fs::create_dir_all(&root).expect("create project root");
    std::fs::write(
        root.join("mesh.obj"),
        "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n",
    )
    .expect("write mesh");

    let transaction = transaction(
        IntentIR::new(
            "asset.scan_project",
            "Scan project assets",
            IntentSource::System,
        ),
        "Scan project assets",
        vec![TransactionOperation::Asset(
            crate::transactions::transaction_ir::AssetMutation::ScanProject {
                root_path: root.to_string_lossy().into_owned(),
            },
        )],
        TransactionBaseRevisions::default(),
    );
    let mut context = TransactionExecutionContext {
        asset_registry: Some(Arc::new(registry)),
        ..TransactionExecutionContext::default()
    };

    let applied = executor.apply(&transaction, &mut context).expect("apply");

    assert_eq!(applied.changed_domains, vec![TransactionDomain::Asset]);
    assert_eq!(applied.asset_entry_count, Some(1));
    assert_eq!(
        context
            .asset_registry
            .as_ref()
            .expect("asset registry")
            .entries_snapshot()
            .into_iter()
            .map(|entry| entry.relative_path)
            .collect::<Vec<_>>(),
        vec!["mesh.obj".to_string()]
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// `IntentIR` decodes legacy payloads without typed arguments.
#[test]
fn intent_ir_decodes_legacy_payloads() {
    let value: serde_json::Value =
        serde_json::from_str(r#"{"verb":"scene.spawn_entity","summary":"Spawn","source":"human"}"#)
            .expect("json");
    let intent = IntentIR::from_json(&value).expect("decode");

    assert_eq!(intent.verb, "scene.spawn_entity");
    assert!(intent.target_object_ids.is_empty());
    assert!(intent.arguments.is_empty());
    assert_eq!(intent.confidence, 1.0);
    assert!(intent.evidence.is_empty());
}

/// The intent transaction builder converts typed intents to scene
/// transactions.
#[test]
fn intent_transaction_builder_builds_scene_transactions() {
    let builder = IntentTransactionBuilder::new();
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(SceneNameComponent::new("Hero"), entity);
    scene.set_local_transform(LocalTransform::from_translation(Float3::ZERO), entity);
    scene.set_component(CameraComponent::default(), entity);

    let mut rename = IntentIR::new(
        "scene.set_name",
        "Rename selected entity",
        IntentSource::Human,
    );
    rename.target_object_ids = vec![format!("scene:{}", entity.raw_value())];
    rename.arguments.insert(
        "name".to_string(),
        IntentArgumentValue::String("Boss".to_string()),
    );
    let mut move_intent = IntentIR::new(
        "scene.set_transform",
        "Move selected entity",
        IntentSource::Human,
    );
    move_intent.target_object_ids = vec![format!("scene:{}", entity.raw_value())];
    move_intent.arguments.insert(
        "translation".to_string(),
        IntentArgumentValue::Vec3(IntentVector3::new(3.0, 4.0, 5.0)),
    );
    let mut aspect = IntentIR::new(
        "scene.set_camera_aspect_ratio",
        "Set camera aspect",
        IntentSource::Human,
    );
    aspect.target_object_ids = vec![format!("scene:{}", entity.raw_value())];
    aspect.arguments.insert(
        "aspect_ratio".to_string(),
        IntentArgumentValue::Number(1.777),
    );
    let context = IntentTransactionBuildContext {
        scene_runtime: scene,
        selected_entity_id: Some(entity.raw_value()),
        default_spawn_mesh_index: 7,
    };

    let rename_tx = builder
        .build_transaction(&rename, &context)
        .expect("rename transaction");
    let move_tx = builder
        .build_transaction(&move_intent, &context)
        .expect("move transaction");
    let aspect_tx = builder
        .build_transaction(&aspect, &context)
        .expect("aspect transaction");

    assert_eq!(
        rename_tx.operations,
        vec![TransactionOperation::Scene(SceneMutation::SetSceneName {
            entity_id: entity.raw_value(),
            value: "Boss".to_string(),
        })]
    );
    match move_tx.operations.first() {
        Some(TransactionOperation::Scene(SceneMutation::SetLocalTransform {
            entity_id,
            transform,
        })) => {
            assert_eq!(*entity_id, entity.raw_value());
            assert_eq!(transform.translation(), Float3::new(3.0, 4.0, 5.0));
        }
        other => panic!("expected setLocalTransform scene mutation, got {other:?}"),
    }
    assert_eq!(
        aspect_tx.operations,
        vec![TransactionOperation::Scene(
            SceneMutation::component_fields(
                entity.raw_value(),
                "camera",
                vec![(
                    "aspectRatio".to_string(),
                    Some(ComponentValue::Number(1.777f32 as f64)),
                )],
            )
        )]
    );
}

fn ambiguity_context(
    requires_target: bool,
    is_destructive: bool,
    required_arguments: &[&str],
) -> crate::invocation::ambiguity_scorer::AmbiguityScoringContext {
    crate::invocation::ambiguity_scorer::AmbiguityScoringContext {
        candidate_entity_ids: Vec::new(),
        selected_entity_id: None,
        requires_target,
        is_verb_destructive: is_destructive,
        required_argument_names: required_arguments
            .iter()
            .map(|name| name.to_string())
            .collect(),
    }
}

/// `AmbiguityScorer` treats fully specified human intents as clear.
#[test]
fn ambiguity_scorer_treats_fully_specified_human_intents_as_clear() {
    let intent = IntentIR {
        target_object_ids: vec!["scene:42".to_string()],
        arguments: [(
            "name".to_string(),
            IntentArgumentValue::String("Boss".to_string()),
        )]
        .into_iter()
        .collect(),
        ..IntentIR::new(
            "scene.set_name",
            "Rename selected entity",
            IntentSource::Human,
        )
    };
    let score = crate::invocation::ambiguity_scorer::AmbiguityScorer::default()
        .score(&intent, &ambiguity_context(true, false, &["name"]));

    assert_eq!(score.score, 0.0);
    assert_eq!(
        score.level,
        crate::invocation::ambiguity_scorer::AmbiguityLevel::Clear
    );
    assert!(score.signals.is_empty());
}

/// `AmbiguityScorer` does not require a target for spawn capabilities.
#[test]
fn ambiguity_scorer_does_not_require_target_for_spawn_capabilities() {
    let intent = IntentIR::new("scene.spawn_entity", "Spawn entity", IntentSource::Human);
    let score = crate::invocation::ambiguity_scorer::AmbiguityScorer::default()
        .score(&intent, &ambiguity_context(false, false, &[]));

    assert_eq!(score.score, 0.0);
    assert_eq!(
        score.level,
        crate::invocation::ambiguity_scorer::AmbiguityLevel::Clear
    );
}

/// `AmbiguityScorer` raises high ambiguity for underspecified AI target edits.
#[test]
fn ambiguity_scorer_raises_high_for_underspecified_ai_target_edits() {
    let intent = IntentIR {
        confidence: 0.4,
        ..IntentIR::new("scene.set_name", "Rename it", IntentSource::Ai)
    };
    let score = crate::invocation::ambiguity_scorer::AmbiguityScorer::default()
        .score(&intent, &ambiguity_context(true, false, &["name"]));
    let kinds: std::collections::BTreeSet<_> =
        score.signals.iter().map(|signal| signal.kind).collect();

    use crate::invocation::ambiguity_scorer::AmbiguitySignalKind;
    assert_eq!(
        score.level,
        crate::invocation::ambiguity_scorer::AmbiguityLevel::High
    );
    assert!(kinds.contains(&AmbiguitySignalKind::AiLowConfidence));
    assert!(kinds.contains(&AmbiguitySignalKind::NoTarget));
    assert!(kinds.contains(&AmbiguitySignalKind::MissingRequiredArgument));
    assert!(kinds.contains(&AmbiguitySignalKind::NoEvidence));
}

/// `AmbiguityScorer` builds destructive confirmation questions.
#[test]
fn ambiguity_scorer_builds_destructive_confirmation_questions() {
    let intent = IntentIR {
        id: "delete-42".to_string(),
        target_object_ids: vec!["scene:42".to_string()],
        ..IntentIR::new(
            "scene.delete_entity",
            "Delete selected entity",
            IntentSource::Human,
        )
    };
    let scorer = crate::invocation::ambiguity_scorer::AmbiguityScorer::default();
    let score = scorer.score(&intent, &ambiguity_context(true, true, &[]));

    let question = scorer
        .make_question(
            &intent,
            &score,
            vec![
                crate::invocation::capability_invocation::ConfirmationOption::new(
                    "confirm", "Apply",
                ),
            ],
        )
        .expect("question");

    assert_eq!(
        score.level,
        crate::invocation::ambiguity_scorer::AmbiguityLevel::Low
    );
    assert_eq!(question.id, "ambiguity:delete-42");
    assert_eq!(
        question.kind,
        crate::invocation::capability_invocation::ConfirmationQuestionKind::ApproveDestructive
    );
    assert_eq!(
        question.severity,
        crate::invocation::capability_invocation::ConfirmationSeverity::Destructive
    );
    assert_eq!(question.ambiguity_score, score.score);
}

pub(crate) fn capability_context(
    scene: &SceneRuntime,
    source: IntentSource,
    confidence: f64,
) -> crate::invocation::capability_invocation_planning::CapabilityInvocationContext {
    crate::invocation::capability_invocation_planning::CapabilityInvocationContext::from_scene_runtime(
        scene,
        None,
        true,
        source,
        confidence,
        Vec::new(),
    )
}
