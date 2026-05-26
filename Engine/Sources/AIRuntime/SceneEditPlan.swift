import Foundation

/// A JSON-typed value that can be a string, number, or boolean.
/// Used for `set_script_property` where the AI sets a typed script parameter.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        let s = try c.decode(String.self)
        self = .string(s)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b):   try c.encode(b)
        }
    }

    /// Returns the value as its JSON representation for embedding in a JSON object.
    public var jsonFragment: String {
        switch self {
        case .string(let s):
            let escaped = s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        case .number(let n):
            return n.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", n)
                : String(n)
        case .bool(let b): return b ? "true" : "false"
        }
    }
}

/// Operations Claude can request in a `SceneEditStep`.
/// Each raw value is the JSON `"op"` string Claude returns.
public enum SceneEditOp: String, Codable, Sendable, CaseIterable {
    // Entity lifecycle
    case spawnEntity       = "spawn_entity"
    case deleteEntity      = "delete_entity"
    case duplicateEntity   = "duplicate_entity"
    case setName           = "set_name"
    case reparentEntity    = "reparent_entity"

    // Spatial
    case setTransform      = "set_transform"
    case snapToGround      = "snap_to_ground"

    // Lighting
    case setLightType        = "set_light_type"
    case setLightIntensity   = "set_light_intensity"
    case setLightColor       = "set_light_color"
    case setLightRange       = "set_light_range"
    case setLightSpotAngles  = "set_light_spot_angles"
    case setLightCastShadows = "set_light_cast_shadows"

    // Camera
    case setCameraPose     = "set_camera_pose"
    case setCameraFOV      = "set_camera_fov"
    case setCameraActive   = "set_camera_active"

    // Visual
    case setMeshColor         = "set_mesh_color"
    case setMaterial          = "set_material"

    // Physics — rigidbody
    case setRigidBodyMotion   = "set_rigidbody_motion"
    case setRigidBodyMass     = "set_rigidbody_mass"
    case setRigidBodyGravity  = "set_rigidbody_gravity"
    case setRigidBodyAllowSleep = "set_rigidbody_allow_sleep"

    // Physics — collider shape
    case setColliderShape        = "set_collider_shape"
    case setColliderBoxExtents   = "set_collider_box_extents"
    case setColliderSphereRadius = "set_collider_sphere_radius"
    case setColliderCapsule      = "set_collider_capsule"

    // Physics — collider material
    case setColliderMaterial  = "set_collider_material"

    // Physics — misc
    case setColliderTrigger   = "set_collider_trigger"
    case setColliderLayer     = "set_collider_layer"
    case setConstraintEnabled = "set_constraint_enabled"

    // Audio
    case setAudioSource       = "set_audio_source"

    // Script
    case setScriptProperty    = "set_script_property"

    // Mesh visibility
    case setMeshVisibility    = "set_mesh_visibility"

    // Animation
    case setAnimationPlayer   = "set_animation_player"
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
    public var spawnKind: String?      // "mesh" | "empty" | "light" | "camera"; default "mesh"

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

    // set_rigidbody_allow_sleep
    public var allowSleep: Bool?

    // set_collider_shape
    public var colliderShape: String?   // "box" | "sphere" | "capsule" | "mesh" | "convex"

    // set_collider_box_extents
    public var halfExtents: [Float]?    // [x, y, z] half-sizes

    // set_collider_sphere_radius / set_collider_capsule
    public var radius: Float?

    // set_collider_capsule
    public var halfHeight: Float?

    // set_collider_material
    public var friction: Float?
    public var restitution: Float?
    public var density: Float?

    // set_collider_trigger
    public var isTrigger: Bool?

    // set_collider_layer
    public var colliderLayerID: Int?     // physics layer this collider occupies (0-15)
    public var colliderLayerMask: Int?   // bitmask of layers this collider interacts with

    // set_constraint_enabled
    public var isEnabled: Bool?

    // reparent_entity
    public var parentRef: String?        // "scene:<id>" or nil to reparent to root

    // set_audio_source
    public var audioClip: String?
    public var audioVolume: Float?
    public var audioPitch: Float?
    public var audioLoop: Bool?
    public var audioPlayOnAwake: Bool?
    public var audioSpatialBlend: Float?

    // set_script_property
    public var scriptIndex: Int?        // binding index, default 0
    public var scriptPropertyName: String?
    public var scriptPropertyValue: JSONValue?

    // set_material (PBR)
    public var materialBaseColor: [Float]?   // [r, g, b, a] linear 0-1; nil = unchanged
    public var materialMetallic: Float?       // 0-1; nil = unchanged
    public var materialRoughness: Float?      // 0-1; nil = unchanged
    public var materialEmissive: [Float]?     // [r, g, b] linear 0-1; nil = no emission

    // set_light_cast_shadows
    public var lightCastShadows: Bool?

    // set_camera_fov / set_camera_active
    public var cameraFovYDegrees: Float?
    public var cameraIsActive: Bool?

    // set_mesh_visibility
    public var isVisible: Bool?

    // set_animation_player
    public var animationClip: String?   // clip name; empty string or nil = use default
    public var animationSpeed: Float?   // default 1.0
    public var animationLoop: Bool?     // default true
    public var animationIsPlaying: Bool?

    enum CodingKeys: String, CodingKey {
        case op
        case entityRef          = "entity_id"
        case label
        case spawnPosition      = "spawn_position"
        case spawnKind          = "spawn_kind"
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
        case materialBaseColor  = "material_base_color"
        case materialMetallic   = "material_metallic"
        case materialRoughness  = "material_roughness"
        case materialEmissive   = "material_emissive"
        case lightCastShadows   = "light_cast_shadows"
        case cameraTarget       = "camera_target"
        case cameraUp           = "camera_up"
        case cameraFovYDegrees  = "camera_fov_y"
        case cameraIsActive     = "camera_is_active"
        case motionType         = "motion_type"
        case mass
        case gravityScale       = "gravity_scale"
        case allowSleep         = "allow_sleep"
        case colliderShape      = "collider_shape"
        case halfExtents        = "half_extents"
        case radius
        case halfHeight         = "half_height"
        case friction
        case restitution
        case density
        case isTrigger          = "is_trigger"
        case colliderLayerID    = "collider_layer_id"
        case colliderLayerMask  = "collider_layer_mask"
        case isEnabled          = "is_enabled"
        case parentRef          = "parent_id"
        case audioClip          = "audio_clip"
        case audioVolume        = "audio_volume"
        case audioPitch         = "audio_pitch"
        case audioLoop          = "audio_loop"
        case audioPlayOnAwake   = "audio_play_on_awake"
        case audioSpatialBlend  = "audio_spatial_blend"
        case scriptIndex        = "script_index"
        case scriptPropertyName = "script_property_name"
        case scriptPropertyValue = "script_property_value"
        case isVisible          = "is_visible"
        case animationClip      = "animation_clip"
        case animationSpeed     = "animation_speed"
        case animationLoop      = "animation_loop"
        case animationIsPlaying = "animation_is_playing"
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
