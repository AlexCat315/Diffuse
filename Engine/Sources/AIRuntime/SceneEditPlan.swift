import Foundation

/// Operations Claude can request in a `SceneEditStep`.
/// Each raw value is the JSON `"op"` string Claude returns.
public enum SceneEditOp: String, Codable, Sendable, CaseIterable {
    // Entity lifecycle
    case spawnEntity       = "spawn_entity"
    case deleteEntity      = "delete_entity"
    case duplicateEntity   = "duplicate_entity"
    case setName           = "set_name"

    // Spatial
    case setTransform      = "set_transform"
    case snapToGround      = "snap_to_ground"

    // Lighting
    case setLightType      = "set_light_type"
    case setLightIntensity = "set_light_intensity"
    case setLightColor     = "set_light_color"
    case setLightRange     = "set_light_range"
    case setLightSpotAngles = "set_light_spot_angles"

    // Camera
    case setCameraPose     = "set_camera_pose"

    // Physics
    case setRigidBodyMotion   = "set_rigidbody_motion"
    case setRigidBodyMass     = "set_rigidbody_mass"
    case setRigidBodyGravity  = "set_rigidbody_gravity"
    case setColliderTrigger   = "set_collider_trigger"
    case setConstraintEnabled = "set_constraint_enabled"
}

/// One atomic mutation step in a `SceneEditPlan`.
///
/// All fields except `op` and `entityRef` are optional. Which fields are
/// required for each `op` is described in `AIScenePlanner`'s tool schema.
public struct SceneEditStep: Codable, Sendable {
    public var op: SceneEditOp

    /// Target entity — `"scene:<rawID>"`. Not required for `spawn_entity`.
    public var entityRef: String?

    // spawn_entity
    public var label: String?          // entity name for spawned entity
    public var spawnPosition: [Float]? // [x, y, z] default [0,0,0]

    // set_transform / snap_to_ground
    public var position: [Float]?      // [x, y, z] metres
    public var eulerDegrees: [Float]?  // [x, y, z] XYZ intrinsic rotation in degrees
    public var scale: [Float]?         // [x, y, z]

    // set_name
    public var name: String?

    // set_light_type
    public var lightType: String?      // "directional" | "point" | "spot"

    // set_light_intensity
    public var intensity: Float?

    // set_light_color
    public var color: [Float]?         // [r, g, b] linear 0–1

    // set_light_range
    public var range: Float?

    // set_light_spot_angles
    public var spotInnerAngleDegrees: Float?
    public var spotOuterAngleDegrees: Float?

    // set_camera_pose
    public var cameraTarget: [Float]?  // [x, y, z] look-at point
    public var cameraUp: [Float]?      // [x, y, z] default [0,1,0]

    // set_rigidbody_motion
    public var motionType: String?     // "static" | "dynamic" | "kinematic"

    // set_rigidbody_mass
    public var mass: Float?

    // set_rigidbody_gravity
    public var gravityScale: Float?

    // set_collider_trigger
    public var isTrigger: Bool?

    // set_constraint_enabled
    public var isEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case op
        case entityRef          = "entity_id"
        case label
        case spawnPosition      = "spawn_position"
        case position
        case eulerDegrees       = "euler_degrees"
        case scale
        case name
        case lightType          = "light_type"
        case intensity
        case color
        case range
        case spotInnerAngleDegrees = "spot_inner_angle"
        case spotOuterAngleDegrees = "spot_outer_angle"
        case cameraTarget       = "camera_target"
        case cameraUp           = "camera_up"
        case motionType         = "motion_type"
        case mass
        case gravityScale       = "gravity_scale"
        case isTrigger          = "is_trigger"
        case isEnabled          = "is_enabled"
    }
}

/// A multi-step AI-generated scene edit plan.
/// Decoded from Claude's `execute_edit_plan` tool call input.
public struct SceneEditPlan: Codable, Sendable {
    /// One-line description of what the plan achieves.
    public var summary: String

    /// Claude's reasoning — useful for debugging and training logs.
    public var reasoning: String?

    /// Ordered list of mutations to execute atomically.
    public var steps: [SceneEditStep]

    public var isEmpty: Bool { steps.isEmpty }
}
