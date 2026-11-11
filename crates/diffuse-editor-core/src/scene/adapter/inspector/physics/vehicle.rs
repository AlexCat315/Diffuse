//! `Editor/Sources/EditorCore/Scene/Adapter/Inspector/Physics/Vehicle.swift`.

use cove_ui_compose::scene_core::Binding;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::physics::ragdoll::Ragdoll;
use diffuse_scene::physics::vehicles::vehicle::Vehicle;
use diffuse_scene::physics::vehicles::vehicle_controller_configuration::{
    MotorcycleVehicleConfiguration, VehicleControllerConfiguration, VehicleControllerKind,
};
use diffuse_scene::physics::vehicles::vehicle_powertrain::{
    VehicleEngineConfiguration, VehicleTransmissionConfiguration,
};
use diffuse_scene::physics::vehicles::vehicle_wheel_configuration::VehicleTransmissionMode;

use crate::localization::localized;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::{
    EditorInspectorField, EditorInspectorFieldValue, EditorInspectorSection,
};

#[derive(Clone, Copy)]
enum EngineField {
    MaxTorque,
}

#[derive(Clone, Copy)]
enum TransmissionField {
    ClutchStrength,
}

#[derive(Clone, Copy)]
enum TrackedField {
    LongitudinalFriction,
    LateralFriction,
}

#[derive(Clone, Copy)]
enum MotorcycleField {
    MaxLeanAngle,
    LeanSpringConstant,
}

impl EditorSceneAdapter {
    pub(crate) fn vehicle_section(&self, entity: EntityID) -> Option<EditorInspectorSection> {
        let vehicle = self.scene().component::<Vehicle>(entity)?;
        let state = self
            .scene()
            .vehicle_state_frame()
            .states
            .get(&entity)
            .cloned();
        let contact_count = state
            .as_ref()
            .map(|state| {
                state
                    .wheels
                    .iter()
                    .filter(|wheel| wheel.has_contact)
                    .count()
            })
            .unwrap_or(0);
        let mut fields: Vec<EditorInspectorField> = vec![
            EditorInspectorField::new(
                "vehicle-enabled",
                localized("Enabled"),
                EditorInspectorFieldValue::Bool(self.vehicle_enabled_binding(entity)),
            ),
            EditorInspectorField::new(
                "vehicle-controller",
                localized("Controller"),
                EditorInspectorFieldValue::options(&self.vehicle_controller_kind_binding(entity)),
            ),
            EditorInspectorField::new(
                "vehicle-wheels",
                localized("Wheels"),
                EditorInspectorFieldValue::ReadOnly(vehicle.wheels.len().to_string()),
            ),
            EditorInspectorField::new(
                "vehicle-differentials",
                localized("Differentials"),
                EditorInspectorFieldValue::ReadOnly(vehicle.differentials.len().to_string()),
            ),
            EditorInspectorField::new(
                "vehicle-transmission",
                localized("Transmission"),
                EditorInspectorFieldValue::ReadOnly(
                    if vehicle.transmission.mode == VehicleTransmissionMode::Automatic {
                        localized("Automatic")
                    } else {
                        localized("Manual")
                    },
                ),
            ),
            constrained(
                "vehicle-max-torque",
                "Max Torque",
                self.vehicle_engine_float_binding(entity, EngineField::MaxTorque),
                0.0,
                None,
                10.0,
            ),
            constrained(
                "vehicle-clutch-strength",
                "Clutch Strength",
                self.vehicle_transmission_float_binding(entity, TransmissionField::ClutchStrength),
                0.0,
                None,
                0.5,
            ),
        ];
        match &vehicle.controller {
            VehicleControllerConfiguration::Wheeled => {}
            VehicleControllerConfiguration::Tracked(_) => {
                fields.push(constrained(
                    "vehicle-track-longitudinal-friction",
                    "Track Forward Friction",
                    self.vehicle_tracked_float_binding(entity, TrackedField::LongitudinalFriction),
                    0.0,
                    None,
                    0.1,
                ));
                fields.push(constrained(
                    "vehicle-track-lateral-friction",
                    "Track Side Friction",
                    self.vehicle_tracked_float_binding(entity, TrackedField::LateralFriction),
                    0.0,
                    None,
                    0.1,
                ));
            }
            VehicleControllerConfiguration::Motorcycle(_) => {
                fields.push(constrained(
                    "vehicle-motorcycle-max-lean",
                    "Max Lean Angle",
                    self.vehicle_motorcycle_float_binding(entity, MotorcycleField::MaxLeanAngle),
                    0.0,
                    Some(std::f32::consts::FRAC_PI_2),
                    0.05,
                ));
                fields.push(constrained(
                    "vehicle-motorcycle-lean-spring",
                    "Lean Spring",
                    self.vehicle_motorcycle_float_binding(
                        entity,
                        MotorcycleField::LeanSpringConstant,
                    ),
                    0.0,
                    None,
                    100.0,
                ));
                fields.push(EditorInspectorField::new(
                    "vehicle-motorcycle-lean-enabled",
                    localized("Lean Controller"),
                    EditorInspectorFieldValue::Bool(
                        self.vehicle_motorcycle_lean_enabled_binding(entity),
                    ),
                ));
            }
        }
        let forward_speed = state
            .as_ref()
            .map(|state| state.forward_speed)
            .unwrap_or(0.0);
        let engine_rpm = state.as_ref().map(|state| state.engine_rpm).unwrap_or(0.0);
        let current_gear = state.as_ref().map(|state| state.current_gear).unwrap_or(0);
        fields.push(EditorInspectorField::new(
            "vehicle-speed",
            localized("Forward Speed"),
            EditorInspectorFieldValue::ReadOnly(self.format(forward_speed)),
        ));
        fields.push(EditorInspectorField::new(
            "vehicle-engine-rpm",
            localized("Engine RPM"),
            EditorInspectorFieldValue::ReadOnly(self.format(engine_rpm)),
        ));
        fields.push(EditorInspectorField::new(
            "vehicle-current-gear",
            localized("Current Gear"),
            EditorInspectorFieldValue::ReadOnly(current_gear.to_string()),
        ));
        fields.push(EditorInspectorField::new(
            "vehicle-wheel-contacts",
            localized("Wheel Contacts"),
            EditorInspectorFieldValue::ReadOnly(format!(
                "{contact_count} / {}",
                vehicle.wheels.len()
            )),
        ));
        Some(EditorInspectorSection::new(
            "vehicle",
            localized("Vehicle"),
            fields,
        ))
    }

    pub(crate) fn ragdoll_section(&self, entity: EntityID) -> Option<EditorInspectorSection> {
        let ragdoll = self.scene().component::<Ragdoll>(entity)?;
        let state = self
            .scene()
            .ragdoll_state_frame()
            .states
            .get(&entity)
            .cloned();
        let simulated_count = state
            .as_ref()
            .map(|state| state.bones.iter().filter(|bone| bone.is_simulated).count())
            .unwrap_or(0);
        Some(EditorInspectorSection::new(
            "ragdoll",
            localized("Ragdoll"),
            vec![
                EditorInspectorField::new(
                    "ragdoll-enabled",
                    localized("Enabled"),
                    EditorInspectorFieldValue::Bool(self.ragdoll_enabled_binding(entity)),
                ),
                EditorInspectorField::new(
                    "ragdoll-mode",
                    localized("Mode"),
                    EditorInspectorFieldValue::ReadOnly(ragdoll.mode.raw_value().to_string()),
                ),
                EditorInspectorField::new(
                    "ragdoll-blend-weight",
                    localized("Blend Weight"),
                    EditorInspectorFieldValue::ConstrainedNumber {
                        binding: self.ragdoll_blend_weight_binding(entity),
                        min: Some(0.0),
                        max: Some(1.0),
                        step: Some(0.05),
                        shows_stepper: true,
                    },
                ),
                EditorInspectorField::new(
                    "ragdoll-bones",
                    localized("Bones"),
                    EditorInspectorFieldValue::ReadOnly(ragdoll.bones.len().to_string()),
                ),
                EditorInspectorField::new(
                    "ragdoll-simulated-bones",
                    localized("Simulated Bones"),
                    EditorInspectorFieldValue::ReadOnly(simulated_count.to_string()),
                ),
            ],
        ))
    }

    fn vehicle_controller_kind_binding(&self, entity: EntityID) -> Binding<VehicleControllerKind> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<Vehicle>(entity)
                    .map(|vehicle| vehicle.controller.kind())
                    .unwrap_or(VehicleControllerKind::Wheeled)
            },
            move |kind: VehicleControllerKind| {
                let Some(current) = set_adapter.scene().component::<Vehicle>(entity) else {
                    return;
                };
                if current.controller.kind() == kind {
                    return;
                }
                let mut next = match kind {
                    VehicleControllerKind::Wheeled => {
                        let mut wheeled = Vehicle::wheeled();
                        wheeled.engine = current.engine;
                        wheeled.transmission = current.transmission;
                        wheeled
                    }
                    VehicleControllerKind::Tracked => {
                        Vehicle::tracked(current.engine, current.transmission)
                    }
                    VehicleControllerKind::Motorcycle => Vehicle::motorcycle(
                        MotorcycleVehicleConfiguration::default(),
                        current.engine,
                        current.transmission,
                    ),
                };
                next.up = current.up;
                next.forward = current.forward;
                next.max_pitch_roll_angle = current.max_pitch_roll_angle;
                next.is_enabled = current.is_enabled;
                let _ = set_adapter.set_component_data(next, entity);
            },
        )
    }

    fn vehicle_enabled_binding(&self, entity: EntityID) -> Binding<bool> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<Vehicle>(entity)
                    .map(|vehicle| vehicle.is_enabled)
                    .unwrap_or(false)
            },
            move |value: bool| {
                let current = set_adapter
                    .scene()
                    .component::<Vehicle>(entity)
                    .map(|vehicle| vehicle.is_enabled);
                if current == Some(value) {
                    return;
                }
                let _ = set_adapter.update_component_data::<Vehicle>(entity, |vehicle| {
                    vehicle.is_enabled = value;
                });
            },
        )
    }

    fn vehicle_engine_float_binding(&self, entity: EntityID, field: EngineField) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<Vehicle>(entity)
                    .map(|vehicle| engine_float(&vehicle.engine, field))
                    .unwrap_or(0.0)
            },
            move |next: f32| {
                let value = next.max(0.0);
                let _ = set_adapter.update_component_data::<Vehicle>(entity, |vehicle| {
                    set_engine_float(&mut vehicle.engine, field, value);
                });
            },
        )
    }

    fn vehicle_transmission_float_binding(
        &self,
        entity: EntityID,
        field: TransmissionField,
    ) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<Vehicle>(entity)
                    .map(|vehicle| transmission_float(&vehicle.transmission, field))
                    .unwrap_or(0.0)
            },
            move |next: f32| {
                let value = next.max(0.0);
                let _ = set_adapter.update_component_data::<Vehicle>(entity, |vehicle| {
                    set_transmission_float(&mut vehicle.transmission, field, value);
                });
            },
        )
    }

    fn vehicle_tracked_float_binding(&self, entity: EntityID, field: TrackedField) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                let Some(vehicle) = get_adapter.scene().component::<Vehicle>(entity) else {
                    return 0.0;
                };
                match &vehicle.controller {
                    VehicleControllerConfiguration::Tracked(configuration) => {
                        tracked_float(configuration, field)
                    }
                    _ => 0.0,
                }
            },
            move |next: f32| {
                let value = next.max(0.0);
                let _ = set_adapter.update_component_data::<Vehicle>(entity, |vehicle| {
                    let VehicleControllerConfiguration::Tracked(configuration) =
                        &mut vehicle.controller
                    else {
                        return;
                    };
                    set_tracked_float(configuration, field, value);
                });
            },
        )
    }

    fn vehicle_motorcycle_float_binding(
        &self,
        entity: EntityID,
        field: MotorcycleField,
    ) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                let Some(vehicle) = get_adapter.scene().component::<Vehicle>(entity) else {
                    return 0.0;
                };
                match &vehicle.controller {
                    VehicleControllerConfiguration::Motorcycle(configuration) => {
                        motorcycle_float(configuration, field)
                    }
                    _ => 0.0,
                }
            },
            move |next: f32| {
                let mut value = next.max(0.0);
                if matches!(field, MotorcycleField::MaxLeanAngle) {
                    value = value.min(std::f32::consts::FRAC_PI_2);
                }
                let _ = set_adapter.update_component_data::<Vehicle>(entity, |vehicle| {
                    let VehicleControllerConfiguration::Motorcycle(configuration) =
                        &mut vehicle.controller
                    else {
                        return;
                    };
                    set_motorcycle_float(configuration, field, value);
                });
            },
        )
    }

    fn vehicle_motorcycle_lean_enabled_binding(&self, entity: EntityID) -> Binding<bool> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                let Some(vehicle) = get_adapter.scene().component::<Vehicle>(entity) else {
                    return false;
                };
                match &vehicle.controller {
                    VehicleControllerConfiguration::Motorcycle(configuration) => {
                        configuration.is_lean_controller_enabled
                    }
                    _ => false,
                }
            },
            move |value: bool| {
                let _ = set_adapter.update_component_data::<Vehicle>(entity, |vehicle| {
                    let VehicleControllerConfiguration::Motorcycle(configuration) =
                        &mut vehicle.controller
                    else {
                        return;
                    };
                    configuration.is_lean_controller_enabled = value;
                });
            },
        )
    }

    fn ragdoll_enabled_binding(&self, entity: EntityID) -> Binding<bool> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<Ragdoll>(entity)
                    .map(|ragdoll| ragdoll.is_enabled)
                    .unwrap_or(false)
            },
            move |value: bool| {
                let current = set_adapter
                    .scene()
                    .component::<Ragdoll>(entity)
                    .map(|ragdoll| ragdoll.is_enabled);
                if current == Some(value) {
                    return;
                }
                let _ = set_adapter.update_component_data::<Ragdoll>(entity, |ragdoll| {
                    ragdoll.is_enabled = value;
                });
            },
        )
    }

    fn ragdoll_blend_weight_binding(&self, entity: EntityID) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<Ragdoll>(entity)
                    .map(|ragdoll| ragdoll.blend_weight)
                    .unwrap_or(1.0)
            },
            move |value: f32| {
                let clamped = value.clamp(0.0, 1.0);
                let current = set_adapter
                    .scene()
                    .component::<Ragdoll>(entity)
                    .map(|ragdoll| ragdoll.blend_weight);
                if current == Some(clamped) {
                    return;
                }
                let _ = set_adapter.update_component_data::<Ragdoll>(entity, |ragdoll| {
                    ragdoll.blend_weight = clamped;
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
    max: Option<f32>,
    step: f32,
) -> EditorInspectorField {
    EditorInspectorField::new(
        id,
        localized(label),
        EditorInspectorFieldValue::ConstrainedNumber {
            binding,
            min: Some(min),
            max,
            step: Some(step),
            shows_stepper: true,
        },
    )
}

fn engine_float(engine: &VehicleEngineConfiguration, field: EngineField) -> f32 {
    match field {
        EngineField::MaxTorque => engine.max_torque,
    }
}

fn set_engine_float(engine: &mut VehicleEngineConfiguration, field: EngineField, value: f32) {
    match field {
        EngineField::MaxTorque => engine.max_torque = value,
    }
}

fn transmission_float(
    transmission: &VehicleTransmissionConfiguration,
    field: TransmissionField,
) -> f32 {
    match field {
        TransmissionField::ClutchStrength => transmission.clutch_strength,
    }
}

fn set_transmission_float(
    transmission: &mut VehicleTransmissionConfiguration,
    field: TransmissionField,
    value: f32,
) {
    match field {
        TransmissionField::ClutchStrength => transmission.clutch_strength = value,
    }
}

fn tracked_float(
    configuration: &diffuse_scene::physics::vehicles::vehicle_controller_configuration::TrackedVehicleConfiguration,
    field: TrackedField,
) -> f32 {
    match field {
        TrackedField::LongitudinalFriction => configuration.longitudinal_friction,
        TrackedField::LateralFriction => configuration.lateral_friction,
    }
}

fn set_tracked_float(
    configuration: &mut diffuse_scene::physics::vehicles::vehicle_controller_configuration::TrackedVehicleConfiguration,
    field: TrackedField,
    value: f32,
) {
    match field {
        TrackedField::LongitudinalFriction => configuration.longitudinal_friction = value,
        TrackedField::LateralFriction => configuration.lateral_friction = value,
    }
}

fn motorcycle_float(configuration: &MotorcycleVehicleConfiguration, field: MotorcycleField) -> f32 {
    match field {
        MotorcycleField::MaxLeanAngle => configuration.max_lean_angle,
        MotorcycleField::LeanSpringConstant => configuration.lean_spring_constant,
    }
}

fn set_motorcycle_float(
    configuration: &mut MotorcycleVehicleConfiguration,
    field: MotorcycleField,
    value: f32,
) {
    match field {
        MotorcycleField::MaxLeanAngle => configuration.max_lean_angle = value,
        MotorcycleField::LeanSpringConstant => configuration.lean_spring_constant = value,
    }
}
