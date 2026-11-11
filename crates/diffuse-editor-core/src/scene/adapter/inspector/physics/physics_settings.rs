//! `Editor/Sources/EditorCore/Scene/Adapter/Inspector/Physics/PhysicsSettings.swift`.

use cove_ui_compose::scene_core::Binding;
use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::physics::backend::physics_backend_kind::PhysicsBackendKind;
use diffuse_scene::physics::physics_settings::{PhysicsCapacitySettings, PhysicsSettingsResource};
use diffuse_scene::physics::physics_types::PhysicsSimulationMode;

use crate::localization::localized;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::{
    EditorInspectorField, EditorInspectorFieldValue, EditorInspectorSection,
};

#[derive(Clone, Copy)]
enum GravityAxis {
    X,
    Y,
    Z,
}

#[derive(Clone, Copy)]
enum IntegerSetting {
    MaxSubstepsPerFrame,
    CollisionSteps,
}

#[derive(Clone, Copy)]
enum CapacitySetting {
    MaxBodies,
    WorkerThreadCount,
}

impl EditorSceneAdapter {
    pub(crate) fn physics_settings_section(&self) -> EditorInspectorSection {
        let fields: Vec<EditorInspectorField> = vec![
            EditorInspectorField::new(
                "physics-backend",
                localized("Backend"),
                EditorInspectorFieldValue::options(&self.physics_backend_kind_binding()),
            ),
            EditorInspectorField::new(
                "physics-simulation-mode",
                localized("Simulation Mode"),
                EditorInspectorFieldValue::options(&self.physics_simulation_mode_binding()),
            ),
            EditorInspectorField::new(
                "physics-gravity",
                localized("Gravity"),
                EditorInspectorFieldValue::Vector3 {
                    x: self.physics_gravity_binding(GravityAxis::X),
                    y: self.physics_gravity_binding(GravityAxis::Y),
                    z: self.physics_gravity_binding(GravityAxis::Z),
                },
            ),
            constrained(
                "physics-fixed-step",
                "Fixed Time Step",
                self.physics_fixed_time_step_binding(),
                0.000_001,
                1.0,
                0.001,
            ),
            constrained(
                "physics-max-substeps",
                "Max Substeps",
                self.physics_integer_setting_binding(IntegerSetting::MaxSubstepsPerFrame),
                1.0,
                64.0,
                1.0,
            ),
            constrained(
                "physics-collision-steps",
                "Collision Steps",
                self.physics_integer_setting_binding(IntegerSetting::CollisionSteps),
                1.0,
                64.0,
                1.0,
            ),
            EditorInspectorField::new(
                "physics-allow-sleep",
                localized("Allow Sleep"),
                EditorInspectorFieldValue::Bool(self.physics_allow_sleep_binding()),
            ),
            constrained(
                "physics-max-bodies",
                "Max Bodies",
                self.physics_capacity_binding(CapacitySetting::MaxBodies, 1, 1_000_000),
                1.0,
                1_000_000.0,
                1_024.0,
            ),
            constrained(
                "physics-workers",
                "Worker Threads (0 = Auto)",
                self.physics_capacity_binding(CapacitySetting::WorkerThreadCount, 0, 1_024),
                0.0,
                1_024.0,
                1.0,
            ),
        ];
        EditorInspectorSection::new("physics-settings", localized("Physics Settings"), fields)
    }

    fn update_physics_settings(&self, mutate: impl FnOnce(&mut PhysicsSettingsResource)) {
        let mut next = self
            .scene()
            .resource::<PhysicsSettingsResource>()
            .unwrap_or_default();
        mutate(&mut next);
        let sanitized = PhysicsSettingsResource::new(
            next.simulation_mode,
            next.backend_kind,
            next.gravity,
            next.fixed_time_step_seconds,
            next.max_substeps_per_frame,
            next.allow_sleep,
            next.collision_steps,
            next.capacity,
        );
        if self.scene().resource::<PhysicsSettingsResource>().as_ref() == Some(&sanitized) {
            return;
        }
        self.with_scene_mut(|scene| scene.set_resource(sanitized));
        self.notify_revision_changed_default();
    }

    fn physics_simulation_mode_binding(&self) -> Binding<PhysicsSimulationMode> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .resource::<PhysicsSettingsResource>()
                    .map(|settings| settings.simulation_mode)
                    .unwrap_or(PhysicsSimulationMode::Off)
            },
            move |next: PhysicsSimulationMode| {
                let current = set_adapter
                    .scene()
                    .resource::<PhysicsSettingsResource>()
                    .map(|settings| settings.simulation_mode);
                if current == Some(next) {
                    return;
                }
                set_adapter.with_physics_settings(|settings| settings.simulation_mode = next);
            },
        )
    }

    fn physics_backend_kind_binding(&self) -> Binding<PhysicsBackendKind> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .resource::<PhysicsSettingsResource>()
                    .unwrap_or_default()
                    .backend_kind
            },
            move |next: PhysicsBackendKind| {
                let current = set_adapter
                    .scene()
                    .resource::<PhysicsSettingsResource>()
                    .unwrap_or_default()
                    .backend_kind;
                if current == next {
                    return;
                }
                set_adapter.with_physics_settings(|settings| settings.backend_kind = next);
            },
        )
    }

    fn physics_gravity_binding(&self, axis: GravityAxis) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                let gravity = get_adapter
                    .scene()
                    .resource::<PhysicsSettingsResource>()
                    .map(|settings| settings.gravity)
                    .unwrap_or_else(|| PhysicsSettingsResource::default().gravity);
                gravity_component(gravity, axis)
            },
            move |next: f32| {
                let current = set_adapter
                    .scene()
                    .resource::<PhysicsSettingsResource>()
                    .unwrap_or_default();
                if gravity_component(current.gravity, axis) == next {
                    return;
                }
                set_adapter.with_physics_settings(|settings| {
                    settings.gravity = set_gravity_component(settings.gravity, axis, next)
                });
            },
        )
    }

    fn physics_fixed_time_step_binding(&self) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .resource::<PhysicsSettingsResource>()
                    .map(|settings| settings.fixed_time_step_seconds as f32)
                    .unwrap_or_else(|| {
                        PhysicsSettingsResource::default().fixed_time_step_seconds as f32
                    })
            },
            move |next: f32| {
                let clamped = next.clamp(0.000_001, 1.0);
                let current = set_adapter
                    .scene()
                    .resource::<PhysicsSettingsResource>()
                    .unwrap_or_default();
                if current.fixed_time_step_seconds as f32 == clamped {
                    return;
                }
                set_adapter.with_physics_settings(|settings| {
                    settings.fixed_time_step_seconds = f64::from(clamped)
                });
            },
        )
    }

    fn physics_integer_setting_binding(&self, setting: IntegerSetting) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                let settings = get_adapter
                    .scene()
                    .resource::<PhysicsSettingsResource>()
                    .unwrap_or_default();
                integer_setting(settings, setting) as f32
            },
            move |next: f32| {
                let clamped = (next.round() as i64).clamp(1, 64);
                let current = set_adapter
                    .scene()
                    .resource::<PhysicsSettingsResource>()
                    .unwrap_or_default();
                if integer_setting(current, setting) == clamped {
                    return;
                }
                set_adapter.with_physics_settings(|settings| {
                    set_integer_setting(settings, setting, clamped)
                });
            },
        )
    }

    fn physics_allow_sleep_binding(&self) -> Binding<bool> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .resource::<PhysicsSettingsResource>()
                    .map(|settings| settings.allow_sleep)
                    .unwrap_or(true)
            },
            move |next: bool| {
                let current = set_adapter
                    .scene()
                    .resource::<PhysicsSettingsResource>()
                    .unwrap_or_default();
                if current.allow_sleep == next {
                    return;
                }
                set_adapter.with_physics_settings(|settings| settings.allow_sleep = next);
            },
        )
    }

    fn physics_capacity_binding(
        &self,
        setting: CapacitySetting,
        minimum: i64,
        maximum: i64,
    ) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                let settings = get_adapter
                    .scene()
                    .resource::<PhysicsSettingsResource>()
                    .unwrap_or_default();
                capacity_setting(settings.capacity, setting) as f32
            },
            move |next: f32| {
                let clamped = (next.round() as i64).clamp(minimum, maximum);
                let current = set_adapter
                    .scene()
                    .resource::<PhysicsSettingsResource>()
                    .unwrap_or_default();
                if capacity_setting(current.capacity, setting) == clamped {
                    return;
                }
                set_adapter.with_physics_settings(|settings| {
                    settings.capacity = set_capacity_setting(settings.capacity, setting, clamped)
                });
            },
        )
    }
}

fn constrained(
    id: &str,
    label: &str,
    binding: Binding<f32>,
    min: f32,
    max: f32,
    step: f32,
) -> EditorInspectorField {
    EditorInspectorField::new(
        id,
        localized(label),
        EditorInspectorFieldValue::ConstrainedNumber {
            binding,
            min: Some(min),
            max: Some(max),
            step: Some(step),
            shows_stepper: true,
        },
    )
}

fn gravity_component(gravity: Float3, axis: GravityAxis) -> f32 {
    match axis {
        GravityAxis::X => gravity.x,
        GravityAxis::Y => gravity.y,
        GravityAxis::Z => gravity.z,
    }
}

fn set_gravity_component(gravity: Float3, axis: GravityAxis, value: f32) -> Float3 {
    match axis {
        GravityAxis::X => Float3::new(value, gravity.y, gravity.z),
        GravityAxis::Y => Float3::new(gravity.x, value, gravity.z),
        GravityAxis::Z => Float3::new(gravity.x, gravity.y, value),
    }
}

fn integer_setting(settings: PhysicsSettingsResource, setting: IntegerSetting) -> i64 {
    match setting {
        IntegerSetting::MaxSubstepsPerFrame => settings.max_substeps_per_frame,
        IntegerSetting::CollisionSteps => settings.collision_steps,
    }
}

fn set_integer_setting(
    settings: &mut PhysicsSettingsResource,
    setting: IntegerSetting,
    value: i64,
) {
    match setting {
        IntegerSetting::MaxSubstepsPerFrame => settings.max_substeps_per_frame = value,
        IntegerSetting::CollisionSteps => settings.collision_steps = value,
    }
}

fn capacity_setting(capacity: PhysicsCapacitySettings, setting: CapacitySetting) -> i64 {
    match setting {
        CapacitySetting::MaxBodies => capacity.max_bodies,
        CapacitySetting::WorkerThreadCount => capacity.worker_thread_count,
    }
}

fn set_capacity_setting(
    capacity: PhysicsCapacitySettings,
    setting: CapacitySetting,
    value: i64,
) -> PhysicsCapacitySettings {
    match setting {
        CapacitySetting::MaxBodies => {
            PhysicsCapacitySettings::new(value, capacity.worker_thread_count)
        }
        CapacitySetting::WorkerThreadCount => {
            PhysicsCapacitySettings::new(capacity.max_bodies, value)
        }
    }
}

impl EditorSceneAdapter {
    /// Shared by every physics-settings binding.
    fn with_physics_settings(&self, mutate: impl FnOnce(&mut PhysicsSettingsResource)) {
        self.update_physics_settings(mutate);
    }
}
