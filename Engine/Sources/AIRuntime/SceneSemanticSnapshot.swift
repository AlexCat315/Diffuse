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

        /// World-space position in metres, or `nil` if no `LocalTransform`.
        public var position: [Float]?          // [x, y, z]

        /// Component type names present on this entity.
        /// Possible values: `"transform"`, `"mesh"`, `"light"`, `"camera"`, `"rigidbody"`, `"collider"`, `"script"`
        public var components: [String]

        // Light extras — non-nil only when `"light"` ∈ components
        public var lightType: String?          // "directional" | "point" | "spot"
        public var lightIntensity: Float?
        public var lightColor: [Float]?        // [r, g, b] linear 0–1
        public var lightRange: Float?

        // Camera extras — non-nil only when `"camera"` ∈ components
        public var cameraFovYDegrees: Float?
        public var cameraIsActive: Bool?

        // Physics extras — non-nil only when `"rigidbody"` ∈ components
        public var rigidBodyMotionType: String? // "static" | "dynamic" | "kinematic"
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
