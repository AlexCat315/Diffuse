//! Translation of Editor/Sources/EditorCore/Scene/Adapter/Inspector/Particles/Section.swift.
//!
//! The particle emitter form: one fixed stack of authored modules, with the
//! module layout rendered by the `particle.module-stack` control.

use diffuse_scene::entity_id::EntityID;
use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
use diffuse_scene::particles::particle_gpu_simulation_plan::ParticleGPUSimulationPlan;

use crate::localization::localized;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::adapter::inspector::particles::bindings::{
    ParticleBoolField, ParticleCurveField, ParticleFloatField, ParticleIntField,
    ParticleVectorField, particle_texture_accepted_kinds,
};
use crate::scene::editor_inspector_schema::{
    EditorInspectorField, EditorInspectorFieldValue, EditorInspectorSection,
};
use crate::scene::inspector::enum_options::EditorInspectorEnumOption;

impl EditorSceneAdapter {
    pub(crate) fn particle_emitter_section(
        &self,
        entity: EntityID,
    ) -> Option<EditorInspectorSection> {
        self.scene().component::<ParticleEmitter>(entity)?;

        let mut fields: Vec<EditorInspectorField> = Vec::new();
        fields.push(EditorInspectorField::new(
            "particle-module-stack",
            localized("Modules"),
            EditorInspectorFieldValue::ParticleModuleStack(
                self.particle_module_stack_binding(entity),
            ),
        ));
        fields.push(EditorInspectorField::new(
            "particle-emitting",
            localized("Emitting"),
            EditorInspectorFieldValue::Bool(self.particle_bool_binding(
                entity,
                ParticleBoolField::Emitting,
                "Toggle particle emitting",
            )),
        ));
        fields.push(EditorInspectorField::new(
            "particle-looping",
            localized("Looping"),
            EditorInspectorFieldValue::Bool(self.particle_bool_binding(
                entity,
                ParticleBoolField::Looping,
                "Toggle particle looping",
            )),
        ));
        fields.push(EditorInspectorField::new(
            "particle-simulation-space",
            localized("Space"),
            EditorInspectorFieldValue::options(&self.particle_simulation_space_binding(entity)),
        ));
        fields.push(EditorInspectorField::new(
            "particle-simulation-backend",
            localized("Backend"),
            EditorInspectorFieldValue::options(&self.particle_simulation_backend_binding(entity)),
        ));
        fields.push(num(
            "particle-gpu-workgroup-size",
            localized("GPU Workgroup"),
            self.particle_int_binding(
                entity,
                ParticleIntField::WorkgroupSize,
                "Update GPU particle workgroup size",
            ),
            1.0,
            ParticleGPUSimulationPlan::MAXIMUM_WORKGROUP_SIZE as f32,
            1.0,
            true,
        ));
        fields.push(EditorInspectorField::new(
            "particle-gpu-status",
            localized("GPU Status"),
            EditorInspectorFieldValue::ReadOnly(self.particle_gpu_status_label(entity)),
        ));
        fields.push(num(
            "particle-duration",
            localized("Duration"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::Duration,
                "Update particle duration",
            ),
            0.0,
            600.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-simulation-speed",
            localized("Speed"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::SimulationSpeed,
                "Update particle simulation speed",
            ),
            0.0,
            16.0,
            0.05,
            true,
        ));
        fields.push(num(
            "particle-prewarm-time",
            localized("Prewarm"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::PrewarmTime,
                "Update particle prewarm",
            ),
            0.0,
            600.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-prewarm-step",
            localized("Prewarm Step"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::PrewarmStep,
                "Update particle prewarm step",
            ),
            0.004,
            1.0,
            0.01,
            true,
        ));
        fields.push(num(
            "particle-rate",
            localized("Emission Rate"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::EmissionRate,
                "Update emission rate",
            ),
            0.0,
            1000.0,
            1.0,
            true,
        ));
        fields.push(EditorInspectorField::new(
            "particle-rate-curve",
            localized("Rate Curve"),
            EditorInspectorFieldValue::ParticleCurve(self.particle_curve_binding(
                entity,
                ParticleCurveField::EmissionRate,
                "Update particle rate curve",
            )),
        ));
        fields.push(num(
            "particle-distance-rate",
            localized("Rate over Distance"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::DistanceEmissionRate,
                "Update distance emission rate",
            ),
            0.0,
            1000.0,
            1.0,
            true,
        ));
        fields.push(EditorInspectorField::new(
            "particle-distance-rate-curve",
            localized("Distance Curve"),
            EditorInspectorFieldValue::ParticleCurve(self.particle_curve_binding(
                entity,
                ParticleCurveField::DistanceEmissionRate,
                "Update particle distance rate curve",
            )),
        ));
        fields.push(num(
            "particle-burst-count",
            localized("Burst Count"),
            self.particle_int_binding(
                entity,
                ParticleIntField::BurstCount,
                "Update particle burst count",
            ),
            0.0,
            100_000.0,
            1.0,
            true,
        ));
        fields.push(num(
            "particle-burst-interval",
            localized("Burst Interval"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::BurstInterval,
                "Update particle burst interval",
            ),
            0.0,
            60.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-max",
            localized("Max Particles"),
            self.particle_max_binding(entity),
            0.0,
            100_000.0,
            16.0,
            true,
        ));
        fields.push(num(
            "particle-max-spawned-per-frame",
            localized("Max Spawn / Frame"),
            self.particle_int_binding(
                entity,
                ParticleIntField::MaxSpawnedParticlesPerFrame,
                "Update particle spawn budget",
            ),
            0.0,
            100_000.0,
            16.0,
            true,
        ));
        fields.push(num(
            "particle-max-rendered",
            localized("Max Rendered"),
            self.particle_int_binding(
                entity,
                ParticleIntField::MaxRenderedParticles,
                "Update max rendered particles",
            ),
            0.0,
            100_000.0,
            16.0,
            true,
        ));
        fields.push(num(
            "particle-lifetime",
            localized("Lifetime"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::Lifetime,
                "Update particle lifetime",
            ),
            0.0,
            60.0,
            0.1,
            true,
        ));
        fields.push(EditorInspectorField::new(
            "particle-sub-emitter-trigger",
            localized("Sub Emit"),
            EditorInspectorFieldValue::options(&self.particle_sub_emitter_trigger_binding(entity)),
        ));
        fields.push(num(
            "particle-sub-emitter-burst",
            localized("Sub Count"),
            self.particle_int_binding(
                entity,
                ParticleIntField::SubEmitterBurstCount,
                "Update sub-emitter count",
            ),
            0.0,
            10_000.0,
            1.0,
            true,
        ));
        fields.push(num(
            "particle-sub-emitter-probability",
            localized("Sub Chance"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::SubEmitterProbability,
                "Update sub-emitter chance",
            ),
            0.0,
            1.0,
            0.05,
            true,
        ));
        fields.push(num(
            "particle-sub-emitter-depth",
            localized("Sub Depth"),
            self.particle_int_binding(
                entity,
                ParticleIntField::SubEmitterMaxDepth,
                "Update sub-emitter depth",
            ),
            0.0,
            16.0,
            1.0,
            true,
        ));
        fields.push(num(
            "particle-sub-emitter-inherit",
            localized("Sub Inherit"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::SubEmitterInheritVelocity,
                "Update sub-emitter inheritance",
            ),
            0.0,
            10.0,
            0.05,
            true,
        ));
        fields.push(num(
            "particle-sub-emitter-lifetime",
            localized("Sub Lifetime"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::SubEmitterLifetime,
                "Update sub-emitter lifetime",
            ),
            0.0001,
            60.0,
            0.1,
            true,
        ));
        fields.push(vec3(
            "particle-sub-emitter-velocity",
            localized("Sub Velocity"),
            self.particle_vector_binding(
                entity,
                ParticleVectorField::SubEmitterStartVelocity,
                0,
                "Update sub-emitter velocity",
            ),
            self.particle_vector_binding(
                entity,
                ParticleVectorField::SubEmitterStartVelocity,
                1,
                "Update sub-emitter velocity",
            ),
            self.particle_vector_binding(
                entity,
                ParticleVectorField::SubEmitterStartVelocity,
                2,
                "Update sub-emitter velocity",
            ),
        ));
        fields.push(vec3(
            "particle-sub-emitter-velocity-random",
            localized("Sub Vel Random"),
            self.particle_vector_binding(
                entity,
                ParticleVectorField::SubEmitterVelocityRandomness,
                0,
                "Update sub-emitter velocity randomness",
            ),
            self.particle_vector_binding(
                entity,
                ParticleVectorField::SubEmitterVelocityRandomness,
                1,
                "Update sub-emitter velocity randomness",
            ),
            self.particle_vector_binding(
                entity,
                ParticleVectorField::SubEmitterVelocityRandomness,
                2,
                "Update sub-emitter velocity randomness",
            ),
        ));
        fields.push(num(
            "particle-sub-emitter-start-size",
            localized("Sub Start Size"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::SubEmitterStartSize,
                "Update sub-emitter start size",
            ),
            0.0,
            100.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-sub-emitter-end-size",
            localized("Sub End Size"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::SubEmitterEndSize,
                "Update sub-emitter end size",
            ),
            0.0,
            100.0,
            0.1,
            true,
        ));
        fields.push(EditorInspectorField::new(
            "particle-sub-emitter-start-color",
            localized("Sub Start Color"),
            EditorInspectorFieldValue::Color(self.particle_sub_emitter_color_binding(entity, true)),
        ));
        fields.push(EditorInspectorField::new(
            "particle-sub-emitter-end-color",
            localized("Sub End Color"),
            EditorInspectorFieldValue::Color(
                self.particle_sub_emitter_color_binding(entity, false),
            ),
        ));
        fields.push(EditorInspectorField::new(
            "particle-sub-emitters",
            localized("Sub Emitters"),
            EditorInspectorFieldValue::ParticleSubEmitters(
                self.particle_sub_emitters_binding(entity),
            ),
        ));
        fields.push(EditorInspectorField::new(
            "particle-shape",
            localized("Shape"),
            EditorInspectorFieldValue::options(&self.particle_shape_binding(entity)),
        ));
        fields.push(num(
            "particle-spawn-radius",
            localized("Spawn Radius"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::SpawnRadius,
                "Update spawn radius",
            ),
            0.0,
            100.0,
            0.1,
            true,
        ));
        fields.push(vec3(
            "particle-box-extents",
            localized("Box Extents"),
            self.particle_box_extents_binding(entity, 0),
            self.particle_box_extents_binding(entity, 1),
            self.particle_box_extents_binding(entity, 2),
        ));
        fields.push(num(
            "particle-cone-radius",
            localized("Cone Radius"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::ConeRadius,
                "Update cone radius",
            ),
            0.0,
            100.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-cone-height",
            localized("Cone Height"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::ConeHeight,
                "Update cone height",
            ),
            0.0,
            100.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-start-size",
            localized("Start Size"),
            self.particle_float_binding(entity, ParticleFloatField::StartSize, "Update start size"),
            0.0,
            100.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-end-size",
            localized("End Size"),
            self.particle_float_binding(entity, ParticleFloatField::EndSize, "Update end size"),
            0.0,
            100.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-size-randomness",
            localized("Size Random"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::SizeRandomness,
                "Update size randomness",
            ),
            0.0,
            4.0,
            0.05,
            true,
        ));
        fields.push(num(
            "particle-rotation",
            localized("Rotation"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::StartRotation,
                "Update particle rotation",
            ),
            -1000.0,
            1000.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-rotation-randomness",
            localized("Rot Random"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::RotationRandomness,
                "Update rotation randomness",
            ),
            0.0,
            1000.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-angular-velocity",
            localized("Spin"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::AngularVelocity,
                "Update particle spin",
            ),
            -1000.0,
            1000.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-angular-velocity-randomness",
            localized("Spin Random"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::AngularVelocityRandomness,
                "Update spin randomness",
            ),
            0.0,
            1000.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-velocity-inheritance",
            localized("Velocity Inherit"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::VelocityInheritance,
                "Update velocity inheritance",
            ),
            0.0,
            10.0,
            0.05,
            true,
        ));
        fields.push(EditorInspectorField::new(
            "particle-size-curve",
            localized("Size Curve"),
            EditorInspectorFieldValue::ParticleCurve(self.particle_curve_binding(
                entity,
                ParticleCurveField::Size,
                "Update particle size curve",
            )),
        ));
        fields.push(vec3(
            "particle-gravity",
            localized("Gravity"),
            self.particle_gravity_binding(entity, 0),
            self.particle_gravity_binding(entity, 1),
            self.particle_gravity_binding(entity, 2),
        ));
        fields.push(num(
            "particle-noise-strength",
            localized("Noise Strength"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::NoiseStrength,
                "Update particle noise strength",
            ),
            0.0,
            100.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-noise-scale",
            localized("Noise Scale"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::NoiseScale,
                "Update particle noise scale",
            ),
            0.0001,
            100.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-noise-speed",
            localized("Noise Speed"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::NoiseSpeed,
                "Update particle noise speed",
            ),
            0.0,
            100.0,
            0.1,
            true,
        ));
        fields.push(EditorInspectorField::new(
            "particle-force-mode",
            localized("Force"),
            EditorInspectorFieldValue::options(&self.particle_force_mode_binding(entity)),
        ));
        fields.push(vec3(
            "particle-force-center",
            localized("Force Center"),
            self.particle_vector_binding(
                entity,
                ParticleVectorField::ForceCenter,
                0,
                "Update particle force center",
            ),
            self.particle_vector_binding(
                entity,
                ParticleVectorField::ForceCenter,
                1,
                "Update particle force center",
            ),
            self.particle_vector_binding(
                entity,
                ParticleVectorField::ForceCenter,
                2,
                "Update particle force center",
            ),
        ));
        fields.push(vec3(
            "particle-force-axis",
            localized("Force Axis"),
            self.particle_vector_binding(
                entity,
                ParticleVectorField::ForceAxis,
                0,
                "Update particle force axis",
            ),
            self.particle_vector_binding(
                entity,
                ParticleVectorField::ForceAxis,
                1,
                "Update particle force axis",
            ),
            self.particle_vector_binding(
                entity,
                ParticleVectorField::ForceAxis,
                2,
                "Update particle force axis",
            ),
        ));
        fields.push(num(
            "particle-force-radius",
            localized("Force Radius"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::ForceRadius,
                "Update particle force radius",
            ),
            0.0,
            10_000.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-force-strength",
            localized("Force Strength"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::ForceStrength,
                "Update particle force strength",
            ),
            -10_000.0,
            10_000.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-force-falloff",
            localized("Force Falloff"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::ForceFalloff,
                "Update particle force falloff",
            ),
            0.0,
            16.0,
            0.1,
            true,
        ));
        fields.push(EditorInspectorField::new(
            "particle-vector-field-mode",
            localized("Vector Field"),
            EditorInspectorFieldValue::options(&self.particle_vector_field_mode_binding(entity)),
        ));
        fields.push(vec3(
            "particle-vector-field-direction",
            localized("Field Direction"),
            self.particle_vector_binding(
                entity,
                ParticleVectorField::VectorFieldDirection,
                0,
                "Update vector field direction",
            ),
            self.particle_vector_binding(
                entity,
                ParticleVectorField::VectorFieldDirection,
                1,
                "Update vector field direction",
            ),
            self.particle_vector_binding(
                entity,
                ParticleVectorField::VectorFieldDirection,
                2,
                "Update vector field direction",
            ),
        ));
        fields.push(num(
            "particle-vector-field-strength",
            localized("Field Strength"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::VectorFieldStrength,
                "Update vector field strength",
            ),
            -10_000.0,
            10_000.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-vector-field-scale",
            localized("Field Scale"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::VectorFieldScale,
                "Update vector field scale",
            ),
            0.0001,
            1000.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-vector-field-scroll",
            localized("Field Scroll"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::VectorFieldScrollSpeed,
                "Update vector field scroll",
            ),
            0.0,
            1000.0,
            0.1,
            true,
        ));
        fields.push(EditorInspectorField::new(
            "particle-collision-mode",
            localized("Collision"),
            EditorInspectorFieldValue::options(&self.particle_collision_mode_binding(entity)),
        ));
        fields.push(num(
            "particle-collision-plane-y",
            localized("Plane Y"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::CollisionPlaneY,
                "Update particle collision plane",
            ),
            -10_000.0,
            10_000.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-collision-restitution",
            localized("Restitution"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::CollisionRestitution,
                "Update particle restitution",
            ),
            0.0,
            1.0,
            0.05,
            true,
        ));
        fields.push(num(
            "particle-collision-damping",
            localized("Damping"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::CollisionDamping,
                "Update particle damping",
            ),
            0.0,
            1.0,
            0.05,
            true,
        ));
        fields.push(EditorInspectorField::new(
            "particle-start-color",
            localized("Start Color"),
            EditorInspectorFieldValue::Color(self.particle_color_binding(entity, true)),
        ));
        fields.push(EditorInspectorField::new(
            "particle-end-color",
            localized("End Color"),
            EditorInspectorFieldValue::Color(self.particle_color_binding(entity, false)),
        ));
        fields.push(EditorInspectorField::new(
            "particle-color-curve",
            localized("Color Curve"),
            EditorInspectorFieldValue::ParticleCurve(self.particle_curve_binding(
                entity,
                ParticleCurveField::Color,
                "Update particle color curve",
            )),
        ));
        fields.push(EditorInspectorField::new(
            "particle-blend-mode",
            localized("Blend"),
            EditorInspectorFieldValue::options(&self.particle_blend_mode_binding(entity)),
        ));
        fields.push(EditorInspectorField::new(
            "particle-render-mode",
            localized("Render Mode"),
            EditorInspectorFieldValue::options(&self.particle_render_mode_binding(entity)),
        ));
        fields.push(EditorInspectorField::new(
            "particle-sort-mode",
            localized("Sort"),
            EditorInspectorFieldValue::options(&self.particle_sort_mode_binding(entity)),
        ));
        fields.push(num(
            "particle-ribbon-width-scale",
            localized("Ribbon Width"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::RibbonWidthScale,
                "Update ribbon width",
            ),
            0.0,
            100.0,
            0.05,
            true,
        ));
        fields.push(num(
            "particle-ribbon-tail-width",
            localized("Ribbon Tail Width"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::RibbonTailWidthScale,
                "Update ribbon tail width",
            ),
            0.0,
            10.0,
            0.05,
            true,
        ));
        fields.push(num(
            "particle-ribbon-tail-alpha",
            localized("Ribbon Tail Alpha"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::RibbonTailAlphaScale,
                "Update ribbon tail alpha",
            ),
            0.0,
            1.0,
            0.05,
            true,
        ));
        fields.push(num(
            "particle-ribbon-max-segment",
            localized("Ribbon Max Segment"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::RibbonMaxSegmentLength,
                "Update ribbon max segment",
            ),
            0.0,
            100_000.0,
            0.1,
            true,
        ));
        fields.push(num(
            "particle-ribbon-join-overlap",
            localized("Ribbon Join Overlap"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::RibbonJoinOverlapScale,
                "Update ribbon join overlap",
            ),
            0.0,
            10.0,
            0.05,
            true,
        ));
        fields.push(num(
            "particle-ribbon-smoothing",
            localized("Ribbon Smoothing"),
            self.particle_clamped_int_binding(
                entity,
                ParticleIntField::RibbonSmoothingSegments,
                1,
                16,
                "Update ribbon smoothing",
            ),
            1.0,
            16.0,
            1.0,
            true,
        ));
        fields.push(num(
            "particle-ribbon-uv-tiling",
            localized("Ribbon UV Tiling"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::RibbonTextureTiling,
                "Update ribbon UV tiling",
            ),
            0.0,
            100.0,
            0.05,
            true,
        ));
        fields.push(num(
            "particle-ribbon-uv-offset",
            localized("Ribbon UV Offset"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::RibbonTextureOffset,
                "Update ribbon UV offset",
            ),
            -10_000.0,
            10_000.0,
            0.05,
            true,
        ));
        fields.push(EditorInspectorField::new(
            "particle-render-alignment",
            localized("Alignment"),
            EditorInspectorFieldValue::options(&self.particle_render_alignment_binding(entity)),
        ));
        fields.push(num(
            "particle-velocity-stretch-scale",
            localized("Velocity Stretch"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::VelocityStretchScale,
                "Update velocity stretch",
            ),
            0.0,
            10.0,
            0.05,
            true,
        ));
        fields.push(num(
            "particle-velocity-stretch-max",
            localized("Max Stretch"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::VelocityStretchMax,
                "Update max velocity stretch",
            ),
            1.0,
            100.0,
            0.5,
            true,
        ));
        fields.push(num(
            "particle-max-render-distance",
            localized("Max Render Distance"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::MaxRenderDistance,
                "Update particle render distance",
            ),
            0.0,
            100_000.0,
            1.0,
            true,
        ));
        fields.push(num(
            "particle-render-distance-fade",
            localized("Distance Fade"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::RenderDistanceFadeRange,
                "Update particle distance fade",
            ),
            0.0,
            100_000.0,
            1.0,
            true,
        ));
        fields.push(num(
            "particle-render-lod-start",
            localized("LOD Start"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::RenderLodStartDistance,
                "Update particle render LOD start",
            ),
            0.0,
            100_000.0,
            1.0,
            true,
        ));
        fields.push(num(
            "particle-render-lod-end",
            localized("LOD End"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::RenderLodEndDistance,
                "Update particle render LOD end",
            ),
            0.0,
            100_000.0,
            1.0,
            true,
        ));
        fields.push(num(
            "particle-render-lod-min-scale",
            localized("LOD Min Scale"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::RenderLodMinParticleScale,
                "Update particle render LOD scale",
            ),
            0.0,
            1.0,
            0.05,
            true,
        ));
        fields.push(EditorInspectorField::new(
            "particle-render-bounds-mode",
            localized("Bounds Mode"),
            EditorInspectorFieldValue::options(&self.particle_render_bounds_mode_binding(entity)),
        ));
        fields.push(num(
            "particle-render-bounds-radius",
            localized("Manual Bounds"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::RenderBoundsRadius,
                "Update particle render bounds",
            ),
            0.0,
            100_000.0,
            1.0,
            true,
        ));
        let estimated_radius = self
            .scene()
            .component::<ParticleEmitter>(entity)
            .map(|emitter| emitter.estimated_render_bounds_radius())
            .unwrap_or(0.0);
        fields.push(EditorInspectorField::new(
            "particle-render-bounds-estimate",
            localized("Auto Bounds"),
            EditorInspectorFieldValue::ReadOnly(self.format(estimated_radius)),
        ));
        fields.push(EditorInspectorField::new(
            "particle-texture",
            localized("Texture"),
            EditorInspectorFieldValue::Asset {
                binding: self.particle_texture_asset_binding(entity),
                accepted_kinds: particle_texture_accepted_kinds(),
                placeholder: localized("Drop texture"),
            },
        ));
        fields.push(num(
            "particle-texture-sheet-columns",
            localized("Sheet Columns"),
            self.particle_int_binding(
                entity,
                ParticleIntField::SheetColumns,
                "Update texture sheet columns",
            ),
            1.0,
            64.0,
            1.0,
            true,
        ));
        fields.push(num(
            "particle-texture-sheet-rows",
            localized("Sheet Rows"),
            self.particle_int_binding(
                entity,
                ParticleIntField::SheetRows,
                "Update texture sheet rows",
            ),
            1.0,
            64.0,
            1.0,
            true,
        ));
        fields.push(num(
            "particle-texture-sheet-frames",
            localized("Sheet Frames"),
            self.particle_int_binding(
                entity,
                ParticleIntField::SheetFrames,
                "Update texture sheet frames",
            ),
            1.0,
            4096.0,
            1.0,
            true,
        ));
        fields.push(num(
            "particle-texture-sheet-fps",
            localized("Sheet FPS"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::FrameRate,
                "Update texture sheet FPS",
            ),
            0.0,
            240.0,
            1.0,
            true,
        ));
        fields.push(EditorInspectorField::new(
            "particle-texture-sheet-playback",
            localized("Sheet Playback"),
            EditorInspectorFieldValue::options(
                &self.particle_texture_sheet_playback_mode_binding(entity),
            ),
        ));
        fields.push(num(
            "particle-texture-sheet-start-frame",
            localized("Sheet Start"),
            self.particle_int_binding(
                entity,
                ParticleIntField::SheetStartFrame,
                "Update texture sheet start frame",
            ),
            0.0,
            4095.0,
            1.0,
            true,
        ));
        fields.push(num(
            "particle-texture-sheet-random",
            localized("Sheet Random"),
            self.particle_int_binding(
                entity,
                ParticleIntField::SheetRandomness,
                "Update texture sheet random frames",
            ),
            0.0,
            4095.0,
            1.0,
            true,
        ));
        fields.push(num(
            "particle-trail-length",
            localized("Trail Length"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::TrailLength,
                "Update particle trail length",
            ),
            0.0,
            10.0,
            0.05,
            true,
        ));
        fields.push(num(
            "particle-trail-segments",
            localized("Trail Segments"),
            self.particle_int_binding(
                entity,
                ParticleIntField::TrailSegments,
                "Update particle trail segments",
            ),
            0.0,
            64.0,
            1.0,
            true,
        ));
        fields.push(num(
            "particle-trail-end-size",
            localized("Trail End Size"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::TrailEndSizeScale,
                "Update particle trail end size",
            ),
            0.0,
            4.0,
            0.05,
            true,
        ));
        fields.push(num(
            "particle-trail-end-alpha",
            localized("Trail End Alpha"),
            self.particle_float_binding(
                entity,
                ParticleFloatField::TrailEndAlphaScale,
                "Update particle trail end alpha",
            ),
            0.0,
            1.0,
            0.05,
            true,
        ));

        Some(EditorInspectorSection::new(
            "particle-emitter",
            localized("Particle Emitter"),
            fields,
        ))
    }
}

fn num(
    id: &str,
    label: String,
    binding: cove_ui_compose::scene_core::Binding<f32>,
    min: f32,
    max: f32,
    step: f32,
    shows_stepper: bool,
) -> EditorInspectorField {
    EditorInspectorField::new(
        id,
        label,
        EditorInspectorFieldValue::ConstrainedNumber {
            binding,
            min: Some(min),
            max: Some(max),
            step: Some(step),
            shows_stepper,
        },
    )
}

fn vec3(
    id: &str,
    label: String,
    x: cove_ui_compose::scene_core::Binding<f32>,
    y: cove_ui_compose::scene_core::Binding<f32>,
    z: cove_ui_compose::scene_core::Binding<f32>,
) -> EditorInspectorField {
    EditorInspectorField::new(id, label, EditorInspectorFieldValue::Vector3 { x, y, z })
}
