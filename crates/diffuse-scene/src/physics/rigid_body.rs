//! Authored rigid-body state.
//!
//! Swift's `RigidBodyAxisLocks` is an `OptionSet` over `UInt8`; the Rust port keeps
//! the raw bit layout so persisted values stay identical.

use diffuse_math::simd::simd_compat::Float3;

use crate::entity_id::RuntimeComponent;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RigidBodyMotionType {
    Static,
    Dynamic,
    Kinematic,
}

/// Swift raw values are the case names; persisting uses
/// `RigidBodyMotionType.rawValue`.
impl RigidBodyMotionType {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            RigidBodyMotionType::Static => "static",
            RigidBodyMotionType::Dynamic => "dynamic",
            RigidBodyMotionType::Kinematic => "kinematic",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "static" => Some(RigidBodyMotionType::Static),
            "dynamic" => Some(RigidBodyMotionType::Dynamic),
            "kinematic" => Some(RigidBodyMotionType::Kinematic),
            _ => None,
        }
    }

    /// `CaseIterable` order from Swift.
    pub const ALL: [RigidBodyMotionType; 3] = [
        RigidBodyMotionType::Static,
        RigidBodyMotionType::Dynamic,
        RigidBodyMotionType::Kinematic,
    ];
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RigidBodyMassMode {
    Mass,
    Density,
}

impl RigidBodyMassMode {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            RigidBodyMassMode::Mass => "mass",
            RigidBodyMassMode::Density => "density",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "mass" => Some(RigidBodyMassMode::Mass),
            "density" => Some(RigidBodyMassMode::Density),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RigidBodyMotionQuality {
    Discrete,
    LinearCast,
}

impl RigidBodyMotionQuality {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            RigidBodyMotionQuality::Discrete => "discrete",
            RigidBodyMotionQuality::LinearCast => "linearCast",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "discrete" => Some(RigidBodyMotionQuality::Discrete),
            "linearCast" => Some(RigidBodyMotionQuality::LinearCast),
            _ => None,
        }
    }
}

/// `RigidBodyAxisLocks: OptionSet` over `UInt8`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct RigidBodyAxisLocks {
    pub raw_value: u8,
}

impl RigidBodyAxisLocks {
    pub const TRANSLATION_X: RigidBodyAxisLocks = RigidBodyAxisLocks { raw_value: 1 << 0 };
    pub const TRANSLATION_Y: RigidBodyAxisLocks = RigidBodyAxisLocks { raw_value: 1 << 1 };
    pub const TRANSLATION_Z: RigidBodyAxisLocks = RigidBodyAxisLocks { raw_value: 1 << 2 };
    pub const ROTATION_X: RigidBodyAxisLocks = RigidBodyAxisLocks { raw_value: 1 << 3 };
    pub const ROTATION_Y: RigidBodyAxisLocks = RigidBodyAxisLocks { raw_value: 1 << 4 };
    pub const ROTATION_Z: RigidBodyAxisLocks = RigidBodyAxisLocks { raw_value: 1 << 5 };

    #[inline]
    pub const fn new(raw_value: u8) -> Self {
        RigidBodyAxisLocks { raw_value }
    }

    #[inline]
    pub const fn contains(&self, other: RigidBodyAxisLocks) -> bool {
        (self.raw_value & other.raw_value) == other.raw_value
    }

    #[inline]
    pub fn insert(&mut self, other: RigidBodyAxisLocks) {
        self.raw_value |= other.raw_value;
    }

    #[inline]
    pub fn remove(&mut self, other: RigidBodyAxisLocks) {
        self.raw_value &= !other.raw_value;
    }
}

/// Desired transform for a kinematic body.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicsKinematicTarget {
    pub position: Float3,
    /// Quaternion encoded as `(x, y, z, w)`.
    pub rotation: diffuse_math::simd::simd_compat::Float4,
}

impl PhysicsKinematicTarget {
    pub fn new(position: Float3) -> Self {
        PhysicsKinematicTarget {
            position,
            rotation: diffuse_math::simd::simd_compat::Float4::new(0.0, 0.0, 0.0, 1.0),
        }
    }

    pub fn with_rotation(
        position: Float3,
        rotation: diffuse_math::simd::simd_compat::Float4,
    ) -> Self {
        PhysicsKinematicTarget { position, rotation }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RigidBody {
    pub motion_type: RigidBodyMotionType,
    pub mass: f32,
    pub mass_mode: RigidBodyMassMode,
    pub linear_velocity: Float3,
    pub angular_velocity: Float3,
    pub accumulated_force: Float3,
    pub accumulated_torque: Float3,
    pub accumulated_linear_impulse: Float3,
    pub accumulated_angular_impulse: Float3,
    pub gravity_scale: f32,
    pub linear_damping: f32,
    pub angular_damping: f32,
    pub allow_sleep: bool,
    pub is_sleeping: bool,
    pub continuous_collision_detection: bool,
    pub center_of_mass_override: Option<Float3>,
    pub inertia_diagonal_override: Option<Float3>,
    pub axis_locks: RigidBodyAxisLocks,
    pub max_linear_velocity: f32,
    pub max_angular_velocity: f32,
    pub motion_quality: RigidBodyMotionQuality,
    pub kinematic_target: Option<PhysicsKinematicTarget>,
}

/// Swift's `init(...)` defaults. Kept as a builder so the clamping rules live in
/// exactly one place.
#[derive(Clone, Debug, PartialEq)]
pub struct RigidBodyOptions {
    pub motion_type: RigidBodyMotionType,
    pub mass: f32,
    pub mass_mode: RigidBodyMassMode,
    pub linear_velocity: Float3,
    pub angular_velocity: Float3,
    pub accumulated_force: Float3,
    pub accumulated_torque: Float3,
    pub accumulated_linear_impulse: Float3,
    pub accumulated_angular_impulse: Float3,
    pub gravity_scale: f32,
    pub linear_damping: f32,
    pub angular_damping: f32,
    pub allow_sleep: bool,
    pub is_sleeping: bool,
    pub continuous_collision_detection: bool,
    pub center_of_mass_override: Option<Float3>,
    pub inertia_diagonal_override: Option<Float3>,
    pub axis_locks: RigidBodyAxisLocks,
    pub max_linear_velocity: f32,
    pub max_angular_velocity: f32,
    pub motion_quality: RigidBodyMotionQuality,
    pub kinematic_target: Option<PhysicsKinematicTarget>,
}

impl Default for RigidBodyOptions {
    fn default() -> Self {
        RigidBodyOptions {
            motion_type: RigidBodyMotionType::Dynamic,
            mass: 1.0,
            mass_mode: RigidBodyMassMode::Mass,
            linear_velocity: Float3::ZERO,
            angular_velocity: Float3::ZERO,
            accumulated_force: Float3::ZERO,
            accumulated_torque: Float3::ZERO,
            accumulated_linear_impulse: Float3::ZERO,
            accumulated_angular_impulse: Float3::ZERO,
            gravity_scale: 1.0,
            linear_damping: 0.04,
            angular_damping: 0.04,
            allow_sleep: true,
            is_sleeping: false,
            continuous_collision_detection: false,
            center_of_mass_override: None,
            inertia_diagonal_override: None,
            axis_locks: RigidBodyAxisLocks::new(0),
            max_linear_velocity: 500.0,
            // 0.25 * .pi * 60
            max_angular_velocity: 0.25 * std::f32::consts::PI * 60.0,
            motion_quality: RigidBodyMotionQuality::Discrete,
            kinematic_target: None,
        }
    }
}

impl RigidBody {
    pub fn new(options: RigidBodyOptions) -> Self {
        RigidBody {
            motion_type: options.motion_type,
            mass: options.mass,
            mass_mode: options.mass_mode,
            linear_velocity: options.linear_velocity,
            angular_velocity: options.angular_velocity,
            accumulated_force: options.accumulated_force,
            accumulated_torque: options.accumulated_torque,
            accumulated_linear_impulse: options.accumulated_linear_impulse,
            accumulated_angular_impulse: options.accumulated_angular_impulse,
            gravity_scale: options.gravity_scale,
            linear_damping: options.linear_damping,
            angular_damping: options.angular_damping,
            allow_sleep: options.allow_sleep,
            is_sleeping: options.is_sleeping,
            continuous_collision_detection: options.continuous_collision_detection,
            center_of_mass_override: options.center_of_mass_override,
            inertia_diagonal_override: options.inertia_diagonal_override,
            axis_locks: options.axis_locks,
            max_linear_velocity: options.max_linear_velocity.max(0.0),
            max_angular_velocity: options.max_angular_velocity.max(0.0),
            // `init` forces linear cast whenever CCD is on, regardless of the
            // supplied motion quality.
            motion_quality: if options.continuous_collision_detection {
                RigidBodyMotionQuality::LinearCast
            } else {
                options.motion_quality
            },
            kinematic_target: options.kinematic_target,
        }
    }
}

impl Default for RigidBody {
    fn default() -> Self {
        RigidBody::new(RigidBodyOptions::default())
    }
}

impl RuntimeComponent for RigidBody {}
