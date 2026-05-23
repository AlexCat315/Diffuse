import Foundation

/// Compact, serialisable snapshot of the scene for AI planning.
/// Built by `SceneSemanticEncoder` from a live `SceneRuntime`; passed verbatim
/// to `AIScenePlanner` as the context Claude reasons over.
///
/// Design goals:
/// - Fully `Codable` → can be serialised to JSON for the API system prompt
/// - Flat, entity-centric layout → Claude can refer to entities by `entityRef`
/// - Minimal but complete → positions, names, component presence, light/camera state
public struct SceneSemanticSnapshot: Codable, Sendable, Equatable {

    // MARK: - Entity record

    public struct Entity: Codable, Sendable, Equatable, Identifiable {
        /// Stable entity reference formatted as `"scene:<rawID>"`.
        /// Use this value as `entity_id` in `SceneEditStep`.
        public var id: String

        /// Human-readable name from `SceneNameComponent`, or `"Entity <rawID>"`.
        public var name: String

        /// Kind label from `SceneKindComponent`, or derived from components present:
        /// `"Static Mesh"` | `"Camera"` | `"Directional Light"` | `"Point Light"` | `"Spot Light"` | `"Group"` | `"Entity"`
        public var kind: String

        public var parentRef: String?
        public var childRefs: [String]
        public var isSelected: Bool

        /// Local-space position in metres, or `nil` if no `LocalTransform`.
        public var position: [Float]?          // [x, y, z]

        /// Local-space scale factors, or `nil` if no `LocalTransform`.
        public var scale: [Float]? = nil       // [x, y, z]; nil if uniform 1,1,1 or no transform

        /// Local-space rotation in degrees (XYZ intrinsic Euler), or `nil` if no rotation or no transform.
        public var eulerDegrees: [Float]? = nil // [x, y, z]; nil if all-zero

        /// World-space position in metres, computed from the full parent hierarchy.
        /// `nil` if the entity has no `LocalTransform`.
        public var worldPosition: [Float]? = nil  // [x, y, z]

        /// Component type names present on this entity.
        /// Possible values: `"transform"`, `"mesh"`, `"light"`, `"camera"`, `"rigidbody"`, `"collider"`, `"script"`
        public var components: [String]

        // Light extras — non-nil only when `"light"` ∈ components
        public var lightType: String?          // "directional" | "point" | "spot"
        public var lightIntensity: Float?
        public var lightColor: [Float]?        // [r, g, b] linear 0–1
        public var lightRange: Float?
        public var lightSpotInner: Float? = nil  // degrees; non-nil only for spot lights
        public var lightSpotOuter: Float? = nil  // degrees; non-nil only for spot lights

        // Camera extras — non-nil only when `"camera"` ∈ components
        public var cameraFovYDegrees: Float?
        public var cameraIsActive: Bool?

        // Mesh extras — non-nil only when `"mesh"` ∈ components and color is non-default
        public var meshColor: [Float]?         // [r, g, b] linear 0–1; nil = default white

        // Physics extras — non-nil only when `"rigidbody"` ∈ components
        public var rigidBodyMotionType: String? // "static" | "dynamic" | "kinematic"
        public var rigidBodyMass: Float?
        public var rigidBodyGravityScale: Float?
        public var rigidBodyAllowSleep: Bool?

        // Collider extras — non-nil only when `"collider"` ∈ components
        public var colliderShape: String?       // "box" | "sphere" | "capsule" | "mesh" | "convex"
        public var colliderIsTrigger: Bool?
        public var colliderFriction: Float?
        public var colliderRestitution: Float?
        public var colliderDensity: Float?

        // Audio extras — non-nil only when `"audio_source"` ∈ components
        public var audioClip: String?
        public var audioVolume: Float?
        public var audioLoop: Bool?
        public var audioPlayOnAwake: Bool?

        // Script extras — non-nil only when `"script"` ∈ components
        public var scriptBindings: [ScriptBindingRecord]? = nil
    }

    /// Compact snapshot of a single ScriptBinding for AI context.
    public struct ScriptBindingRecord: Codable, Sendable, Equatable {
        public var handle: UInt64
        public var isEnabled: Bool
        /// Raw JSON string of parameters (e.g. `{"speed":5,"label":"Patrol"}`).
        public var parametersJSON: String

        public init(handle: UInt64, isEnabled: Bool, parametersJSON: String) {
            self.handle = handle
            self.isEnabled = isEnabled
            self.parametersJSON = parametersJSON
        }
    }

    // MARK: - Snapshot root

    public var sceneRevision: UInt64
    public var entityCount: Int
    public var entities: [Entity]
    public var selectedRef: String?    // "scene:<rawID>" or nil
    public var workspaceMode: String?  // "level" | "modeling" | "animation"
    public var localeIdentifier: String?

    public init(sceneRevision: UInt64,
                entityCount: Int,
                entities: [Entity],
                selectedRef: String? = nil,
                workspaceMode: String? = nil,
                localeIdentifier: String? = nil) {
        self.sceneRevision = sceneRevision
        self.entityCount = entityCount
        self.entities = entities
        self.selectedRef = selectedRef
        self.workspaceMode = workspaceMode
        self.localeIdentifier = localeIdentifier
    }
}
