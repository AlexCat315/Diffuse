//! Validate supported scene features before allocating resources or acquiring
//! a drawable.

use crate::core::frame::render_camera_matrices::RenderCameraMatrices;
use crate::core::frame::render_packet::RenderPacket;
use crate::core::frame::viewport_target_allocation::ViewportTargetAllocation;
use crate::core::particles::particle_gpu_data::GPUParticleInstance;
use crate::core::particles::particle_instance_gpu_data::{
    GPUParticleAppearanceData, GPUParticleSimulationInstanceUniforms,
    GPUParticleSortPrepareUniforms,
};
use crate::core::particles::particle_simulation_gpu_data::{
    GPUParticleSimulationState, GPUParticleSimulationUniforms,
};
use crate::core::render_settings::RenderSettings;
use cove_graphics::rhi::RhiError;
use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4};
use diffuse_scene::rendering::render_scene::RenderParticleSimulationBatch;

pub enum NativePacketValidation {}

impl NativePacketValidation {
    pub fn validate(packet: &RenderPacket) -> Result<RenderCameraMatrices, RhiError> {
        if packet.drawable_size.width == 0
            || packet.drawable_size.height == 0
            || packet.drawable_size.width > ViewportTargetAllocation::MAX_DIMENSION
            || packet.drawable_size.height > ViewportTargetAllocation::MAX_DIMENSION
            || (packet.render_settings.viewport.grid_enabled
                && !packet.render_settings.viewport.grid_spacing.is_finite())
        {
            return Err(RhiError::invalid_argument(
                "native viewport must be nonempty",
            ));
        }
        Self::validate_simulation(packet)?;
        Self::validate_capability_dependencies(&packet.render_settings)?;
        let settings = &packet.render_settings;
        let style = &settings.stylization.style;
        if settings.stylization.enabled {
            let values = [
                style.toon_thresholds,
                style.toon_levels,
                style.ink_wash_color,
                Float4::new(
                    style.paper_grain_strength,
                    style.rim_strength,
                    style.material_bias_strength,
                    style.outline_width,
                ),
            ];
            if !values
                .iter()
                .all(|vector| (0..4).all(|lane| Self::float4_lane(*vector, lane).is_finite()))
            {
                return Err(RhiError::invalid_argument("non-finite stylized input"));
            }
        }
        let scene = &packet.scene;
        if scene.particles.len() > u32::MAX as usize
            || !scene
                .particles
                .iter()
                .all(|particle| GPUParticleInstance::from_particle(particle).is_finite())
        {
            return Err(RhiError::invalid_argument(
                "non-finite or oversized particle input",
            ));
        }
        if !Self::finite3(scene.camera.eye)
            || !Self::finite3(scene.camera.target)
            || !Self::finite3(scene.camera.up)
            || !Self::finite3(scene.environment.ambient_color)
            || !scene.environment.ambient_intensity.is_finite()
            || scene.environment.ambient_intensity < 0.0
            || !scene.environment.exposure.is_finite()
            || scene.environment.exposure < 0.0
            || !scene.lights.iter().all(|light| {
                Self::finite3(light.position)
                    && Self::finite3(light.direction)
                    && Self::finite3(light.color)
                    && light.intensity.is_finite()
                    && light.intensity >= 0.0
                    && light.range.is_finite()
                    && light.range >= 0.0
                    && light.spot_inner_angle_radians.is_finite()
                    && light.spot_outer_angle_radians.is_finite()
            })
            || !packet.render_settings.shadows.depth_bias.is_finite()
            || !packet.render_settings.shadows.strength.is_finite()
            || !packet
                .render_settings
                .shadows
                .directional_cascade_split_lambda
                .is_finite()
        {
            return Err(RhiError::invalid_argument(
                "non-finite or negative native lighting input",
            ));
        }
        let matrices = RenderCameraMatrices::make(scene, packet.drawable_size);
        if !Self::finite_matrix(matrices.view_projection)
            || !scene.environment.exposure.is_finite()
            || !scene
                .instances
                .iter()
                .all(|instance| Self::finite_matrix(instance.transform))
        {
            return Err(RhiError::invalid_argument(
                "non-finite camera or instance transform",
            ));
        }
        for instance in &scene.instances {
            let alpha_cutoff_finite = instance
                .material
                .alpha_cutoff
                .is_none_or(|cutoff| cutoff.is_finite());
            if !Self::finite3(instance.color_tint)
                || !alpha_cutoff_finite
                || !instance.material.base_color_factor.x.is_finite()
                || !instance.material.base_color_factor.y.is_finite()
                || !instance.material.base_color_factor.z.is_finite()
                || !instance.material.base_color_factor.w.is_finite()
            {
                return Err(RhiError::invalid_argument("non-finite material color"));
            }
        }
        if !packet.joint_palette_map.palettes.values().all(|palette| {
            palette.matrices.len() <= u32::MAX as usize
                && palette
                    .matrices
                    .iter()
                    .all(|matrix| Self::finite_matrix(*matrix))
        }) {
            return Err(RhiError::invalid_argument(
                "non-finite or oversized joint palette",
            ));
        }
        Ok(matrices)
    }

    fn finite_matrix(matrix: Float4x4) -> bool {
        (0..4).all(|column| (0..4).all(|lane| Self::column_lane(matrix, column, lane).is_finite()))
    }

    fn column_lane(matrix: Float4x4, column: usize, lane: usize) -> f32 {
        let column = matrix.columns[column];
        match lane {
            0 => column.x,
            1 => column.y,
            2 => column.z,
            _ => column.w,
        }
    }

    fn float4_lane(vector: Float4, lane: usize) -> f32 {
        match lane {
            0 => vector.x,
            1 => vector.y,
            2 => vector.z,
            _ => vector.w,
        }
    }

    fn finite3(vector: Float3) -> bool {
        vector.x.is_finite() && vector.y.is_finite() && vector.z.is_finite()
    }

    fn validate_simulation(packet: &RenderPacket) -> Result<(), RhiError> {
        if !(packet.delta_time as f32).is_finite()
            || !(packet.simulation_time_seconds as f32).is_finite()
        {
            return Err(RhiError::invalid_argument(
                "non-finite particle simulation time",
            ));
        }
        let mut emitters = std::collections::HashSet::new();
        let mut instances = packet.scene.particles.len() as i64;
        for batch in &packet.scene.particle_simulation_batches {
            if !batch.plan.uses_gpu() || batch.particle_count() <= 0 {
                continue;
            }
            let delta_time_scaled = packet.delta_time as f32 * batch.simulation_speed;
            let simulation_uniforms = GPUParticleSimulationUniforms::from_batch(
                batch,
                delta_time_scaled,
                packet.simulation_time_seconds as f32,
                batch.particle_count(),
                batch.plan.particle_capacity * 2,
            );
            if !(batch.plan.particle_capacity > 0
                && batch.plan.particle_capacity
                    <= GPUParticleSimulationUniforms::MAXIMUM_EXACT_PARTICLE_COUNT)
                || ![
                    batch.simulation_speed,
                    batch.noise_strength,
                    batch.noise_scale,
                    batch.noise_speed,
                    batch.vector_field_strength,
                    batch.vector_field_scale,
                    batch.vector_field_scroll_speed,
                    batch.force_radius,
                    batch.force_strength,
                    batch.force_falloff,
                    batch.collision_plane_y,
                    batch.collision_restitution,
                    batch.collision_damping,
                ]
                .iter()
                .all(|value| value.is_finite())
                || !Self::finite_matrix(batch.world_transform)
                || !simulation_uniforms.is_finite()
                || !batch
                    .particles
                    .iter()
                    .all(|particle| GPUParticleSimulationState::from_particle(particle).is_finite())
                || !batch
                    .spawn_particles
                    .iter()
                    .all(|particle| GPUParticleSimulationState::from_particle(particle).is_finite())
            {
                return Err(RhiError::invalid_argument(
                    "non-finite or oversized particle simulation input",
                ));
            }
            if let Some(emitter) = batch.emitter_entity.map(|entity| entity.raw_value())
                && !emitters.insert(emitter)
            {
                return Err(RhiError::invalid_argument(
                    "duplicate particle simulation emitter",
                ));
            }
            if batch.render_on_gpu {
                Self::validate_particle_rendering(batch)?;
                let (count, overflow) = batch
                    .render_particle_count()
                    .checked_mul(batch.render_instance_multiplier());
                if overflow {
                    return Err(RhiError::invalid_argument(
                        "simulated particle instance count exceeds the Float32 ABI",
                    ));
                }
                let (total, addition_overflow) = instances.checked_add(count);
                if addition_overflow
                    || total > GPUParticleSimulationUniforms::MAXIMUM_EXACT_PARTICLE_COUNT
                {
                    return Err(RhiError::invalid_argument(
                        "simulated particle instance count exceeds the Float32 ABI",
                    ));
                }
                instances = total;
            }
        }
        Ok(())
    }

    /// Express the genuine capability dependencies up front so a bad combination
    /// fails with an actionable message instead of a cryptic resource failure
    /// mid-frame. Screen-space and temporal effects operate in the linear HDR
    /// colour space, which the PBR path provides.
    fn validate_capability_dependencies(settings: &RenderSettings) -> Result<(), RhiError> {
        if settings.shading.pbr {
            return Ok(());
        }
        let hdr_effects: [(&str, bool); 4] = [
            ("SSAO", settings.post_processing.ssao),
            ("SSR", settings.post_processing.ssr),
            ("TAA", settings.post_processing.taa),
            ("Bloom", settings.post_processing.bloom),
        ];
        if let Some((name, _)) = hdr_effects.iter().find(|(_, enabled)| *enabled) {
            return Err(RhiError::unsupported_feature(format!(
                "{name} requires HDR rendering; enable the PBR path (enablePBR: true). \
                 For antialiasing in an LDR scene use enableFXAA instead."
            )));
        }
        Ok(())
    }

    fn validate_particle_rendering(batch: &RenderParticleSimulationBatch) -> Result<(), RhiError> {
        let limit = GPUParticleSimulationUniforms::MAXIMUM_EXACT_PARTICLE_COUNT;
        let (frames, overflow) = batch
            .texture_sheet_columns
            .checked_mul(batch.texture_sheet_rows)
            .ok_or_else(|| {
                RhiError::invalid_argument(
                    "non-finite or oversized simulated-particle rendering input",
                )
            })?;
        let appearance = GPUParticleAppearanceData::from_batch(batch);
        let instance_uniforms =
            GPUParticleSimulationInstanceUniforms::from_batch(batch, 0, &appearance);
        if !(batch.trail_segments >= 0 && batch.trail_segments < limit)
            || ![
                batch.texture_sheet_columns,
                batch.texture_sheet_rows,
                batch.texture_sheet_frame_count,
            ]
            .iter()
            .all(|value| *value > 0 && *value <= limit)
            || ![
                batch.texture_sheet_start_frame,
                batch.texture_sheet_frame_randomness,
            ]
            .iter()
            .all(|value| *value >= 0 && *value <= limit)
            || overflow
            || frames > u32::MAX as i64
            || ![
                batch.start_size,
                batch.end_size,
                batch.texture_sheet_frame_rate,
                batch.velocity_stretch_scale,
                batch.velocity_stretch_max,
                batch.render_alpha_scale,
                batch.trail_length,
                batch.trail_end_size_scale,
                batch.trail_end_alpha_scale,
            ]
            .iter()
            .all(|value| value.is_finite())
            || !instance_uniforms.is_finite()
            || !appearance.is_finite()
        {
            return Err(RhiError::invalid_argument(
                "non-finite or oversized simulated-particle rendering input",
            ));
        }
        Ok(())
    }
}
