//! Ported from `Engine/Tests/ScriptRuntimeTests/AnimationRuntimeTests.swift`.
//!
//! Swift's `MeshAsset(name:vertices:indices:nodes:skins:animations:)` is a
//! memberwise initializer with defaulted `materials`/`textures`/`submeshes`; the
//! Rust struct has no `Default`, so [`mesh_asset`] names every field.
//! `MeshSkin(jointNodeIndices:inverseBindMatrices:)` becomes
//! `MeshSkin { name: None, joint_node_indices, inverse_bind_matrices }`.
//!
//! Swift's `SceneRuntime().runScriptDriver(AnimationRuntime(), deltaTime:)` is
//! `run_script_driver(&mut AnimationRuntime, dt)` — the driver is passed mutably
//! for the frame rather than being stored on the runtime.
//!
//! `AssetRegistry.shared.registerForTesting(_:at:)` is
//! `AssetRegistry::shared().register_for_testing(mesh, index)` and takes an
//! `i64`; [`RegisteredMesh`] stands in for the `defer { reset() }` blocks.

use std::collections::BTreeMap;

use diffuse_assets::asset_pipeline::{
    MeshAnimation, MeshAnimationChannel, MeshAnimationInterpolation, MeshAnimationPath,
    MeshAnimationSampler, MeshAsset, MeshNode, MeshSkin,
};
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::{
    AnimationBlendSample1D, AnimationBlendSpace1D, AnimationGraph, AnimationGraphPlayer,
    AnimationMotion, AnimationPlayer, AnimationState, AnimationStateMachine, AnimationTransition,
    AnimationTransitionComparison, JointPaletteMap,
};
use diffuse_scene::scene_bootstrap::AssetReferenceComponent;
use diffuse_scene::scene_runtime::SceneRuntime;

use crate::controllers::animation_runtime::AnimationRuntime;

/// The shared base index from Swift's `testMeshBase`.
const TEST_MESH_BASE: i64 = 200;

/// Swift's `SceneRuntime()`; the Rust runtime takes its component registry.
fn scene() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

/// `MeshAsset(name:vertices:indices:nodes:skins:animations:)` with Swift's
/// defaulted empty `materials`/`textures`/`submeshes`.
fn mesh_asset(
    name: &str,
    nodes: Vec<MeshNode>,
    skins: Vec<MeshSkin>,
    animations: Vec<MeshAnimation>,
) -> MeshAsset {
    MeshAsset {
        vertices: Vec::new(),
        indices: Vec::new(),
        name: name.to_string(),
        materials: Vec::new(),
        textures: Vec::new(),
        nodes,
        skins,
        animations,
        submeshes: Vec::new(),
    }
}

/// `MeshNode(name: "root")`.
fn root_node() -> MeshNode {
    MeshNode {
        name: Some("root".into()),
        ..MeshNode::default()
    }
}

/// `MeshSkin(jointNodeIndices:inverseBindMatrices:)`.
fn single_joint_skin() -> MeshSkin {
    MeshSkin {
        name: None,
        joint_node_indices: vec![0],
        inverse_bind_matrices: vec![diffuse_math::simd::simd_compat::MATRIX_IDENTITY_FLOAT4X4],
    }
}

fn translation_channel() -> MeshAnimationChannel {
    MeshAnimationChannel {
        sampler_index: 0,
        target_node_index: Some(0),
        path: MeshAnimationPath::Translation,
    }
}

/// `makeOneJointMesh(clipDuration:)`.
fn one_joint_mesh(clip_duration: f32) -> MeshAsset {
    let sampler = MeshAnimationSampler::new(
        vec![0.0, clip_duration],
        vec![
            diffuse_math::simd::simd_compat::Float4::new(0.0, 0.0, 0.0, 0.0),
            diffuse_math::simd::simd_compat::Float4::new(1.0, 0.0, 0.0, 0.0),
        ],
        MeshAnimationInterpolation::Linear,
    );
    let clip = MeshAnimation {
        name: Some("walk".into()),
        samplers: vec![sampler],
        channels: vec![translation_channel()],
    };
    mesh_asset(
        "test_skinned",
        vec![root_node()],
        vec![single_joint_skin()],
        vec![clip],
    )
}

/// `makeConstantTranslationClip(name:x:)`.
fn constant_translation_clip(name: &str, x: f32) -> MeshAnimation {
    let sampler = MeshAnimationSampler::new(
        vec![0.0, 1.0],
        vec![
            diffuse_math::simd::simd_compat::Float4::new(x, 0.0, 0.0, 0.0),
            diffuse_math::simd::simd_compat::Float4::new(x, 0.0, 0.0, 0.0),
        ],
        MeshAnimationInterpolation::Linear,
    );
    MeshAnimation {
        name: Some(name.to_string()),
        samplers: vec![sampler],
        channels: vec![translation_channel()],
    }
}

/// `makeLocomotionMesh()`: idle at x=0 and run at x=2.
fn locomotion_mesh() -> MeshAsset {
    mesh_asset(
        "locomotion",
        vec![root_node()],
        vec![single_joint_skin()],
        vec![
            constant_translation_clip("idle", 0.0),
            constant_translation_clip("run", 2.0),
        ],
    )
}

/// `AssetReferenceComponent(assetID:name:relativePath:absolutePath:kind:meshIndex:)`.
fn asset_reference(mesh_index: i64) -> AssetReferenceComponent {
    AssetReferenceComponent::new(
        format!("test:{mesh_index}"),
        "test",
        "test.gltf",
        "/test.gltf",
        "gltf",
        mesh_index,
    )
}

/// `makeScene(meshIndex:)`: an entity with the default player and the reference.
fn make_scene(mesh_index: i64) -> (SceneRuntime, EntityID) {
    let mut runtime = scene();
    let entity = runtime.create_entity();
    runtime.set_component(AnimationPlayer::default(), entity);
    runtime.set_component(asset_reference(mesh_index), entity);
    (runtime, entity)
}

/// Registers a mesh in the shared registry for the duration of one case.
struct RegisteredMesh;

impl RegisteredMesh {
    fn new(mesh: MeshAsset, index: i64) -> Self {
        AssetRegistry::shared().register_for_testing(mesh, index);
        Self
    }
}

impl Drop for RegisteredMesh {
    fn drop(&mut self) {
        AssetRegistry::shared().reset();
    }
}

/// A `AnimationPlayer` with Swift's memberwise defaults for the unlisted fields.
fn player(clip_name: Option<&str>, loop_: bool, is_playing: bool, time: f64) -> AnimationPlayer {
    AnimationPlayer::new(clip_name.map(str::to_string), 1.0, loop_, is_playing, time)
}

/// A graph player with Swift's defaults for the playback fields.
fn graph_player(graph: AnimationGraph, parameters: &[(&str, f32)]) -> AnimationGraphPlayer {
    AnimationGraphPlayer::new(
        graph,
        parameters
            .iter()
            .map(|(key, value)| ((*key).to_string(), *value))
            .collect::<BTreeMap<_, _>>(),
        None,
        None,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        true,
    )
}

/// `animation time advances each tick when isPlaying is true`
#[test]
fn time_advances_when_playing() {
    let idx = TEST_MESH_BASE;
    let _registered = RegisteredMesh::new(one_joint_mesh(1.0), idx);

    let (mut runtime, entity) = make_scene(idx);
    runtime.set_component(player(None, true, true, 0.0), entity);

    runtime.run_script_driver(&mut AnimationRuntime::new(), 0.1);

    let player = runtime
        .component::<AnimationPlayer>(entity)
        .expect("the player survives the tick");
    assert!(player.time > 0.0);
}

/// `animation time does not advance when isPlaying is false`
#[test]
fn time_does_not_advance_when_paused() {
    let idx = TEST_MESH_BASE + 1;
    let _registered = RegisteredMesh::new(one_joint_mesh(1.0), idx);

    let (mut runtime, entity) = make_scene(idx);
    runtime.set_component(player(None, true, false, 0.5), entity);

    runtime.run_script_driver(&mut AnimationRuntime::new(), 0.1);

    let player = runtime
        .component::<AnimationPlayer>(entity)
        .expect("the player survives the tick");
    assert_eq!(player.time, 0.5);
}

/// `looping clip wraps time at clip duration`
#[test]
fn looping_clip_wraps_time() {
    let idx = TEST_MESH_BASE + 2;
    let _registered = RegisteredMesh::new(one_joint_mesh(1.0), idx);

    let (mut runtime, entity) = make_scene(idx);
    runtime.set_component(player(None, true, true, 0.95), entity);

    runtime.run_script_driver(&mut AnimationRuntime::new(), 0.1);

    let time = runtime
        .component::<AnimationPlayer>(entity)
        .map(|player| player.time)
        .unwrap_or(1.0);
    assert!(time < 0.2);
}

/// `non-looping clip clamps and stops at end`
#[test]
fn non_looping_clip_stops_at_end() {
    let idx = TEST_MESH_BASE + 3;
    let _registered = RegisteredMesh::new(one_joint_mesh(1.0), idx);

    let (mut runtime, entity) = make_scene(idx);
    runtime.set_component(player(None, false, true, 0.98), entity);

    runtime.run_script_driver(&mut AnimationRuntime::new(), 0.1);

    let player = runtime
        .component::<AnimationPlayer>(entity)
        .expect("the player survives the tick");
    assert!(!player.is_playing);
    assert!(player.time >= 1.0);
}

/// `JointPaletteMap resource is written after tick for entity with skin`
#[test]
fn joint_palette_written_for_skinned_entity() {
    let idx = TEST_MESH_BASE + 4;
    let _registered = RegisteredMesh::new(one_joint_mesh(1.0), idx);

    let (mut runtime, entity) = make_scene(idx);
    runtime.set_component(player(None, true, true, 0.0), entity);

    runtime.run_script_driver(&mut AnimationRuntime::new(), 0.1);

    let palette = runtime
        .resource::<JointPaletteMap>()
        .expect("the palette map is written");
    let entry = palette.palette(entity).expect("the entity has a palette");
    assert!(!entry.matrices.is_empty());
}

/// `entity without AnimationPlayer is skipped and palette has no entry`
#[test]
fn entity_without_player_is_skipped() {
    let idx = TEST_MESH_BASE + 5;
    let _registered = RegisteredMesh::new(one_joint_mesh(1.0), idx);

    let mut runtime = scene();
    let entity = runtime.create_entity();
    runtime.set_component(asset_reference(idx), entity);

    runtime.run_script_driver(&mut AnimationRuntime::new(), 0.1);

    assert!(
        runtime
            .resource::<JointPaletteMap>()
            .and_then(|palette| palette.palette(entity).cloned())
            .is_none()
    );
}

/// `clipName selects named clip over first clip`
#[test]
fn clip_name_selects_named_clip() {
    let idx = TEST_MESH_BASE + 6;
    let sampler = MeshAnimationSampler::new(
        vec![0.0, 2.0],
        vec![
            diffuse_math::simd::simd_compat::Float4::new(0.0, 0.0, 0.0, 0.0),
            diffuse_math::simd::simd_compat::Float4::new(0.0, 2.0, 0.0, 0.0),
        ],
        MeshAnimationInterpolation::Linear,
    );
    let mesh = mesh_asset(
        "hero",
        vec![root_node()],
        vec![single_joint_skin()],
        vec![
            MeshAnimation {
                name: Some("idle".into()),
                samplers: vec![sampler.clone()],
                channels: vec![translation_channel()],
            },
            MeshAnimation {
                name: Some("run".into()),
                samplers: vec![sampler],
                channels: vec![translation_channel()],
            },
        ],
    );
    let _registered = RegisteredMesh::new(mesh, idx);

    let (mut runtime, entity) = make_scene(idx);
    runtime.set_component(player(Some("run"), true, true, 0.0), entity);

    runtime.run_script_driver(&mut AnimationRuntime::new(), 0.1);

    assert!(
        runtime
            .component::<AnimationPlayer>(entity)
            .map(|player| player.time)
            .unwrap_or(0.0)
            > 0.0
    );
    assert!(
        runtime
            .resource::<JointPaletteMap>()
            .and_then(|palette| palette.palette(entity).cloned())
            .is_some()
    );
}

/// `runScriptDriver drives AnimationRuntime and writes JointPaletteMap to scene`
#[test]
fn run_script_driver_writes_palette_map() {
    let idx = TEST_MESH_BASE + 7;
    let _registered = RegisteredMesh::new(one_joint_mesh(1.0), idx);

    let (mut runtime, entity) = make_scene(idx);
    runtime.set_component(player(None, true, true, 0.0), entity);

    runtime.run_script_driver(&mut AnimationRuntime::new(), 0.016);

    assert!(
        runtime
            .resource::<JointPaletteMap>()
            .and_then(|palette| palette.palette(entity).cloned())
            .is_some()
    );
}

/// `1D blend space mixes clips by parameter and writes blended palette`
#[test]
fn blend_space_1d_mixes_clips() {
    let idx = TEST_MESH_BASE + 8;
    let _registered = RegisteredMesh::new(locomotion_mesh(), idx);

    let mut runtime = scene();
    let entity = runtime.create_entity();
    runtime.set_component(asset_reference(idx), entity);
    let graph = AnimationGraph::new(
        vec![AnimationBlendSpace1D::new(
            "locomotion",
            "speed",
            vec![
                AnimationBlendSample1D::new(Some("idle".into()), 0.0),
                AnimationBlendSample1D::new(Some("run".into()), 1.0),
            ],
        )],
        AnimationStateMachine::new(
            "Locomotion",
            vec![AnimationState::new(
                "Locomotion",
                AnimationMotion::BlendSpace1D("locomotion".into()),
                1.0,
                true,
            )],
            Vec::new(),
        ),
    );
    runtime.set_component(graph_player(graph, &[("speed", 0.25)]), entity);

    runtime.run_script_driver(&mut AnimationRuntime::new(), 0.016);

    let matrix = runtime.resource::<JointPaletteMap>().and_then(|palette| {
        palette
            .palette(entity)
            .and_then(|p| p.matrices.first().copied())
    });
    let x = matrix.map(|matrix| matrix.columns[3].x).unwrap_or(-1.0);
    assert!((x - 0.5).abs() < 0.0001);
}

/// `state machine transitions crossfade between state motions`
#[test]
fn state_machine_transition_crossfades() {
    let idx = TEST_MESH_BASE + 9;
    let _registered = RegisteredMesh::new(locomotion_mesh(), idx);

    let mut runtime = scene();
    let entity = runtime.create_entity();
    runtime.set_component(asset_reference(idx), entity);
    let graph = AnimationGraph::new(
        Vec::new(),
        AnimationStateMachine::new(
            "Idle",
            vec![
                AnimationState::new("Idle", AnimationMotion::Clip(None), 1.0, true),
                AnimationState::new("Run", AnimationMotion::Clip(Some("run".into())), 1.0, true),
            ],
            vec![AnimationTransition::new(
                "Idle",
                "Run",
                "speed",
                AnimationTransitionComparison::GreaterThan,
                0.5,
                1.0,
            )],
        ),
    );
    runtime.set_component(graph_player(graph, &[("speed", 1.0)]), entity);

    runtime.run_script_driver(&mut AnimationRuntime::new(), 0.016);
    let player = runtime
        .component::<AnimationGraphPlayer>(entity)
        .expect("the graph player survives the tick");
    assert_eq!(player.active_state.as_deref(), Some("Run"));
    assert_eq!(player.previous_state.as_deref(), Some("Idle"));

    runtime.run_script_driver(&mut AnimationRuntime::new(), 0.5);

    let player = runtime
        .component::<AnimationGraphPlayer>(entity)
        .expect("the graph player survives the tick");
    let matrix = runtime.resource::<JointPaletteMap>().and_then(|palette| {
        palette
            .palette(entity)
            .and_then(|p| p.matrices.first().copied())
    });
    let x = matrix.map(|matrix| matrix.columns[3].x).unwrap_or(-1.0);
    assert_eq!(player.active_state.as_deref(), Some("Run"));
    assert_eq!(player.previous_state.as_deref(), Some("Idle"));
    assert!((x - 1.0).abs() < 0.0001);
}
