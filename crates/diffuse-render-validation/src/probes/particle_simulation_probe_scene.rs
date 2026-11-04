use super::{particle_probe_scene::ParticleProbeScene, post_probe_scene::PostProbeScene};
use diffuse_math::simd::simd_compat::{Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::{RenderDrawableSize, RenderPacket};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::particles::emitter::{
    particle_emitter::ParticleEmitter, particle_emitter_settings::ParticleEmitterSettings,
};
use diffuse_scene::particles::particle_curve::ParticleCurve;
use diffuse_scene::particles::particle_types::{
    Particle, ParticleBlendMode, ParticleCollisionMode, ParticleForceMode, ParticleRenderAlignment,
    ParticleSimulationBackend, ParticleSortMode, ParticleTextureSheetPlaybackMode,
    ParticleVectorFieldMode,
};
use diffuse_scene::rendering::render_scene::{
    RenderParticleAppearance, RenderParticleSimulationBatch,
};

pub enum ParticleSimulationProbeScene {}
impl ParticleSimulationProbeScene {
    pub fn packet(size: RenderDrawableSize, frame: i64) -> RenderPacket {
        let mut packet = PostProbeScene::packet(size, frame);
        packet.delta_time = 1.0 / 60.0;
        packet.simulation_time_seconds = frame as f64 / 60.0;
        packet.scene.particles = (0..32).map(ParticleProbeScene::ribbon).collect();
        packet.scene.particle_simulation_batches =
            vec![Self::batch(11, 37, frame), Self::batch(22, 255, frame)];
        if frame % 2 == 1 {
            packet.scene.particle_simulation_batches.reverse();
        }
        packet
    }

    fn batch(emitter: u64, group: i64, frame: i64) -> RenderParticleSimulationBatch {
        let mut settings = ParticleEmitterSettings::default();
        settings.emission.max_particles = 1024;
        settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::GpuRequired;
        settings.gpu_simulation.workgroup_size = group;
        let plan = ParticleEmitter::new(settings).gpu_simulation_plan();
        let particles = (0..1024)
            .map(|index| {
                let x = (index % 32) as f32 * 0.24 - 3.8;
                let z = (index / 32) as f32 * 0.25 - 4.0;
                Particle::new(
                    Float3::new(x, 1.7 + x.sin() * 0.6, z),
                    Float3::new(0.03, 0.04, -0.02),
                    (index % 17) as f32 * 0.02,
                    10.0,
                    0.8,
                    0.0,
                    0.2,
                    0.13,
                    Float4::new(0.5, 0.8, 1.0, 0.6),
                    0,
                    (index % 2) as u16,
                    index as u16,
                )
            })
            .collect();
        let mut world_transform = MATRIX_IDENTITY_FLOAT4X4;
        world_transform.columns[3].x = if emitter == 11 { -2.0 } else { 2.0 };
        let mut batch = RenderParticleSimulationBatch {
            emitter_entity: Some(EntityID::from_raw_value(emitter)),
            plan,
            particles,
            spawn_particles: Vec::new(),
            simulation_speed: 0.4,
            gravity: Float3::ZERO,
            noise_strength: 0.02,
            noise_scale: 0.8,
            noise_speed: 0.4,
            noise_seed: emitter,
            vector_field_mode: ParticleVectorFieldMode::Curl,
            vector_field_direction: Float3::new(0.0, 1.0, 0.0),
            vector_field_strength: 0.02,
            vector_field_scale: 1.0,
            vector_field_scroll_speed: 0.0,
            force_mode: ParticleForceMode::Vortex,
            force_center: Float3::ZERO,
            force_axis: Float3::new(0.0, 1.0, 0.0),
            force_radius: 0.0,
            force_strength: 0.01,
            force_falloff: 0.5,
            collision_mode: ParticleCollisionMode::None,
            collision_plane_y: 0.0,
            collision_restitution: 0.5,
            collision_damping: 0.0,
            render_on_gpu: true,
            world_transform,
            uv_rect: Float4::new(0.0, 0.0, 1.0, 1.0),
            texture_sheet_columns: 1,
            texture_sheet_rows: 1,
            texture_sheet_frame_count: 1,
            texture_sheet_frame_rate: 0.0,
            texture_sheet_playback_mode: ParticleTextureSheetPlaybackMode::Automatic,
            texture_sheet_start_frame: 0,
            texture_sheet_frame_randomness: 0,
            start_size: 1.0,
            end_size: 1.0,
            size_curve: ParticleCurve::EaseOut,
            start_color: Float4::new(1.0, 1.0, 1.0, 1.0),
            end_color: Float4::new(1.0, 1.0, 1.0, 1.0),
            color_curve: ParticleCurve::EaseInOut,
            uses_authored_appearance: true,
            appearance_palette: vec![
                RenderParticleAppearance::new(
                    0.15,
                    0.06,
                    Float4::new(1.2, 0.4, 0.2, 0.6),
                    Float4::new(0.1, 0.4, 1.0, 0.1),
                ),
                RenderParticleAppearance::new(
                    0.12,
                    0.04,
                    Float4::new(0.3, 1.0, 0.7, 0.5),
                    Float4::new(0.8, 0.2, 1.0, 0.1),
                ),
            ],
            blend_mode: if emitter == 11 {
                ParticleBlendMode::Alpha
            } else {
                ParticleBlendMode::Additive
            },
            texture_path: None,
            render_alignment: ParticleRenderAlignment::Velocity,
            velocity_stretch_scale: 2.0,
            velocity_stretch_max: 3.0,
            sort_mode: if emitter == 11 {
                ParticleSortMode::DistanceDescending
            } else {
                ParticleSortMode::OldestFirst
            },
            render_sort_priority: 0,
            render_particle_limit: 0,
            render_alpha_scale: 1.0,
            trail_length: 0.3,
            trail_segments: 2,
            trail_end_size_scale: 0.2,
            trail_end_alpha_scale: 0.1,
        };
        if frame > 0 && frame % 48 == 0 {
            batch.spawn_particles = vec![Particle::new(
                Float3::new(0.0, 3.0, 0.0),
                Float3::ZERO,
                0.0,
                10.0,
                1.0,
                0.0,
                0.0,
                1.0,
                Float4::new(1.0, 1.0, 1.0, 0.5),
                0,
                0,
                0,
            )];
        }
        batch
    }
}
