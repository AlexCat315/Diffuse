//! `Editor/Sources/EditorCore/Scene/Inspector/Choices/PhysicsChoices.swift`.

use diffuse_scene::physics::backend::physics_backend_kind::PhysicsBackendKind;
use diffuse_scene::physics::collider::ColliderShapeKind;
use diffuse_scene::physics::joints::physics_joint_configuration::{
    PhysicsJointKind, PhysicsJointMotorMode,
};
use diffuse_scene::physics::physics_types::PhysicsSimulationMode;
use diffuse_scene::physics::vehicles::vehicle_controller_configuration::VehicleControllerKind;

use crate::localization::localized;
use crate::scene::inspector::enum_options::EditorInspectorEnumOption;

impl EditorInspectorEnumOption for PhysicsSimulationMode {
    const ALL: &'static [Self] = &PhysicsSimulationMode::ALL;

    fn inspector_option_id(&self) -> String {
        self.raw_value().to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            PhysicsSimulationMode::Off => localized("Off"),
            PhysicsSimulationMode::Preview => localized("Preview"),
            PhysicsSimulationMode::Play => localized("Play"),
            PhysicsSimulationMode::Bake => localized("Bake"),
        }
    }
}

impl EditorInspectorEnumOption for VehicleControllerKind {
    const ALL: &'static [Self] = &VehicleControllerKind::ALL;

    fn inspector_option_id(&self) -> String {
        match self {
            VehicleControllerKind::Wheeled => "wheeled",
            VehicleControllerKind::Tracked => "tracked",
            VehicleControllerKind::Motorcycle => "motorcycle",
        }
        .to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            VehicleControllerKind::Wheeled => localized("Wheeled"),
            VehicleControllerKind::Tracked => localized("Tracked"),
            VehicleControllerKind::Motorcycle => localized("Motorcycle"),
        }
    }
}

impl EditorInspectorEnumOption for ColliderShapeKind {
    const ALL: &'static [Self] = &ColliderShapeKind::ALL;

    fn inspector_option_id(&self) -> String {
        self.raw_value().to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            ColliderShapeKind::Box => localized("Box"),
            ColliderShapeKind::Sphere => localized("Sphere"),
            ColliderShapeKind::Capsule => localized("Capsule"),
            ColliderShapeKind::Cylinder => localized("Cylinder"),
            ColliderShapeKind::HeightField => localized("Height Field"),
            ColliderShapeKind::Mesh => localized("Mesh"),
            ColliderShapeKind::Convex => localized("Convex"),
        }
    }
}

impl EditorInspectorEnumOption for PhysicsJointKind {
    const ALL: &'static [Self] = &PhysicsJointKind::ALL;

    fn inspector_option_id(&self) -> String {
        self.raw_value().to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            PhysicsJointKind::PointToPoint => localized("Point"),
            PhysicsJointKind::Fixed => localized("Fixed"),
            PhysicsJointKind::Distance => localized("Distance"),
            PhysicsJointKind::Hinge => localized("Hinge"),
            PhysicsJointKind::Slider => localized("Slider"),
            PhysicsJointKind::Cone => localized("Cone / Swing Twist"),
            PhysicsJointKind::SixDof => localized("Six DOF"),
        }
    }
}

impl EditorInspectorEnumOption for PhysicsJointMotorMode {
    const ALL: &'static [Self] = &[
        PhysicsJointMotorMode::Disabled,
        PhysicsJointMotorMode::Position,
        PhysicsJointMotorMode::Velocity,
    ];

    fn inspector_option_id(&self) -> String {
        self.raw_value().to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            PhysicsJointMotorMode::Disabled => localized("Disabled"),
            PhysicsJointMotorMode::Position => localized("Position"),
            PhysicsJointMotorMode::Velocity => localized("Velocity"),
        }
    }
}

impl EditorInspectorEnumOption for PhysicsBackendKind {
    const ALL: &'static [Self] = &PhysicsBackendKind::ALL;

    fn inspector_option_id(&self) -> String {
        self.raw_value().to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            PhysicsBackendKind::None => localized("None"),
            PhysicsBackendKind::Natsel => "Natsel".to_string(),
        }
    }
}
