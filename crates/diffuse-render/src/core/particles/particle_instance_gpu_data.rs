//! GPU instance-conversion, sort and appearance data for particle batches.
//!
//! Ported from
//! `Engine/Sources/RenderBackend/Core/Particles/ParticleInstanceGPUData.swift`.
//! Layouts match `ParticleSimToInstanceUniforms`/`ParticleAppearance`/
//! `ParticleCurveKeyframe` in `particle_sim_to_instance.slang`,
//! `ParticleSortPrepareUniforms` in `particle_sort_prepare.slang`,
//! `ParticleSortBitonicUniforms` and `ParticleSortItem` in
//! `particle_sort_common.slang`.

use diffuse_math::simd::simd_compat::{Float2, Float3, Float4, Float4x4, UInt4};
use diffuse_scene::particles::particle_types::{
    ParticleRenderAlignment, ParticleSortMode, ParticleTextureSheetPlaybackMode,
};
use diffuse_scene::rendering::render_scene::RenderParticleSimulationBatch;

/// Layout matches `ParticleSimToInstanceUniforms` in `particle_sim_to_instance.wgsl`.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleSimulationInstanceUniforms {
    pub world_transform: Float4x4,
    /// x: particle count, y: base render instance, z: source start index, w: appearance count.
    pub params: Float4,
    pub uv_rect: Float4,
    /// x: columns, y: rows, z: frame count, w: frame rate.
    pub texture_sheet: Float4,
    /// x: alignment mode (0 billboard, 1 velocity), y: velocity stretch scale, z: max stretch, w: alpha scale.
    pub render_params: Float4,
    /// x: trail segments, y: trail length, z: trail end size scale, w: trail end alpha scale.
    pub trail_params: Float4,
    /// x: playback mode, y: start frame, z: random frame range, w: reserved.
    pub texture_sheet_playback: Float4,
    /// x/y reserved, z: size curve mode, w: size curve constant.
    pub appearance_size: Float4,
    /// Fallback start color when no appearance palette is authored.
    pub appearance_start_color: Float4,
    /// Fallback end color when no appearance palette is authored.
    pub appearance_end_color: Float4,
    /// x: color curve mode, y: color curve constant, z/w reserved.
    pub appearance_color_curve: Float4,
    /// x: size keyframe offset, y: size keyframe count, z: color keyframe offset, w: color keyframe count.
    pub curve_keyframes: Float4,
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<GPUParticleSimulationInstanceUniforms>() == 240);
const _: () = assert!(core::mem::align_of::<GPUParticleSimulationInstanceUniforms>() == 16);

impl GPUParticleSimulationInstanceUniforms {
    /// `isFinite` — every float lane of the struct is finite. Swift reads the
    /// struct's bytes as `Float`; the Rust equivalent walks every field
    /// (16 columns of the matrix + 11 float4 fields = 60 lanes).
    pub fn is_finite(&self) -> bool {
        let lanes: [f32; 60] = {
            let mut lanes = [0.0f32; 60];
            let mut offset = 0usize;
            let mut push = |value: Float4, lanes: &mut [f32; 60], offset: &mut usize| {
                lanes[*offset] = value.x;
                lanes[*offset + 1] = value.y;
                lanes[*offset + 2] = value.z;
                lanes[*offset + 3] = value.w;
                *offset += 4;
            };
            for column in &self.world_transform.columns {
                push(*column, &mut lanes, &mut offset);
            }
            push(self.params, &mut lanes, &mut offset);
            push(self.uv_rect, &mut lanes, &mut offset);
            push(self.texture_sheet, &mut lanes, &mut offset);
            push(self.render_params, &mut lanes, &mut offset);
            push(self.trail_params, &mut lanes, &mut offset);
            push(self.texture_sheet_playback, &mut lanes, &mut offset);
            push(self.appearance_size, &mut lanes, &mut offset);
            push(self.appearance_start_color, &mut lanes, &mut offset);
            push(self.appearance_end_color, &mut lanes, &mut offset);
            push(self.appearance_color_curve, &mut lanes, &mut offset);
            push(self.curve_keyframes, &mut lanes, &mut offset);
            lanes
        };
        lanes.iter().all(|value| value.is_finite())
    }

    /// `init(batch:baseInstance:appearance:)`.
    pub fn from_batch(
        batch: &RenderParticleSimulationBatch,
        base_instance: i64,
        appearance: &GPUParticleAppearanceData,
    ) -> Self {
        let playback: f32 = match batch.texture_sheet_playback_mode {
            ParticleTextureSheetPlaybackMode::Automatic => 0.0,
            ParticleTextureSheetPlaybackMode::Lifetime => 1.0,
            ParticleTextureSheetPlaybackMode::PlayOnce => 2.0,
            ParticleTextureSheetPlaybackMode::Loop => 3.0,
            ParticleTextureSheetPlaybackMode::SingleFrame => 4.0,
        };
        GPUParticleSimulationInstanceUniforms {
            world_transform: batch.world_transform,
            params: Float4::new(
                batch.render_particle_count() as f32,
                base_instance as f32,
                batch.render_particle_start_index() as f32,
                appearance.appearances.len() as f32,
            ),
            uv_rect: batch.uv_rect,
            texture_sheet: Float4::new(
                batch.texture_sheet_columns as f32,
                batch.texture_sheet_rows as f32,
                batch.texture_sheet_frame_count as f32,
                batch.texture_sheet_frame_rate,
            ),
            render_params: Float4::new(
                if batch.render_alignment == ParticleRenderAlignment::Velocity {
                    1.0
                } else {
                    0.0
                },
                batch.velocity_stretch_scale,
                batch.velocity_stretch_max,
                batch.render_alpha_scale,
            ),
            trail_params: Float4::new(
                batch.trail_segments.max(0) as f32,
                batch.trail_length,
                batch.trail_end_size_scale,
                batch.trail_end_alpha_scale,
            ),
            texture_sheet_playback: Float4::new(
                playback,
                batch.texture_sheet_start_frame as f32,
                batch.texture_sheet_frame_randomness as f32,
                0.0,
            ),
            appearance_size: Float4::new(
                0.0,
                0.0,
                appearance.size_curve.mode_constant.x,
                appearance.size_curve.mode_constant.y,
            ),
            appearance_start_color: batch.start_color,
            appearance_end_color: batch.end_color,
            appearance_color_curve: Float4::new(
                appearance.color_curve.mode_constant.x,
                appearance.color_curve.mode_constant.y,
                if batch.uses_authored_appearance {
                    1.0
                } else {
                    0.0
                },
                0.0,
            ),
            curve_keyframes: Float4::new(
                appearance.size_curve.keyframe_range.x,
                appearance.size_curve.keyframe_range.y,
                appearance.color_curve.keyframe_range.x,
                appearance.color_curve.keyframe_range.y,
            ),
        }
    }
}

/// Layout matches `ParticleAppearance` in `particle_sim_to_instance.wgsl`.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleAppearance {
    /// x: start size, y: end size, z/w reserved.
    pub size: Float4,
    pub start_color: Float4,
    pub end_color: Float4,
}

impl GPUParticleAppearance {
    pub fn new(size: Float4, start_color: Float4, end_color: Float4) -> Self {
        GPUParticleAppearance {
            size,
            start_color,
            end_color,
        }
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<GPUParticleAppearance>() == 48);
const _: () = assert!(core::mem::align_of::<GPUParticleAppearance>() == 16);

/// Layout matches `ParticleCurveKeyframe` in `particle_sim_to_instance.wgsl`.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleCurveKeyframe {
    /// x: normalized time, y: value, z/w reserved.
    pub time_value: Float4,
}

impl GPUParticleCurveKeyframe {
    pub fn new(time_value: Float4) -> Self {
        GPUParticleCurveKeyframe { time_value }
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<GPUParticleCurveKeyframe>() == 16);
const _: () = assert!(core::mem::align_of::<GPUParticleCurveKeyframe>() == 16);

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleCurveEncoding {
    pub mode_constant: Float2,
    pub keyframe_range: Float2,
}

impl GPUParticleCurveEncoding {
    pub fn new(mode_constant: Float2, keyframe_range: Float2) -> Self {
        GPUParticleCurveEncoding {
            mode_constant,
            keyframe_range,
        }
    }

    /// `GPUParticleCurveEncoding.encode(_:keyframes:)` — appends the selected
    /// keyframes to `keyframes` and returns the range encoding.
    pub fn encode(
        curve: &diffuse_scene::particles::particle_curve::ParticleCurve,
        keyframes: &mut Vec<GPUParticleCurveKeyframe>,
    ) -> Self {
        use diffuse_scene::particles::particle_curve::ParticleCurve;
        match curve {
            ParticleCurve::Constant(value) => {
                GPUParticleCurveEncoding::new(Float2::new(1.0, *value), Float2::ZERO)
            }
            ParticleCurve::Linear => {
                GPUParticleCurveEncoding::new(Float2::new(2.0, 0.0), Float2::ZERO)
            }
            ParticleCurve::EaseIn => {
                GPUParticleCurveEncoding::new(Float2::new(3.0, 0.0), Float2::ZERO)
            }
            ParticleCurve::EaseOut => {
                GPUParticleCurveEncoding::new(Float2::new(4.0, 0.0), Float2::ZERO)
            }
            ParticleCurve::EaseInOut => {
                GPUParticleCurveEncoding::new(Float2::new(5.0, 0.0), Float2::ZERO)
            }
            ParticleCurve::Keyframes(frames) => {
                if frames.is_empty() {
                    return GPUParticleCurveEncoding::new(Float2::new(2.0, 0.0), Float2::ZERO);
                }
                // Swift sorts `(offset, element)` pairs by time, breaking ties
                // by the original offset — a stable sort by time.
                let mut sorted: Vec<(
                    usize,
                    &diffuse_scene::particles::particle_curve::ParticleCurveKeyframe,
                )> = frames.iter().enumerate().collect();
                sorted.sort_by(|lhs, rhs| {
                    if lhs.1.time == rhs.1.time {
                        lhs.0.cmp(&rhs.0)
                    } else {
                        lhs.1
                            .time
                            .partial_cmp(&rhs.1.time)
                            .unwrap_or(std::cmp::Ordering::Equal)
                    }
                });
                let offset = keyframes.len();
                let remaining = GPUParticleAppearanceData::KEYFRAME_CAPACITY.saturating_sub(offset);
                if remaining == 0 {
                    return GPUParticleCurveEncoding::new(Float2::new(0.0, 0.0), Float2::ZERO);
                }
                let mut selected: Vec<
                    &diffuse_scene::particles::particle_curve::ParticleCurveKeyframe,
                > = sorted
                    .iter()
                    .take(remaining)
                    .map(|(_, frame)| *frame)
                    .collect();
                if sorted.len() > remaining
                    && let Some((_, last)) = sorted.last()
                    && !selected.is_empty()
                {
                    let last = *last;
                    let length = selected.len();
                    selected[length - 1] = last;
                }
                for frame in selected {
                    keyframes.push(GPUParticleCurveKeyframe::new(Float4::new(
                        frame.time,
                        frame.value,
                        0.0,
                        0.0,
                    )));
                }
                let selected_count = keyframes.len() - offset;
                GPUParticleCurveEncoding::new(
                    Float2::new(6.0, 0.0),
                    Float2::new(offset as f32, selected_count as f32),
                )
            }
        }
    }
}

/// Layout matches `ParticleSortPrepareUniforms` in `particle_sort_prepare.wgsl`.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleSortPrepareUniforms {
    pub world_transform: Float4x4,
    /// x: render particle count, y: source start index, z: sort mode, w: padded sort capacity.
    pub params: Float4,
    /// xyz: camera eye used by distance sort modes.
    pub sort_params: Float4,
}

impl GPUParticleSortPrepareUniforms {
    pub fn new(world_transform: Float4x4, params: Float4, sort_params: Float4) -> Self {
        GPUParticleSortPrepareUniforms {
            world_transform,
            params,
            sort_params,
        }
    }

    /// `init(batch:cameraEye:capacity:)`.
    pub fn from_batch(
        batch: &RenderParticleSimulationBatch,
        camera_eye: Float3,
        capacity: i64,
    ) -> Self {
        let mode: f32 = match batch.sort_mode {
            ParticleSortMode::DistanceDescending => 0.0,
            ParticleSortMode::DistanceAscending => 1.0,
            ParticleSortMode::OldestFirst => 2.0,
            ParticleSortMode::YoungestFirst => 3.0,
        };
        GPUParticleSortPrepareUniforms::new(
            batch.world_transform,
            Float4::new(
                batch.render_particle_count() as f32,
                batch.render_particle_start_index() as f32,
                mode,
                capacity as f32,
            ),
            Float4::new(camera_eye.x, camera_eye.y, camera_eye.z, 0.0),
        )
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<GPUParticleSortPrepareUniforms>() == 96);
const _: () = assert!(core::mem::align_of::<GPUParticleSortPrepareUniforms>() == 16);

/// Layout matches `ParticleSortBitonicUniforms` in `particle_sort_bitonic.wgsl`.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleSortBitonicUniforms {
    /// x: sort capacity, y: bitonic k, z: bitonic j.
    pub params: UInt4,
}

impl GPUParticleSortBitonicUniforms {
    pub fn new(params: UInt4) -> Self {
        GPUParticleSortBitonicUniforms { params }
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<GPUParticleSortBitonicUniforms>() == 16);
const _: () = assert!(core::mem::align_of::<GPUParticleSortBitonicUniforms>() == 16);

/// Layout matches `ParticleSortItem` in the particle sort WGSL shaders.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleSortItem {
    pub key: f32,
    pub index: u32,
    pub _padding0: u32,
    pub _padding1: u32,
}

impl GPUParticleSortItem {
    /// Swift's memberwise init; both paddings default to 0.
    pub fn new(key: f32, index: u32) -> Self {
        GPUParticleSortItem {
            key,
            index,
            _padding0: 0,
            _padding1: 0,
        }
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<GPUParticleSortItem>() == 16);
const _: () = assert!(core::mem::align_of::<GPUParticleSortItem>() == 4);

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleSimulationSortEncodeReport {
    pub pass_count: i64,
    pub item_count: i64,
    pub padded_item_count: i64,
    pub dispatch_workgroups: i64,
}

impl GPUParticleSimulationSortEncodeReport {
    pub fn new(
        pass_count: i64,
        item_count: i64,
        padded_item_count: i64,
        dispatch_workgroups: i64,
    ) -> Self {
        GPUParticleSimulationSortEncodeReport {
            pass_count,
            item_count,
            padded_item_count,
            dispatch_workgroups,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleSimulationInstanceEncodeReport {
    pub render_instance_count: i64,
    pub instance_dispatch_workgroups: i64,
    pub sort_report: GPUParticleSimulationSortEncodeReport,
}

impl GPUParticleSimulationInstanceEncodeReport {
    pub fn new(
        render_instance_count: i64,
        instance_dispatch_workgroups: i64,
        sort_report: GPUParticleSimulationSortEncodeReport,
    ) -> Self {
        GPUParticleSimulationInstanceEncodeReport {
            render_instance_count,
            instance_dispatch_workgroups,
            sort_report,
        }
    }
}

/// The packed appearance palette and curve keyframes for one batch.
#[derive(Clone, Debug, PartialEq)]
pub struct GPUParticleAppearanceData {
    pub appearances: Vec<GPUParticleAppearance>,
    pub keyframes: Vec<GPUParticleCurveKeyframe>,
    pub size_curve: GPUParticleCurveEncoding,
    pub color_curve: GPUParticleCurveEncoding,
}

impl GPUParticleAppearanceData {
    pub const APPEARANCE_CAPACITY: usize = 64;
    pub const KEYFRAME_CAPACITY: usize = 128;

    /// `init(batch:)`.
    pub fn from_batch(batch: &RenderParticleSimulationBatch) -> Self {
        let mut keyframes = Vec::new();
        let appearances = Self::pack_appearances(batch);
        let size_curve = GPUParticleCurveEncoding::encode(&batch.size_curve, &mut keyframes);
        let color_curve = GPUParticleCurveEncoding::encode(&batch.color_curve, &mut keyframes);
        GPUParticleAppearanceData {
            appearances,
            keyframes,
            size_curve,
            color_curve,
        }
    }

    fn pack_appearances(batch: &RenderParticleSimulationBatch) -> Vec<GPUParticleAppearance> {
        let fallback_appearance =
            diffuse_scene::rendering::render_scene::RenderParticleAppearance::new(
                batch.start_size,
                batch.end_size,
                batch.start_color,
                batch.end_color,
            );
        let palette: &[diffuse_scene::rendering::render_scene::RenderParticleAppearance] =
            if batch.appearance_palette.is_empty() {
                std::slice::from_ref(&fallback_appearance)
            } else {
                &batch.appearance_palette
            };
        let mut result: Vec<GPUParticleAppearance> = Vec::with_capacity(Self::APPEARANCE_CAPACITY);
        for appearance in palette.iter().take(Self::APPEARANCE_CAPACITY) {
            result.push(GPUParticleAppearance::new(
                Float4::new(appearance.start_size, appearance.end_size, 0.0, 0.0),
                appearance.start_color,
                appearance.end_color,
            ));
        }
        if result.is_empty() {
            result.push(GPUParticleAppearance::new(
                Float4::new(
                    fallback_appearance.start_size,
                    fallback_appearance.end_size,
                    0.0,
                    0.0,
                ),
                fallback_appearance.start_color,
                fallback_appearance.end_color,
            ));
        }
        result
    }

    /// `isFinite` — every float lane of both packed arrays is finite.
    pub fn is_finite(&self) -> bool {
        let appearances_finite = self.appearances.iter().all(|appearance| {
            appearance.size.x.is_finite()
                && appearance.size.y.is_finite()
                && appearance.size.z.is_finite()
                && appearance.size.w.is_finite()
                && appearance.start_color.x.is_finite()
                && appearance.start_color.y.is_finite()
                && appearance.start_color.z.is_finite()
                && appearance.start_color.w.is_finite()
                && appearance.end_color.x.is_finite()
                && appearance.end_color.y.is_finite()
                && appearance.end_color.z.is_finite()
                && appearance.end_color.w.is_finite()
        });
        let keyframes_finite = self.keyframes.iter().all(|keyframe| {
            keyframe.time_value.x.is_finite()
                && keyframe.time_value.y.is_finite()
                && keyframe.time_value.z.is_finite()
                && keyframe.time_value.w.is_finite()
        });
        appearances_finite && keyframes_finite
    }
}

/// One bitonic stage: the `(k, j)` pair.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleSortStage {
    pub k: i64,
    pub j: i64,
}

impl GPUParticleSortStage {
    pub fn new(k: i64, j: i64) -> Self {
        GPUParticleSortStage { k, j }
    }

    /// `func uniforms(capacity:)`.
    pub fn uniforms(&self, capacity: i64) -> GPUParticleSortBitonicUniforms {
        GPUParticleSortBitonicUniforms::new(UInt4::new(
            capacity as u32,
            self.k as u32,
            self.j as u32,
            0,
        ))
    }
}

/// One bitonic network is shared by both rendering backends.
#[derive(Clone, Debug, PartialEq)]
pub struct GPUParticleSortPlan {
    pub capacity: i64,
    pub stages: Vec<GPUParticleSortStage>,
}

impl GPUParticleSortPlan {
    /// `init(count:)`.
    pub fn new(count: i64) -> Self {
        let capacity = Self::capacity_for(count);
        let mut stages: Vec<GPUParticleSortStage> = Vec::new();
        let mut k = 2i64;
        while k <= capacity {
            let mut j = k / 2;
            while j > 0 {
                stages.push(GPUParticleSortStage::new(k, j));
                j /= 2;
            }
            k *= 2;
        }
        GPUParticleSortPlan { capacity, stages }
    }

    /// `static func capacity(for:)`.
    pub fn capacity_for(count: i64) -> i64 {
        let mut value = 1i64;
        while value < 1.max(count) {
            value <<= 1;
        }
        value
    }
}
