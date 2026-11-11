//! `Editor/Sources/EditorCore/Scene/Adapter/Inspector/Particles/Scalability.swift`.

use cove_ui_compose::scene_core::Binding;
use diffuse_scene::particles::particle_scalability::{
    ParticleScalabilityPolicyResource, ParticleScalabilityResource,
    ParticleScalabilityStateResource,
};

use crate::localization::localized;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::{
    EditorInspectorField, EditorInspectorFieldValue, EditorInspectorSection,
};

#[derive(Clone, Copy)]
enum ScalingAxis {
    EmissionScale,
    BurstScale,
    DistanceEmissionScale,
    MaxLiveParticleScale,
    TargetLiveParticles,
    TargetSpawnedParticlesPerFrame,
    MinimumScale,
    PressureStep,
    RecoveryStep,
}

#[derive(Clone, Copy)]
enum ScalingKind {
    Resource,
    PolicyFloat,
    PolicyInteger,
}

impl EditorSceneAdapter {
    pub(crate) fn particle_scalability_section(&self) -> EditorInspectorSection {
        let state = self
            .scene()
            .resource::<ParticleScalabilityStateResource>()
            .unwrap_or_default();
        let fields: Vec<EditorInspectorField> = vec![
            constrained_field(
                self,
                "particle-scale-emission",
                "Emission Scale",
                ScalingAxis::EmissionScale,
                ScalingKind::Resource,
                0.05,
            ),
            constrained_field(
                self,
                "particle-scale-burst",
                "Burst Scale",
                ScalingAxis::BurstScale,
                ScalingKind::Resource,
                0.05,
            ),
            constrained_field(
                self,
                "particle-scale-distance",
                "Distance Scale",
                ScalingAxis::DistanceEmissionScale,
                ScalingKind::Resource,
                0.05,
            ),
            constrained_field(
                self,
                "particle-scale-live-cap",
                "Live Cap Scale",
                ScalingAxis::MaxLiveParticleScale,
                ScalingKind::Resource,
                0.05,
            ),
            EditorInspectorField::new(
                "particle-policy-enabled",
                localized("Auto Scale"),
                EditorInspectorFieldValue::Bool(self.policy_enabled_binding()),
            ),
            constrained_field(
                self,
                "particle-policy-target-live",
                "Target Live",
                ScalingAxis::TargetLiveParticles,
                ScalingKind::PolicyInteger,
                100.0,
            ),
            constrained_field(
                self,
                "particle-policy-target-spawn",
                "Target Spawn",
                ScalingAxis::TargetSpawnedParticlesPerFrame,
                ScalingKind::PolicyInteger,
                10.0,
            ),
            constrained_field(
                self,
                "particle-policy-min-scale",
                "Minimum Scale",
                ScalingAxis::MinimumScale,
                ScalingKind::PolicyFloat,
                0.05,
            ),
            constrained_field(
                self,
                "particle-policy-pressure-step",
                "Pressure Step",
                ScalingAxis::PressureStep,
                ScalingKind::PolicyFloat,
                0.05,
            ),
            constrained_field(
                self,
                "particle-policy-recovery-step",
                "Recovery Step",
                ScalingAxis::RecoveryStep,
                ScalingKind::PolicyFloat,
                0.05,
            ),
            EditorInspectorField::new(
                "particle-policy-applied-scale",
                localized("Applied Scale"),
                EditorInspectorFieldValue::ReadOnly(self.format(state.applied_scale)),
            ),
            EditorInspectorField::new(
                "particle-policy-pressure",
                localized("Pressure"),
                EditorInspectorFieldValue::ReadOnly(self.format(state.pressure)),
            ),
            EditorInspectorField::new(
                "particle-policy-reason",
                localized("Reason"),
                EditorInspectorFieldValue::ReadOnly(state.reason.raw_value().to_string()),
            ),
        ];
        EditorInspectorSection::new(
            "particle-scalability",
            localized("Particle Scalability"),
            fields,
        )
    }

    fn update_particle_scalability(&self, mutate: impl FnOnce(&mut ParticleScalabilityResource)) {
        let mut next = self
            .scene()
            .resource::<ParticleScalabilityResource>()
            .unwrap_or_default();
        mutate(&mut next);
        let sanitized = ParticleScalabilityResource::new(
            next.emission_scale,
            next.burst_scale,
            next.distance_emission_scale,
            next.max_live_particle_scale,
        );
        if self
            .scene()
            .resource::<ParticleScalabilityResource>()
            .as_ref()
            == Some(&sanitized)
        {
            return;
        }
        self.with_scene_mut(|scene| scene.set_resource(sanitized));
        self.notify_revision_changed_default();
    }

    fn update_particle_scalability_policy(
        &self,
        mutate: impl FnOnce(&mut ParticleScalabilityPolicyResource),
    ) {
        let mut next = self
            .scene()
            .resource::<ParticleScalabilityPolicyResource>()
            .unwrap_or_else(ParticleScalabilityPolicyResource::disabled);
        mutate(&mut next);
        let sanitized = ParticleScalabilityPolicyResource::new(
            next.is_enabled,
            next.target_live_particles,
            next.target_spawned_particles_per_frame,
            next.minimum_scale,
            next.pressure_step,
            next.recovery_step,
        );
        if self
            .scene()
            .resource::<ParticleScalabilityPolicyResource>()
            .as_ref()
            == Some(&sanitized)
        {
            return;
        }
        self.with_scene_mut(|scene| scene.set_resource(sanitized));
        self.notify_revision_changed_default();
    }

    fn policy_enabled_binding(&self) -> Binding<bool> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .resource::<ParticleScalabilityPolicyResource>()
                    .map(|policy| policy.is_enabled)
                    .unwrap_or(false)
            },
            move |next: bool| {
                let current = set_adapter
                    .scene()
                    .resource::<ParticleScalabilityPolicyResource>()
                    .map(|policy| policy.is_enabled);
                if current == Some(next) {
                    return;
                }
                set_adapter.update_particle_scalability_policy(|policy| policy.is_enabled = next);
            },
        )
    }
}

fn constrained_field(
    adapter: &EditorSceneAdapter,
    id: &str,
    label: &str,
    axis: ScalingAxis,
    kind: ScalingKind,
    step: f32,
) -> EditorInspectorField {
    let binding = match kind {
        ScalingKind::Resource => resource_float_binding(adapter, axis),
        ScalingKind::PolicyFloat => policy_float_binding(adapter, axis),
        ScalingKind::PolicyInteger => policy_integer_binding(adapter, axis),
    };
    let maximum = match axis {
        ScalingAxis::TargetLiveParticles | ScalingAxis::TargetSpawnedParticlesPerFrame => {
            1_000_000.0
        }
        _ => 1.0,
    };
    EditorInspectorField::new(
        id,
        localized(label),
        EditorInspectorFieldValue::ConstrainedNumber {
            binding,
            min: Some(0.0),
            max: Some(maximum),
            step: Some(step),
            shows_stepper: true,
        },
    )
}

fn resource_float_binding(adapter: &EditorSceneAdapter, axis: ScalingAxis) -> Binding<f32> {
    let get_adapter = adapter.clone();
    let set_adapter = adapter.clone();
    Binding::new(
        move || {
            get_adapter
                .scene()
                .resource::<ParticleScalabilityResource>()
                .map(|resource| resource_float(&resource, axis))
                .unwrap_or(1.0)
        },
        move |next: f32| {
            let current = set_adapter
                .scene()
                .resource::<ParticleScalabilityResource>()
                .map(|resource| resource_float(&resource, axis));
            if current == Some(next) {
                return;
            }
            set_adapter
                .update_particle_scalability(|resource| set_resource_float(resource, axis, next));
        },
    )
}

fn resource_float(resource: &ParticleScalabilityResource, axis: ScalingAxis) -> f32 {
    match axis {
        ScalingAxis::EmissionScale => resource.emission_scale,
        ScalingAxis::BurstScale => resource.burst_scale,
        ScalingAxis::DistanceEmissionScale => resource.distance_emission_scale,
        ScalingAxis::MaxLiveParticleScale => resource.max_live_particle_scale,
        _ => 1.0,
    }
}

fn set_resource_float(resource: &mut ParticleScalabilityResource, axis: ScalingAxis, value: f32) {
    match axis {
        ScalingAxis::EmissionScale => resource.emission_scale = value,
        ScalingAxis::BurstScale => resource.burst_scale = value,
        ScalingAxis::DistanceEmissionScale => resource.distance_emission_scale = value,
        ScalingAxis::MaxLiveParticleScale => resource.max_live_particle_scale = value,
        _ => {}
    }
}

fn policy_float_binding(adapter: &EditorSceneAdapter, axis: ScalingAxis) -> Binding<f32> {
    let get_adapter = adapter.clone();
    let set_adapter = adapter.clone();
    Binding::new(
        move || {
            get_adapter
                .scene()
                .resource::<ParticleScalabilityPolicyResource>()
                .map(|policy| policy_float(&policy, axis))
                .unwrap_or_else(|| {
                    policy_float(&ParticleScalabilityPolicyResource::disabled(), axis)
                })
        },
        move |next: f32| {
            let current = set_adapter
                .scene()
                .resource::<ParticleScalabilityPolicyResource>()
                .map(|policy| policy_float(&policy, axis));
            if current == Some(next) {
                return;
            }
            set_adapter
                .update_particle_scalability_policy(|policy| set_policy_float(policy, axis, next));
        },
    )
}

fn policy_integer_binding(adapter: &EditorSceneAdapter, axis: ScalingAxis) -> Binding<f32> {
    let get_adapter = adapter.clone();
    let set_adapter = adapter.clone();
    Binding::new(
        move || {
            let value = get_adapter
                .scene()
                .resource::<ParticleScalabilityPolicyResource>()
                .map(|policy| policy_integer(&policy, axis))
                .unwrap_or_else(|| {
                    policy_integer(&ParticleScalabilityPolicyResource::disabled(), axis)
                });
            value as f32
        },
        move |next: f32| {
            let value = next.round().max(0.0) as i64;
            let current = set_adapter
                .scene()
                .resource::<ParticleScalabilityPolicyResource>()
                .map(|policy| policy_integer(&policy, axis));
            if current == Some(value) {
                return;
            }
            set_adapter.update_particle_scalability_policy(|policy| {
                set_policy_integer(policy, axis, value)
            });
        },
    )
}

fn policy_float(policy: &ParticleScalabilityPolicyResource, axis: ScalingAxis) -> f32 {
    match axis {
        ScalingAxis::MinimumScale => policy.minimum_scale,
        ScalingAxis::PressureStep => policy.pressure_step,
        ScalingAxis::RecoveryStep => policy.recovery_step,
        _ => 0.0,
    }
}

fn set_policy_float(policy: &mut ParticleScalabilityPolicyResource, axis: ScalingAxis, value: f32) {
    match axis {
        ScalingAxis::MinimumScale => policy.minimum_scale = value,
        ScalingAxis::PressureStep => policy.pressure_step = value,
        ScalingAxis::RecoveryStep => policy.recovery_step = value,
        _ => {}
    }
}

fn policy_integer(policy: &ParticleScalabilityPolicyResource, axis: ScalingAxis) -> i64 {
    match axis {
        ScalingAxis::TargetLiveParticles => policy.target_live_particles,
        ScalingAxis::TargetSpawnedParticlesPerFrame => policy.target_spawned_particles_per_frame,
        _ => 0,
    }
}

fn set_policy_integer(
    policy: &mut ParticleScalabilityPolicyResource,
    axis: ScalingAxis,
    value: i64,
) {
    match axis {
        ScalingAxis::TargetLiveParticles => policy.target_live_particles = value,
        ScalingAxis::TargetSpawnedParticlesPerFrame => {
            policy.target_spawned_particles_per_frame = value
        }
        _ => {}
    }
}
