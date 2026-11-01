use diffuse_assets::{
    asset_pipeline::{
        MeshAnimation, MeshAnimationInterpolation, MeshAnimationPath, MeshAnimationSampler,
        MeshAsset,
    },
    asset_registry::AssetRegistry,
};
use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_scene::{
    media::animation::*,
    scene_bootstrap::AssetReferenceComponent,
    scripting::{RuntimeScriptDriver, RuntimeScriptPhaseContext},
};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Default)]
pub struct AnimationRuntime;

impl AnimationRuntime {
    pub fn new() -> Self {
        Self
    }

    pub fn tick(&mut self, context: &mut RuntimeScriptPhaseContext<'_>, delta_time: f64) {
        let mut seen = BTreeSet::new();
        let mut entities = Vec::new();
        for entity in context
            .entities_with::<AnimationGraphPlayer>()
            .into_iter()
            .chain(context.entities_with::<AnimationPlayer>())
        {
            if seen.insert(entity) {
                entities.push(entity);
            }
        }
        let mut palette_map = JointPaletteMap::default();
        for entity in entities {
            let Some(reference) = context.component::<AssetReferenceComponent>(entity) else {
                continue;
            };
            let Some(mesh) = AssetRegistry::shared().mesh_asset(reference.mesh_index) else {
                continue;
            };
            if mesh.animations.is_empty() {
                continue;
            }
            let pose = if let Some(mut player) = context.component::<AnimationGraphPlayer>(entity) {
                let pose = evaluate_graph(&mut player, &mesh, delta_time);
                context
                    .update_component::<AnimationGraphPlayer>(entity, |current| *current = player);
                pose
            } else if let Some(mut player) = context.component::<AnimationPlayer>(entity) {
                let pose = evaluate_single_clip(&mut player, &mesh, delta_time);
                context.update_component::<AnimationPlayer>(entity, |current| *current = player);
                pose
            } else {
                None
            };
            let Some(pose) = pose else {
                continue;
            };
            if mesh.nodes.is_empty() {
                continue;
            }
            let world = world_matrices(&pose, &mesh);
            if let Some(skin) = mesh.skins.first() {
                let matrices = skin
                    .joint_node_indices
                    .iter()
                    .enumerate()
                    .map(|(index, node)| {
                        let node_world = usize::try_from(*node)
                            .ok()
                            .and_then(|index| world.get(index))
                            .copied()
                            .unwrap_or(MATRIX_IDENTITY_FLOAT4X4);
                        let inverse_bind = skin
                            .inverse_bind_matrices
                            .get(index)
                            .copied()
                            .unwrap_or(MATRIX_IDENTITY_FLOAT4X4);
                        node_world * inverse_bind
                    })
                    .collect();
                palette_map
                    .palettes
                    .insert(entity, JointPalette::new(matrices));
            }
        }
        context.set_resource(palette_map);
    }
}

impl RuntimeScriptDriver for AnimationRuntime {
    fn run(&mut self, context: &mut RuntimeScriptPhaseContext<'_>) {
        let delta_time = context.delta_time_seconds();
        self.tick(context, delta_time);
    }
    fn reset(&mut self) {
        let _ = self;
    }
}

fn evaluate_single_clip(
    player: &mut AnimationPlayer,
    mesh: &MeshAsset,
    delta_time: f64,
) -> Option<AnimationPose> {
    let clip = select_clip(player.clip_name.as_deref(), mesh)?;
    if player.is_playing {
        player.time += delta_time * f64::from(player.speed);
    }
    let duration = clip_duration(clip);
    if duration > 0.0 {
        if player.loop_ {
            player.time = wrapped(player.time, duration);
        } else {
            player.time = swift_min(player.time, duration);
            if player.time >= duration {
                player.is_playing = false;
            }
        }
    }
    Some(sample_clip(clip, mesh, player.time, player.loop_))
}

fn evaluate_graph(
    player: &mut AnimationGraphPlayer,
    mesh: &MeshAsset,
    delta_time: f64,
) -> Option<AnimationPose> {
    let mut states = BTreeMap::new();
    for state in &player.graph.state_machine.states {
        states
            .entry(state.name.clone())
            .or_insert_with(|| state.clone());
    }
    if states.is_empty() {
        return None;
    }
    if player
        .active_state
        .as_ref()
        .and_then(|name| states.get(name))
        .is_none()
    {
        player.active_state = if states.contains_key(&player.graph.state_machine.initial_state) {
            Some(player.graph.state_machine.initial_state.clone())
        } else {
            player
                .graph
                .state_machine
                .states
                .first()
                .map(|state| state.name.clone())
        };
        player.active_time = 0.0;
        player.previous_state = None;
        player.previous_time = 0.0;
        player.transition_elapsed = 0.0;
        player.transition_duration = 0.0;
    }
    let active_name = player.active_state.clone()?;
    let active = states.get(&active_name)?;
    if player.is_playing {
        player.active_time += delta_time * f64::from(player.speed) * f64::from(active.speed);
        if let Some(previous) = player
            .previous_state
            .as_ref()
            .and_then(|name| states.get(name))
        {
            player.previous_time +=
                delta_time * f64::from(player.speed) * f64::from(previous.speed);
            player.transition_elapsed += delta_time;
        }
    }
    if player.previous_state.is_some()
        && (player.transition_duration <= 0.0
            || player.transition_elapsed >= player.transition_duration)
    {
        player.previous_state = None;
        player.previous_time = 0.0;
        player.transition_elapsed = 0.0;
        player.transition_duration = 0.0;
    }
    if player.previous_state.is_none()
        && let Some(transition) = player
            .graph
            .state_machine
            .transitions
            .iter()
            .find(|transition| {
                transition.from == active_name
                    && transition_condition_matches(transition, &player.parameters)
            })
        && states.contains_key(&transition.to)
    {
        player.previous_state = Some(active_name);
        player.previous_time = player.active_time;
        player.active_state = Some(transition.to.clone());
        player.active_time = 0.0;
        player.transition_elapsed = 0.0;
        player.transition_duration = transition.duration;
        if transition.duration <= 0.0 {
            player.previous_state = None;
            player.previous_time = 0.0;
        }
    }
    let current = states.get(player.active_state.as_ref()?)?;
    let current_pose = evaluate_state(current, player, mesh, player.active_time)?;
    let previous_pose = player
        .previous_state
        .as_ref()
        .and_then(|name| states.get(name))
        .and_then(|state| evaluate_state(state, player, mesh, player.previous_time));
    match previous_pose {
        Some(previous) if player.transition_duration > 0.0 => {
            let alpha = swift_min(
                swift_max(player.transition_elapsed / player.transition_duration, 0.0),
                1.0,
            ) as f32;
            Some(blend(&previous, &current_pose, alpha))
        }
        _ => Some(current_pose),
    }
}

fn evaluate_state(
    state: &AnimationState,
    player: &AnimationGraphPlayer,
    mesh: &MeshAsset,
    time: f64,
) -> Option<AnimationPose> {
    match &state.motion {
        AnimationMotion::Clip(name) => {
            let clip = select_clip(name.as_deref(), mesh)?;
            Some(sample_clip(
                clip,
                mesh,
                normalized(time, clip_duration(clip), state.loop_),
                state.loop_,
            ))
        }
        AnimationMotion::BlendSpace1D(name) => {
            let space = player
                .graph
                .blend_spaces_1d
                .iter()
                .find(|space| &space.name == name)?;
            evaluate_blend_space_1d(space, player, mesh, time, state.loop_)
        }
    }
}

fn evaluate_blend_space_1d(
    space: &AnimationBlendSpace1D,
    player: &AnimationGraphPlayer,
    mesh: &MeshAsset,
    time: f64,
    loop_: bool,
) -> Option<AnimationPose> {
    let mut samples: Vec<_> = space.samples.iter().collect();
    samples.sort_by(|a, b| {
        a.threshold
            .partial_cmp(&b.threshold)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let first = *samples.first()?;
    let value = player
        .parameters
        .get(&space.parameter)
        .copied()
        .unwrap_or(0.0);
    if value <= first.threshold {
        return sample_blend_sample(first, mesh, time, loop_);
    }
    let last = *samples.last()?;
    if value >= last.threshold {
        return sample_blend_sample(last, mesh, time, loop_);
    }
    for pair in samples.windows(2) {
        let (a, b) = (pair[0], pair[1]);
        if !(value >= a.threshold && value <= b.threshold) {
            continue;
        }
        let span = b.threshold - a.threshold;
        let alpha = if span > 0.0 {
            (value - a.threshold) / span
        } else {
            0.0
        };
        return Some(blend(
            &sample_blend_sample(a, mesh, time, loop_)?,
            &sample_blend_sample(b, mesh, time, loop_)?,
            alpha,
        ));
    }
    None
}

fn sample_blend_sample(
    sample: &AnimationBlendSample1D,
    mesh: &MeshAsset,
    time: f64,
    loop_: bool,
) -> Option<AnimationPose> {
    let clip = select_clip(sample.clip_name.as_deref(), mesh)?;
    Some(sample_clip(
        clip,
        mesh,
        normalized(time, clip_duration(clip), loop_),
        loop_,
    ))
}

fn transition_condition_matches(
    transition: &AnimationTransition,
    parameters: &BTreeMap<String, f32>,
) -> bool {
    let value = parameters
        .get(&transition.parameter)
        .copied()
        .unwrap_or(0.0);
    match transition.comparison {
        AnimationTransitionComparison::GreaterThan => value > transition.threshold,
        AnimationTransitionComparison::GreaterThanOrEqual => value >= transition.threshold,
        AnimationTransitionComparison::LessThan => value < transition.threshold,
        AnimationTransitionComparison::LessThanOrEqual => value <= transition.threshold,
        AnimationTransitionComparison::Equal => (value - transition.threshold).abs() <= 0.0001,
        AnimationTransitionComparison::NotEqual => (value - transition.threshold).abs() > 0.0001,
    }
}

fn select_clip<'a>(name: Option<&str>, mesh: &'a MeshAsset) -> Option<&'a MeshAnimation> {
    name.and_then(|name| {
        mesh.animations
            .iter()
            .find(|clip| clip.name.as_deref() == Some(name))
    })
    .or_else(|| mesh.animations.first())
}

fn sample_clip(clip: &MeshAnimation, mesh: &MeshAsset, time: f64, loop_: bool) -> AnimationPose {
    let mut pose = AnimationPose::bind_pose(mesh);
    let time = normalized(time, clip_duration(clip), loop_) as f32;
    for channel in &clip.channels {
        let Some(node) = channel
            .target_node_index
            .and_then(|node| usize::try_from(node).ok())
            .filter(|node| *node < mesh.nodes.len())
        else {
            continue;
        };
        let Some(sampler) = usize::try_from(channel.sampler_index)
            .ok()
            .and_then(|index| clip.samplers.get(index))
        else {
            continue;
        };
        match channel.path {
            MeshAnimationPath::Translation => pose.translations[node] = sample_vec3(sampler, time),
            MeshAnimationPath::Rotation => pose.rotations[node] = sample_quat(sampler, time),
            MeshAnimationPath::Scale => pose.scales[node] = sample_vec3(sampler, time),
            MeshAnimationPath::Weights => continue,
        }
    }
    pose
}

fn clip_duration(clip: &MeshAnimation) -> f64 {
    clip.samplers
        .iter()
        .filter_map(|sampler| sampler.input_times.last().copied())
        .reduce(|a, b| if a < b { b } else { a })
        .map(f64::from)
        .unwrap_or(0.0)
}
fn normalized(time: f64, duration: f64, loop_: bool) -> f64 {
    if !(duration > 0.0) {
        return time;
    }
    if loop_ {
        wrapped(time, duration)
    } else {
        swift_min(swift_max(time, 0.0), duration)
    }
}
fn wrapped(time: f64, duration: f64) -> f64 {
    if !(duration > 0.0) {
        return time;
    }
    let mut value = time % duration;
    if value < 0.0 {
        value += duration;
    }
    value
}
fn swift_min<T: PartialOrd>(a: T, b: T) -> T {
    if b < a { b } else { a }
}
fn swift_max<T: PartialOrd>(a: T, b: T) -> T {
    if a < b { b } else { a }
}

fn sample_vec3(sampler: &MeshAnimationSampler, time: f32) -> Float3 {
    let (i0, i1, alpha) = interval(&sampler.input_times, time);
    let v0 = sampler
        .output_values
        .get(i0)
        .copied()
        .unwrap_or(Float4::ZERO)
        .xyz();
    let v1 = sampler
        .output_values
        .get(i1)
        .copied()
        .unwrap_or(Float4::ZERO)
        .xyz();
    let alpha = if sampler.interpolation == MeshAnimationInterpolation::Step {
        0.0
    } else {
        alpha
    };
    v0 * (1.0 - alpha) + v1 * alpha
}
fn sample_quat(sampler: &MeshAnimationSampler, time: f32) -> Float4 {
    let (i0, i1, alpha) = interval(&sampler.input_times, time);
    let identity = Float4::new(0.0, 0.0, 0.0, 1.0);
    let q0 = sampler.output_values.get(i0).copied().unwrap_or(identity);
    let q1 = sampler.output_values.get(i1).copied().unwrap_or(identity);
    slerp(
        q0,
        q1,
        if sampler.interpolation == MeshAnimationInterpolation::Step {
            0.0
        } else {
            alpha
        },
    )
}
fn interval(times: &[f32], time: f32) -> (usize, usize, f32) {
    if times.len() <= 1 || time <= times[0] {
        return (0, 0, 0.0);
    }
    let last = times.len() - 1;
    if time >= times[last] {
        return (last, last, 0.0);
    }
    let (mut lo, mut hi) = (0, last);
    while hi - lo > 1 {
        let middle = (lo + hi) / 2;
        if times[middle] <= time {
            lo = middle;
        } else {
            hi = middle;
        }
    }
    let dt = times[hi] - times[lo];
    (
        lo,
        hi,
        if dt > 0.0 {
            (time - times[lo]) / dt
        } else {
            0.0
        },
    )
}
fn dot4(a: Float4, b: Float4) -> f32 {
    a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
}
fn norm_q(q: Float4) -> Float4 {
    let length = dot4(q, q).sqrt();
    if length > 1e-6 {
        q / length
    } else {
        Float4::new(0.0, 0.0, 0.0, 1.0)
    }
}
fn slerp(a: Float4, b: Float4, t: f32) -> Float4 {
    let mut cos_theta = dot4(a, b);
    let mut b2 = b;
    if cos_theta < 0.0 {
        b2 = -b2;
        cos_theta = -cos_theta;
    }
    if cos_theta > 0.9995 {
        return norm_q(a + (b2 - a) * t);
    }
    let theta = cos_theta.acos();
    let st = theta.sin();
    norm_q(a * (((1.0 - t) * theta).sin() / st) + b2 * ((t * theta).sin() / st))
}

#[derive(Clone, Debug, PartialEq)]
struct AnimationPose {
    translations: Vec<Float3>,
    rotations: Vec<Float4>,
    scales: Vec<Float3>,
}
impl AnimationPose {
    fn bind_pose(mesh: &MeshAsset) -> Self {
        Self {
            translations: mesh
                .nodes
                .iter()
                .map(|node| node.local_translation)
                .collect(),
            rotations: mesh.nodes.iter().map(|node| node.local_rotation).collect(),
            scales: mesh.nodes.iter().map(|node| node.local_scale).collect(),
        }
    }
}
fn blend(a: &AnimationPose, b: &AnimationPose, alpha: f32) -> AnimationPose {
    let mut result = a.clone();
    let t = swift_min(swift_max(alpha, 0.0), 1.0);
    for i in 0..a.translations.len().min(b.translations.len()) {
        result.translations[i] = a.translations[i] * (1.0 - t) + b.translations[i] * t;
        result.rotations[i] = slerp(a.rotations[i], b.rotations[i], t);
        result.scales[i] = a.scales[i] * (1.0 - t) + b.scales[i] * t;
    }
    result
}
fn world_matrices(pose: &AnimationPose, mesh: &MeshAsset) -> Vec<Float4x4> {
    // GLTF's parent-before-child order is preserved, including its fallback for an invalid parent.
    let mut world = vec![MATRIX_IDENTITY_FLOAT4X4; mesh.nodes.len()];
    for (i, node) in mesh.nodes.iter().enumerate() {
        let local = trs_matrix(pose.translations[i], pose.rotations[i], pose.scales[i]);
        world[i] = if let Some(parent) = node
            .parent_index
            .and_then(|index| usize::try_from(index).ok())
            .filter(|index| *index < world.len())
        {
            world[parent] * local
        } else {
            local
        };
    }
    world
}
fn trs_matrix(t: Float3, r: Float4, s: Float3) -> Float4x4 {
    let x2 = r.x * r.x;
    let y2 = r.y * r.y;
    let z2 = r.z * r.z;
    let xy = r.x * r.y;
    let xz = r.x * r.z;
    let yz = r.y * r.z;
    let wx = r.w * r.x;
    let wy = r.w * r.y;
    let wz = r.w * r.z;
    Float4x4::from_columns([
        Float4::new(
            (1.0 - 2.0 * (y2 + z2)) * s.x,
            2.0 * (xy + wz) * s.x,
            2.0 * (xz - wy) * s.x,
            0.0,
        ),
        Float4::new(
            2.0 * (xy - wz) * s.y,
            (1.0 - 2.0 * (x2 + z2)) * s.y,
            2.0 * (yz + wx) * s.y,
            0.0,
        ),
        Float4::new(
            2.0 * (xz + wy) * s.z,
            2.0 * (yz - wx) * s.z,
            (1.0 - 2.0 * (x2 + y2)) * s.z,
            0.0,
        ),
        Float4::new(t.x, t.y, t.z, 1.0),
    ])
}
