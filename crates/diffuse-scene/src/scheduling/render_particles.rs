//! The render-side particle pipeline: the per-frame GPU simulation batches and
//! the CPU flattening of live emitter pools into sorted `RenderParticle`s.
//!
//! Ported from `Engine/Sources/SceneRuntime/Scheduling/RenderParticles.swift`.
//!
//! `ParticleEmitter` state lives inside the ECS, so these are free functions
//! taking a `RuntimeWorld` instead of methods on `RuntimeWorldSchedule` (whose
//! fields are private). Ordering, budget semantics and the draw order of every
//! particle are identical to the Swift implementation.

use diffuse_math::simd::simd_compat::{
    Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4, simd_clamp_scalar, simd_cross, simd_dot,
    simd_length, simd_length_squared,
};

use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::particles::emitter::spawning::{transform_direction, transform_point};
use crate::particles::particle_scalability::{
    ParticleScalabilityPolicyResource, ParticleScalabilityResource,
    ParticleScalabilityStateResource,
};
use crate::particles::particle_stats::ParticleFrameStatsResource;
use crate::particles::particle_types::{
    Particle, ParticleAdvanceOptions, ParticleBlendMode, ParticleRenderAlignment,
    ParticleRenderMode, ParticleSimulationSpace, ParticleSortMode,
};
use crate::rendering::render_scene::{
    RenderCamera, RenderParticle, RenderParticleAppearance, RenderParticleShape,
    RenderParticleSimulationBatch,
};
use crate::runtime_world::RuntimeWorld;

/// Resolve this frame's advance options from the scalability resources and store
/// the derived scalability state back into the world.
pub fn particle_advance_options(world: &mut RuntimeWorld) -> ParticleAdvanceOptions {
    let base_options = world
        .resource::<ParticleScalabilityResource>()
        .unwrap_or_default()
        .advance_options();
    let policy = world
        .resource::<ParticleScalabilityPolicyResource>()
        .unwrap_or_else(ParticleScalabilityPolicyResource::disabled);
    let previous_stats = world
        .resource::<ParticleFrameStatsResource>()
        .unwrap_or_default();
    let previous_state = world
        .resource::<ParticleScalabilityStateResource>()
        .unwrap_or_default();
    let state = policy.updated_state(&previous_stats, previous_state);
    world.set_derived_resource(state);
    state.applying(base_options)
}

/// One GPU simulation batch per emitter that currently wants GPU simulation.
///
/// Batches are ordered by `renderSortPriority`, then by the emitter's raw entity
/// value so the order is stable across frames.
pub fn collect_particle_simulation_batches(
    world: &RuntimeWorld,
    camera: &RenderCamera,
) -> Vec<RenderParticleSimulationBatch> {
    let mut result: Vec<RenderParticleSimulationBatch> = Vec::new();
    for entity in world.entities_with::<ParticleEmitter>() {
        let Some(emitter) = world.component::<ParticleEmitter>(entity) else {
            continue;
        };
        if emitter.particles().is_empty() {
            continue;
        }
        let plan = emitter.gpu_simulation_plan();
        if !plan.uses_gpu() {
            continue;
        }
        let to_world = world
            .world_transform(entity)
            .map(|transform| transform.matrix)
            .unwrap_or(MATRIX_IDENTITY_FLOAT4X4);
        let can_render_on_gpu = can_render_emitter_particles_on_gpu(&emitter);
        let is_render_visible =
            can_render_on_gpu && is_emitter_visible_to_camera(&emitter, &to_world, camera);
        let distance_fade = if is_render_visible {
            render_distance_fade(&emitter, &to_world, camera.eye)
        } else {
            0.0
        };
        let camera_distance = emitter_camera_distance(&emitter, &to_world, camera.eye);
        let render_particle_limit = emitter.effective_max_rendered_particles(
            camera_distance,
            emitter.particles().len() as i64,
        );
        let render_on_gpu = can_render_on_gpu && distance_fade > 0.0 && render_particle_limit > 0;
        let render_alpha_scale = if render_on_gpu { distance_fade } else { 0.0 };
        let last_frame_stats = emitter.last_frame_stats();
        let frame_spawn_count = (emitter.last_frame_spawned_particles().len() as i64)
            .min(last_frame_stats.spawned_particle_count())
            .min(emitter.particles().len() as i64);
        let persisted_particle_count =
            (emitter.particles().len() as i64 - frame_spawn_count).max(0) as usize;
        let persisted_particles = emitter.particles()[..persisted_particle_count].to_vec();
        let spawn_start = emitter.last_frame_spawned_particles().len() - frame_spawn_count as usize;
        let spawn_particles = emitter.last_frame_spawned_particles()[spawn_start..].to_vec();
        let settings = &emitter.settings;

        result.push(RenderParticleSimulationBatch {
            emitter_entity: Some(entity),
            plan,
            particles: persisted_particles,
            spawn_particles,
            simulation_speed: settings.emission.simulation_speed.max(0.0),
            gravity: settings.forces.gravity,
            noise_strength: settings.forces.noise_strength.max(0.0),
            noise_scale: swift_max_f32(0.0001, settings.forces.noise_scale),
            noise_speed: settings.forces.noise_speed.max(0.0),
            noise_seed: settings.emission.seed,
            vector_field_mode: settings.forces.vector_field_mode,
            vector_field_direction: settings.forces.vector_field_direction,
            vector_field_strength: settings.forces.vector_field_strength.max(0.0),
            vector_field_scale: swift_max_f32(0.0001, settings.forces.vector_field_scale),
            vector_field_scroll_speed: settings.forces.vector_field_scroll_speed,
            force_mode: settings.forces.force_mode,
            force_center: settings.forces.force_center,
            force_axis: settings.forces.force_axis,
            force_radius: settings.forces.force_radius.max(0.0),
            force_strength: settings.forces.force_strength,
            force_falloff: settings.forces.force_falloff.max(0.0),
            collision_mode: settings.collision.collision_mode,
            collision_plane_y: settings.collision.collision_plane_y,
            collision_restitution: simd_clamp_scalar(
                settings.collision.collision_restitution,
                0.0,
                1.0,
            ),
            collision_damping: simd_clamp_scalar(settings.collision.collision_damping, 0.0, 1.0),
            render_on_gpu,
            world_transform: if settings.gpu_simulation.simulation_space
                == ParticleSimulationSpace::Local
            {
                to_world
            } else {
                MATRIX_IDENTITY_FLOAT4X4
            },
            uv_rect: Float4::new(0.0, 0.0, 1.0, 1.0),
            texture_sheet_columns: settings.texture_sheet.columns.max(1),
            texture_sheet_rows: settings.texture_sheet.rows.max(1),
            texture_sheet_frame_count: settings.texture_sheet.frame_count.max(1),
            texture_sheet_frame_rate: settings.texture_sheet.frame_rate.max(0.0),
            texture_sheet_playback_mode: settings.texture_sheet.playback_mode,
            texture_sheet_start_frame: settings.texture_sheet.start_frame.max(0),
            texture_sheet_frame_randomness: settings.texture_sheet.frame_randomness.max(0),
            start_size: settings.appearance.start_size.max(0.0),
            end_size: settings.appearance.end_size.max(0.0),
            size_curve: settings.appearance.size_curve.clone(),
            start_color: settings.appearance.start_color,
            end_color: settings.appearance.end_color,
            color_curve: settings.appearance.color_curve.clone(),
            uses_authored_appearance: true,
            appearance_palette: render_particle_appearance_palette(&emitter),
            blend_mode: settings.appearance.blend_mode,
            texture_path: normalized_particle_texture_path(
                &settings.texture_sheet.texture_path,
            ),
            render_alignment: settings.renderer.render_alignment,
            velocity_stretch_scale: settings.renderer.velocity_stretch_scale.max(0.0),
            velocity_stretch_max: settings.renderer.velocity_stretch_max.max(1.0),
            sort_mode: settings.renderer.sort_mode,
            render_sort_priority: settings.renderer.render_sort_priority,
            render_particle_limit,
            render_alpha_scale: simd_clamp_scalar(render_alpha_scale, 0.0, 1.0),
            trail_length: settings.trails.trail_length.max(0.0),
            trail_segments: settings.trails.trail_segments.max(0),
            trail_end_size_scale: settings.trails.trail_end_size_scale.max(0.0),
            trail_end_alpha_scale: simd_clamp_scalar(
                settings.trails.trail_end_alpha_scale,
                0.0,
                1.0,
            ),
        });
    }
    result.sort_by(|lhs, rhs| {
        if lhs.render_sort_priority != rhs.render_sort_priority {
            return lhs.render_sort_priority.cmp(&rhs.render_sort_priority);
        }
        let lhs_value = lhs
            .emitter_entity
            .map(|entity| entity.raw_value())
            .unwrap_or(0);
        let rhs_value = rhs
            .emitter_entity
            .map(|entity| entity.raw_value())
            .unwrap_or(0);
        lhs_value.cmp(&rhs_value)
    });
    result
}

/// The authored appearance plus every active rule's appearance, indexed by
/// `Particle.appearanceIndex`.
pub fn render_particle_appearance_palette(
    emitter: &ParticleEmitter,
) -> Vec<RenderParticleAppearance> {
    let settings = &emitter.settings;
    let mut palette = vec![
        make_render_particle_appearance(
            settings.appearance.start_size,
            settings.appearance.end_size,
            settings.appearance.start_color,
            settings.appearance.end_color,
        ),
        make_render_particle_appearance(
            settings.sub_emitters.legacy_start_size,
            settings.sub_emitters.legacy_end_size,
            settings.sub_emitters.legacy_start_color,
            settings.sub_emitters.legacy_end_color,
        ),
    ];
    palette.extend(settings.sub_emitters.rules.iter().map(|rule| {
        make_render_particle_appearance(
            rule.start_size,
            rule.end_size,
            rule.start_color,
            rule.end_color,
        )
    }));
    palette
}

pub fn can_render_emitter_particles_on_gpu(emitter: &ParticleEmitter) -> bool {
    if !emitter.gpu_simulation_plan().uses_gpu() {
        return false;
    }
    if emitter.settings.renderer.render_mode != ParticleRenderMode::Billboard {
        return false;
    }
    if emitter.settings.renderer.render_alignment != ParticleRenderAlignment::Billboard
        && emitter.settings.renderer.render_alignment != ParticleRenderAlignment::Velocity
    {
        return false;
    }
    if !(emitter.settings.texture_sheet.texture_asset_id.is_none()
        || emitter.settings.texture_sheet.texture_path.is_some())
    {
        return false;
    }
    true
}

/// The flattened, camera-sorted particle list for the render backend.
pub struct CollectedRenderParticles {
    pub particles: Vec<RenderParticle>,
    pub source_particle_count: i64,
    pub submitted_source_particle_count: i64,
}

/// Flattens every live `ParticleEmitter` pool into world-space billboard
/// particles for the render backend. Local-space particles are transformed by
/// the entity's world matrix; world-space particles are already stored in render
/// space. The result is sorted back-to-front for the camera so alpha blending
/// composites correctly.
pub fn collect_render_particles(
    world: &RuntimeWorld,
    camera: &RenderCamera,
) -> CollectedRenderParticles {
    let mut sortable_particles: Vec<SortableRenderParticle> = Vec::new();
    let mut next_source_order: i64 = 0;
    let mut source_particle_count: i64 = 0;
    let mut submitted_source_particle_count: i64 = 0;
    for entity in world.entities_with::<ParticleEmitter>() {
        let Some(emitter) = world.component::<ParticleEmitter>(entity) else {
            continue;
        };
        if emitter.particles().is_empty() {
            continue;
        }
        if can_render_emitter_particles_on_gpu(&emitter) {
            continue;
        }
        let to_world = world
            .world_transform(entity)
            .map(|transform| transform.matrix)
            .unwrap_or(MATRIX_IDENTITY_FLOAT4X4);
        if !is_emitter_visible_to_camera(&emitter, &to_world, camera) {
            continue;
        }
        let distance_fade = render_distance_fade(&emitter, &to_world, camera.eye);
        if distance_fade <= 0.0 {
            continue;
        }
        let camera_distance = emitter_camera_distance(&emitter, &to_world, camera.eye);
        let source_particles = render_source_particles(&emitter, camera_distance);
        source_particle_count += emitter.particles().len() as i64;
        submitted_source_particle_count += source_particles.len() as i64;
        if emitter.settings.renderer.render_mode == ParticleRenderMode::Ribbon {
            append_ribbon_particles(
                source_particles,
                &emitter,
                &to_world,
                distance_fade,
                camera.eye,
                &mut next_source_order,
                &mut sortable_particles,
            );
            continue;
        }
        let trail_segments = if emitter.settings.trails.trail_length > 0.0 {
            emitter.settings.trails.trail_segments.max(0)
        } else {
            0
        };
        sortable_particles.reserve(
            source_particles.len() * (1 + usize::try_from(trail_segments).unwrap_or(0)),
        );
        for particle in source_particles {
            let sample = render_particle_sample(particle, &emitter, &to_world);
            let uv_rect = emitter.texture_uv_rect(particle);
            let (alignment_axis, stretch) = render_alignment(&emitter, sample.velocity);
            let mut color = particle.color;
            color.w *= distance_fade;
            let base = make_render_particle(
                sample.position,
                particle.size,
                particle.rotation,
                color,
                color,
                uv_rect,
                alignment_axis,
                stretch,
                particle.size,
                particle.size,
                RenderParticleShape::SoftBillboard,
                0.0,
                0.0,
                emitter.settings.appearance.blend_mode,
                &emitter.settings.texture_sheet.texture_path,
            );
            append_sortable_particle(
                base.clone(),
                &emitter,
                camera.eye,
                particle.age,
                &mut next_source_order,
                &mut sortable_particles,
            );
            append_trail_particles(
                particle,
                &emitter,
                &base,
                sample.velocity,
                camera.eye,
                &mut next_source_order,
                &mut sortable_particles,
            );
        }
    }
    sortable_particles.sort_by(compare_sortable_particles);
    CollectedRenderParticles {
        particles: sortable_particles
            .into_iter()
            .map(|sortable| sortable.particle)
            .collect(),
        source_particle_count,
        submitted_source_particle_count,
    }
}

/// The portion of an emitter's live pool that fits this frame's render budget.
/// A zero budget submits nothing; otherwise the newest particles are kept.
pub fn render_source_particles(
    emitter: &ParticleEmitter,
    camera_distance: f32,
) -> &[Particle] {
    let budget =
        emitter.effective_max_rendered_particles(camera_distance, emitter.particles().len() as i64);
    let particles = emitter.particles();
    if budget <= 0 {
        return &particles[particles.len()..];
    }
    if budget >= particles.len() as i64 {
        return particles;
    }
    &particles[particles.len() - budget as usize..]
}

fn append_sortable_particle(
    particle: RenderParticle,
    emitter: &ParticleEmitter,
    camera_eye: Float3,
    age: f32,
    next_source_order: &mut i64,
    result: &mut Vec<SortableRenderParticle>,
) {
    let distance_squared = simd_length_squared(particle.position - camera_eye);
    result.push(SortableRenderParticle {
        particle,
        sort_mode: emitter.settings.renderer.sort_mode,
        sort_priority: emitter.settings.renderer.render_sort_priority,
        distance_squared,
        age: swift_max_f32(0.0, age),
        source_order: *next_source_order,
    });
    *next_source_order += 1;
}

fn compare_sortable_particles(
    lhs: &SortableRenderParticle,
    rhs: &SortableRenderParticle,
) -> std::cmp::Ordering {
    use std::cmp::Ordering;

    if lhs.sort_priority != rhs.sort_priority {
        return lhs.sort_priority.cmp(&rhs.sort_priority);
    }
    if lhs.sort_mode != rhs.sort_mode {
        return tie_break_sortable_particles(lhs, rhs);
    }

    match lhs.sort_mode {
        ParticleSortMode::DistanceDescending => {
            if lhs.distance_squared != rhs.distance_squared {
                if lhs.distance_squared > rhs.distance_squared {
                    return Ordering::Less;
                }
                if rhs.distance_squared > lhs.distance_squared {
                    return Ordering::Greater;
                }
                // A NaN distance makes Swift's `>` false; keep the order stable.
                return tie_break_sortable_particles(lhs, rhs);
            }
        }
        ParticleSortMode::DistanceAscending => {
            if lhs.distance_squared != rhs.distance_squared {
                if lhs.distance_squared < rhs.distance_squared {
                    return Ordering::Less;
                }
                if rhs.distance_squared < lhs.distance_squared {
                    return Ordering::Greater;
                }
                return tie_break_sortable_particles(lhs, rhs);
            }
        }
        ParticleSortMode::OldestFirst => {
            if lhs.age != rhs.age {
                if lhs.age > rhs.age {
                    return Ordering::Less;
                }
                if rhs.age > lhs.age {
                    return Ordering::Greater;
                }
                return tie_break_sortable_particles(lhs, rhs);
            }
        }
        ParticleSortMode::YoungestFirst => {
            if lhs.age != rhs.age {
                if lhs.age < rhs.age {
                    return Ordering::Less;
                }
                if rhs.age < lhs.age {
                    return Ordering::Greater;
                }
                return tie_break_sortable_particles(lhs, rhs);
            }
        }
    }
    tie_break_sortable_particles(lhs, rhs)
}

fn tie_break_sortable_particles(
    lhs: &SortableRenderParticle,
    rhs: &SortableRenderParticle,
) -> std::cmp::Ordering {
    use std::cmp::Ordering;

    if lhs.distance_squared != rhs.distance_squared {
        if lhs.distance_squared > rhs.distance_squared {
            return Ordering::Less;
        }
        if rhs.distance_squared > lhs.distance_squared {
            return Ordering::Greater;
        }
        return Ordering::Equal;
    }
    lhs.source_order.cmp(&rhs.source_order)
}

struct CameraBasis {
    forward: Float3,
    right: Float3,
    up: Float3,
}

struct RenderParticleSample {
    position: Float3,
    velocity: Float3,
}

struct RibbonControlPoint {
    particle: Particle,
    position: Float3,
    width: f32,
    color: Float4,
}

struct RibbonRenderSegment {
    start_position: Float3,
    end_position: Float3,
    start_width: f32,
    end_width: f32,
    start_color: Float4,
    end_color: Float4,
    sort_age: f32,
    uv_rect: Float4,
    texture_v_offset: f32,
    texture_v_scale: f32,
    run_id: i64,
}

struct SortableRenderParticle {
    particle: RenderParticle,
    sort_mode: ParticleSortMode,
    sort_priority: i64,
    distance_squared: f32,
    age: f32,
    source_order: i64,
}

fn is_emitter_visible_to_camera(
    emitter: &ParticleEmitter,
    to_world: &Float4x4,
    camera: &RenderCamera,
) -> bool {
    let radius = emitter.effective_render_bounds_radius();
    if !(radius > 0.0) {
        return true;
    }
    let center = transform_point(emitter.settings.shape.origin_offset, to_world);
    let basis = camera_basis(camera);
    let offset = center - camera.eye;
    let forward_distance = simd_dot(offset, basis.forward);

    if forward_distance + radius < camera.near {
        return false;
    }
    if camera.far > camera.near && forward_distance - radius > camera.far {
        return false;
    }

    let vertical_half_fov = swift_max_f32(
        0.001,
        swift_min_f32(std::f32::consts::PI * 0.49, camera.fov_y_radians * 0.5),
    );
    let vertical_half_extent =
        swift_max_f32(0.0, forward_distance) * (vertical_half_fov as f64).tan() as f32 + radius;
    let vertical_distance = simd_dot(offset, basis.up).abs();
    if vertical_distance > vertical_half_extent {
        return false;
    }
    let horizontal_half_extent = swift_max_f32(0.0, forward_distance)
        * (vertical_half_fov as f64).tan() as f32
        * swift_max_f32(0.001, camera.aspect_ratio)
        + radius;
    let horizontal_distance = simd_dot(offset, basis.right).abs();
    if horizontal_distance > horizontal_half_extent {
        return false;
    }
    true
}

fn camera_basis(camera: &RenderCamera) -> CameraBasis {
    let raw_forward = camera.target - camera.eye;
    let forward = normalized_or_default(raw_forward, Float3::new(0.0, 0.0, -1.0));
    let requested_up = normalized_or_default(camera.up, Float3::new(0.0, 1.0, 0.0));
    let mut right = simd_cross(forward, requested_up);
    if simd_length_squared(right) <= 0.000_001 {
        right = simd_cross(forward, Float3::new(1.0, 0.0, 0.0));
    }
    right = normalized_or_default(right, Float3::new(1.0, 0.0, 0.0));
    let up = normalized_or_default(simd_cross(right, forward), Float3::new(0.0, 1.0, 0.0));
    CameraBasis { forward, right, up }
}

fn render_distance_fade(
    emitter: &ParticleEmitter,
    to_world: &Float4x4,
    camera_eye: Float3,
) -> f32 {
    let renderer = &emitter.settings.renderer;
    if !(renderer.max_render_distance > 0.0) {
        return 1.0;
    }
    let origin = transform_point(emitter.settings.shape.origin_offset, to_world);
    let distance = simd_length(origin - camera_eye);
    if !(distance <= renderer.max_render_distance) {
        return 0.0;
    }
    if !(renderer.render_distance_fade_range > 0.0) {
        return 1.0;
    }
    let fade_range = swift_min_f32(renderer.render_distance_fade_range, renderer.max_render_distance);
    if !(fade_range > 0.0001) {
        return 1.0;
    }
    let fade_start = renderer.max_render_distance - fade_range;
    if !(distance > fade_start) {
        return 1.0;
    }
    simd_clamp_scalar((renderer.max_render_distance - distance) / fade_range, 0.0, 1.0)
}

fn emitter_camera_distance(
    emitter: &ParticleEmitter,
    to_world: &Float4x4,
    camera_eye: Float3,
) -> f32 {
    let origin = transform_point(emitter.settings.shape.origin_offset, to_world);
    simd_length(origin - camera_eye)
}

#[allow(clippy::too_many_arguments)]
fn append_trail_particles(
    particle: &Particle,
    emitter: &ParticleEmitter,
    base: &RenderParticle,
    world_velocity: Float3,
    camera_eye: Float3,
    next_source_order: &mut i64,
    result: &mut Vec<SortableRenderParticle>,
) {
    let trails = &emitter.settings.trails;
    if !(trails.trail_length > 0.0) || trails.trail_segments <= 0 || !(particle.size > 0.0) {
        return;
    }

    let speed = simd_length(world_velocity);
    if !(speed > 0.0001) {
        return;
    }

    let segment_count = trails.trail_segments;
    let step = world_velocity * (trails.trail_length / segment_count as f32);
    for index in 1..=segment_count {
        let t = index as f32 / segment_count as f32;
        let size_scale = 1.0 + (trails.trail_end_size_scale - 1.0) * t;
        let alpha_scale = 1.0 + (trails.trail_end_alpha_scale - 1.0) * t;
        let mut color = base.color;
        color.w *= alpha_scale;
        let size = swift_max_f32(0.0, base.size * size_scale);
        append_sortable_particle(
            make_render_particle(
                base.position - step * index as f32,
                size,
                base.rotation,
                color,
                color,
                base.uv_rect,
                base.alignment_axis,
                base.stretch,
                size,
                size,
                RenderParticleShape::SoftBillboard,
                0.0,
                0.0,
                base.blend_mode,
                &base.texture_path,
            ),
            emitter,
            camera_eye,
            particle.age,
            next_source_order,
            result,
        );
    }
}

#[allow(clippy::too_many_arguments)]
fn append_ribbon_particles(
    particles: &[Particle],
    emitter: &ParticleEmitter,
    to_world: &Float4x4,
    distance_fade: f32,
    camera_eye: Float3,
    next_source_order: &mut i64,
    result: &mut Vec<SortableRenderParticle>,
) {
    if particles.len() < 2 {
        return;
    }
    let trails = &emitter.settings.trails;

    let samples: Vec<(Particle, RenderParticleSample)> = particles
        .iter()
        .map(|particle| {
            (
                *particle,
                render_particle_sample(particle, emitter, to_world),
            )
        })
        .collect();
    let segment_lengths: Vec<f32> = samples
        .windows(2)
        .map(|pair| simd_length(pair[1].1.position - pair[0].1.position))
        .collect();
    let segment_count = 1.max(segment_lengths.len() as i64);
    let control_points: Vec<RibbonControlPoint> = samples
        .iter()
        .enumerate()
        .map(|(index, pair)| {
            let tail_normalized =
                1.0 - simd_clamp_scalar(index as f32 / segment_count as f32, 0.0, 1.0);
            let width_scale = trails.ribbon_width_scale
                * (1.0 + (trails.ribbon_tail_width_scale - 1.0) * tail_normalized);
            let alpha_scale =
                1.0 + (trails.ribbon_tail_alpha_scale - 1.0) * tail_normalized;
            let mut color = pair.0.color;
            color.w *= distance_fade * alpha_scale;
            RibbonControlPoint {
                particle: pair.0,
                position: pair.1.position,
                width: swift_max_f32(0.0, pair.0.size * width_scale),
                color,
            }
        })
        .collect();

    let subdivisions = trails.ribbon_smoothing_segments;
    let mut drafts: Vec<RibbonRenderSegment> = Vec::new();
    drafts.reserve((segment_lengths.len() as i64 * subdivisions).max(0) as usize);
    let mut ribbon_distance: f32 = 0.0;
    let mut run_id: i64 = 0;
    for index in 0..segment_lengths.len() {
        let length = segment_lengths[index];
        if !is_renderable_ribbon_segment(length, emitter) {
            ribbon_distance = 0.0;
            run_id += 1;
            continue;
        }

        let index_i64 = index as i64;
        let previous_position = connected_ribbon_control_position(
            index_i64 - 1,
            control_points[index].position,
            &segment_lengths,
            &control_points,
            emitter,
        );
        let next_position = connected_ribbon_control_position(
            index_i64 + 2,
            control_points[index + 1].position,
            &segment_lengths,
            &control_points,
            emitter,
        );
        for subdivision in 0..subdivisions {
            let t0 = subdivision as f32 / subdivisions as f32;
            let t1 = (subdivision + 1) as f32 / subdivisions as f32;
            let start_position = ribbon_interpolated_position(
                previous_position,
                control_points[index].position,
                control_points[index + 1].position,
                next_position,
                t0,
                subdivisions > 1,
            );
            let end_position = ribbon_interpolated_position(
                previous_position,
                control_points[index].position,
                control_points[index + 1].position,
                next_position,
                t1,
                subdivisions > 1,
            );
            let sub_length = simd_length(end_position - start_position);
            if !(sub_length > 0.0001) {
                continue;
            }
            let start_width = lerp_f32(
                control_points[index].width,
                control_points[index + 1].width,
                t0,
            );
            let end_width = lerp_f32(
                control_points[index].width,
                control_points[index + 1].width,
                t1,
            );
            let start_color = lerp4(
                control_points[index].color,
                control_points[index + 1].color,
                t0,
            );
            let end_color = lerp4(
                control_points[index].color,
                control_points[index + 1].color,
                t1,
            );
            let sort_age = lerp_f32(
                control_points[index].particle.age,
                control_points[index + 1].particle.age,
                (t0 + t1) * 0.5,
            );
            drafts.push(RibbonRenderSegment {
                start_position,
                end_position,
                start_width,
                end_width,
                start_color,
                end_color,
                sort_age,
                uv_rect: emitter.texture_uv_rect(&control_points[index].particle),
                texture_v_offset: trails.ribbon_texture_offset
                    + ribbon_distance * trails.ribbon_texture_tiling,
                texture_v_scale: sub_length * trails.ribbon_texture_tiling,
                run_id,
            });
            ribbon_distance += sub_length;
        }
    }

    let render_segment_lengths: Vec<f32> = drafts
        .iter()
        .map(|draft| simd_length(draft.end_position - draft.start_position))
        .collect();
    let run_ids: Vec<i64> = drafts.iter().map(|draft| draft.run_id).collect();
    result.reserve(drafts.len());
    for (index, draft) in drafts.iter().enumerate() {
        let length = render_segment_lengths[index];
        if !(length > 0.0001) {
            continue;
        }
        let width = swift_max_f32(0.0001, swift_max_f32(draft.start_width, draft.end_width));
        let start_overlap = ribbon_join_overlap(
            index as i64,
            index as i64 - 1,
            width,
            &render_segment_lengths,
            &run_ids,
            emitter,
        );
        let end_overlap = ribbon_join_overlap(
            index as i64,
            index as i64 + 1,
            width,
            &render_segment_lengths,
            &run_ids,
            emitter,
        );
        let direction = (draft.end_position - draft.start_position) / length;
        let render_length = length + start_overlap + end_overlap;
        let render_center = (draft.start_position + draft.end_position) * 0.5
            + direction * ((end_overlap - start_overlap) * 0.5);
        append_sortable_particle(
            make_render_particle(
                render_center,
                width,
                0.0,
                draft.start_color,
                draft.end_color,
                draft.uv_rect,
                direction,
                render_length / width,
                draft.start_width,
                draft.end_width,
                RenderParticleShape::RibbonSegment,
                draft.texture_v_offset,
                draft.texture_v_scale,
                emitter.settings.appearance.blend_mode,
                &emitter.settings.texture_sheet.texture_path,
            ),
            emitter,
            camera_eye,
            draft.sort_age,
            next_source_order,
            result,
        );
    }
}

fn ribbon_join_overlap(
    segment_index: i64,
    neighbor_index: i64,
    width: f32,
    segment_lengths: &[f32],
    run_ids: &[i64],
    emitter: &ParticleEmitter,
) -> f32 {
    let join_overlap_scale = emitter.settings.trails.ribbon_join_overlap_scale;
    if !(join_overlap_scale > 0.0)
        || !index_contains(segment_lengths.len(), segment_index)
        || !index_contains(segment_lengths.len(), neighbor_index)
        || !index_contains(run_ids.len(), segment_index)
        || !index_contains(run_ids.len(), neighbor_index)
        || run_ids[segment_index as usize] != run_ids[neighbor_index as usize]
    {
        return 0.0;
    }
    let length = segment_lengths[segment_index as usize];
    let neighbor_length = segment_lengths[neighbor_index as usize];
    if !(length > 0.0001) || !(neighbor_length > 0.0001) {
        return 0.0;
    }
    (width * join_overlap_scale)
        .min(length * 0.5)
        .min(neighbor_length * 0.5)
}

fn connected_ribbon_control_position(
    point_index: i64,
    fallback: Float3,
    segment_lengths: &[f32],
    control_points: &[RibbonControlPoint],
    emitter: &ParticleEmitter,
) -> Float3 {
    if !index_contains(control_points.len(), point_index) {
        return fallback;
    }
    let index = point_index as usize;
    if index < control_points.len() - 1
        && !is_renderable_ribbon_segment(segment_lengths[index], emitter)
    {
        return fallback;
    }
    if index > 0 && !is_renderable_ribbon_segment(segment_lengths[index - 1], emitter) {
        return fallback;
    }
    control_points[index].position
}

fn ribbon_interpolated_position(
    previous: Float3,
    start: Float3,
    end: Float3,
    next: Float3,
    t: f32,
    smooth: bool,
) -> Float3 {
    if !smooth {
        return lerp3(start, end, t);
    }
    let t2 = t * t;
    let t3 = t2 * t;
    let term0 = start * 2.0;
    let term1 = (end - previous) * t;
    let term2_a = previous * 2.0;
    let term2_b = start * 5.0;
    let term2_c = end * 4.0;
    let term2_base = term2_a - term2_b + term2_c - next;
    let term2 = term2_base * t2;
    let term3_a = start * 3.0;
    let term3_b = end * 3.0;
    let term3_base = -previous + term3_a - term3_b + next;
    let term3 = term3_base * t3;
    (term0 + term1 + term2 + term3) * 0.5
}

fn lerp_f32(start: f32, end: f32, t: f32) -> f32 {
    start + (end - start) * t
}

fn lerp3(start: Float3, end: Float3, t: f32) -> Float3 {
    start + (end - start) * t
}

fn lerp4(start: Float4, end: Float4, t: f32) -> Float4 {
    start + (end - start) * t
}

fn is_renderable_ribbon_segment(length: f32, emitter: &ParticleEmitter) -> bool {
    if !(length > 0.0001) {
        return false;
    }
    let max_segment_length = emitter.settings.trails.ribbon_max_segment_length;
    if max_segment_length > 0.0 && length > max_segment_length {
        return false;
    }
    true
}

fn render_alignment(emitter: &ParticleEmitter, world_velocity: Float3) -> (Float3, f32) {
    if emitter.settings.renderer.render_alignment != ParticleRenderAlignment::Velocity {
        return (Float3::ZERO, 1.0);
    }
    let speed = simd_length(world_velocity);
    if !(speed > 0.0001) {
        return (Float3::ZERO, 1.0);
    }
    let stretch = swift_min_f32(
        emitter.settings.renderer.velocity_stretch_max,
        swift_max_f32(
            1.0,
            1.0 + speed * emitter.settings.renderer.velocity_stretch_scale,
        ),
    );
    (world_velocity / speed, stretch)
}

fn render_particle_sample(
    particle: &Particle,
    emitter: &ParticleEmitter,
    to_world: &Float4x4,
) -> RenderParticleSample {
    match emitter.settings.gpu_simulation.simulation_space {
        ParticleSimulationSpace::Local => RenderParticleSample {
            position: transform_point(particle.position, to_world),
            velocity: transform_direction(particle.velocity, to_world),
        },
        ParticleSimulationSpace::World => RenderParticleSample {
            position: particle.position,
            velocity: particle.velocity,
        },
    }
}

/// Swift's `RenderParticle.init`, expanded so the struct stays constructible
/// without depending on the rendering batch's initializer signature.
#[allow(clippy::too_many_arguments)]
fn make_render_particle(
    position: Float3,
    size: f32,
    rotation: f32,
    color: Float4,
    end_color: Float4,
    uv_rect: Float4,
    alignment_axis: Float3,
    stretch: f32,
    start_size: f32,
    end_size: f32,
    shape: RenderParticleShape,
    texture_v_offset: f32,
    texture_v_scale: f32,
    blend_mode: ParticleBlendMode,
    texture_path: &Option<String>,
) -> RenderParticle {
    RenderParticle {
        position,
        size,
        rotation,
        color,
        end_color,
        uv_rect,
        alignment_axis,
        stretch: swift_max_f32(1.0, stretch),
        start_size: swift_max_f32(0.0, start_size),
        end_size: swift_max_f32(0.0, end_size),
        shape,
        texture_v_offset,
        texture_v_scale: swift_max_f32(0.0, texture_v_scale),
        blend_mode,
        texture_path: normalized_particle_texture_path(texture_path),
    }
}

fn make_render_particle_appearance(
    start_size: f32,
    end_size: f32,
    start_color: Float4,
    end_color: Float4,
) -> RenderParticleAppearance {
    RenderParticleAppearance {
        start_size: swift_max_f32(0.0, start_size),
        end_size: swift_max_f32(0.0, end_size),
        start_color,
        end_color,
    }
}

/// Trimmed, non-empty texture paths only — `normalizedParticleTexturePath`.
fn normalized_particle_texture_path(path: &Option<String>) -> Option<String> {
    let path = path.as_ref()?.trim();
    if path.is_empty() {
        return None;
    }
    Some(path.to_string())
}

fn index_contains(count: usize, index: i64) -> bool {
    index >= 0 && (index as usize) < count
}

fn normalized_or_default(vector: Float3, fallback: Float3) -> Float3 {
    let length_squared = simd_length_squared(vector);
    if !(length_squared > 0.000_001) {
        return fallback;
    }
    vector / length_squared.sqrt()
}

#[inline]
fn swift_max_f32(x: f32, y: f32) -> f32 {
    if y >= x { y } else { x }
}

#[inline]
fn swift_min_f32(x: f32, y: f32) -> f32 {
    if y < x { y } else { x }
}
