import CapabilityRuntime
import Foundation
import SceneRuntime
import ScriptRuntime
import SIMDCompat

public enum SceneUtilityCapabilityPreparationError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case entityCannotParentItself(String)
    case emptyScriptPropertyName
    case noAudioFields
    case noAnimationFields

    public var description: String {
        switch self {
        case let .entityCannotParentItself(reference):
            return "entity '\(reference)' cannot be its own parent"
        case .emptyScriptPropertyName:
            return "script_property_name must not be empty"
        case .noAudioFields:
            return "set_audio_source requires at least one audio field"
        case .noAnimationFields:
            return "set_animation_player requires at least one animation field"
        }
    }
}

public enum CapabilitySpawnKind: String, CapabilitySchemaValue, CaseIterable {
    case mesh
    case empty
    case light
    case camera

    public static var capabilitySchema: JSONSchema {
        .string(allowedValues: allCases.map(\.rawValue))
    }

    public static var capabilityPlaceholder: CapabilitySpawnKind { .mesh }
}

public struct SpawnEntityCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @AIField(description: "Entity display name.", minLength: 1, maxLength: 256)
        public var label: String?

        @AIField(description: "Initial local-space position.")
        public var spawn_position: Vec3?

        @AIField(description: "Kind of entity to create.")
        public var spawn_kind: CapabilitySpawnKind?

        @AIField(description: "Optional existing parent entity.")
        public var spawn_parent_id: SceneEntityRef?

        @AIField(description: "Initial type when spawning a light.")
        public var light_type: CapabilityLightType?

        @ValueRange(min: 0)
        public var intensity: Double?

        @ValueRange(min: 0, max: 1)
        public var color: Vec3?

        @ValueRange(min: 0)
        public var range: Double?

        @AIField(description: "Initial shadow state when spawning a light.")
        public var light_cast_shadows: Bool?

        @ValueRange(min: 1, max: 179)
        public var camera_fov_y: Double?

        public init() {}
    }

    public static let id = "scene.spawn_entity"
    public static let title = "Spawn entity"
    public static let description = "Create a mesh, empty, light, or camera entity."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        let label = input.label ?? "AI Entity"
        let position = try input.spawn_position.map {
            try capabilityVector($0, field: "spawn_position")
        } ?? .zero
        let parentID = try input.spawn_parent_id.map {
            try preparedEntityID($0, context: context)
        }
        let mutation: SceneMutation
        switch input.spawn_kind ?? .mesh {
        case .mesh:
            mutation = .spawnImportedMeshEntity(
                label: label,
                kindLabel: "Static Mesh",
                meshIndex: 0,
                position: position,
                parentID: parentID
            )
        case .empty:
            mutation = .spawnEmptyEntity(label: label, position: position, parentID: parentID)
        case .light:
            mutation = .spawnLightEntity(
                label: label,
                lightType: (input.light_type ?? .point).runtimeValue,
                position: position,
                initialIntensity: try input.intensity.map {
                    try capabilityFloat($0, field: "intensity")
                },
                initialColor: try input.color.map {
                    try capabilityVector($0, field: "color")
                },
                initialRange: try input.range.map {
                    try capabilityFloat($0, field: "range")
                },
                initialCastShadows: input.light_cast_shadows,
                parentID: parentID
            )
        case .camera:
            mutation = .spawnCameraEntity(
                label: label,
                position: position,
                initialFovYDegrees: try input.camera_fov_y.map {
                    try capabilityFloat($0, field: "camera_fov_y")
                },
                parentID: parentID
            )
        }
        return PreparedCapability(
            operations: [.scene(mutation)],
            preview: CapabilityPreview(
                summary: "Spawn \((input.spawn_kind ?? .mesh).rawValue) entity",
                targetReferences: input.spawn_parent_id.map { [$0.rawValue] } ?? []
            ),
            assertions: [.sceneRevisionAdvanced(from: context.sceneRevision)]
        )
    }
}

public struct ReparentEntityCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @AIField(description: "New parent entity. Omit to move to the scene root.")
        public var parent_id: SceneEntityRef?

        public init() {}
    }

    public static let id = "scene.reparent_entity"
    public static let title = "Reparent entity"
    public static let description = "Move an entity beneath another entity or to the scene root."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        let entityID = try preparedEntityID(input.entity_id, context: context)
        if input.parent_id == input.entity_id {
            throw SceneUtilityCapabilityPreparationError.entityCannotParentItself(
                input.entity_id.rawValue
            )
        }
        let parentID = try input.parent_id.map { try preparedEntityID($0, context: context) }
        return PreparedCapability(
            operations: [.scene(.moveEntity(entityID: entityID,
                                            parentID: parentID,
                                            index: .max))],
            preview: CapabilityPreview(
                summary: "Reparent entity",
                targetReferences: [input.entity_id.rawValue]
                    + (input.parent_id.map { [$0.rawValue] } ?? [])
            ),
            assertions: [.entityExists(entityID)]
        )
    }
}

public struct SnapToGroundCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference(requires: [.localTransform])
        public var entity_id: SceneEntityRef

        public init() {}
    }

    public static let id = "scene.snap_to_ground"
    public static let title = "Snap to ground"
    public static let description = "Move an entity to the ground plane at y=0."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        let prepared = try preparedLocalTransform(input.entity_id, context: context)
        var transform = prepared.transform
        transform.matrix.columns.3.y = 0
        return PreparedCapability(
            operations: [.scene(.setLocalTransform(entityID: prepared.entityID,
                                                    transform: transform))],
            preview: CapabilityPreview(summary: "Snap entity to ground",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(prepared.entityID)]
        )
    }
}

public struct SetMeshColorCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference(requires: [.renderMesh])
        public var entity_id: SceneEntityRef

        @ValueRange(min: 0, max: 1)
        public var color: Vec3

        public init() {}
    }

    public static let id = "scene.set_mesh_color"
    public static let title = "Set mesh colour"
    public static let description = "Set the linear RGB colour tint of a render mesh."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        let entityID = try preparedEntityID(input.entity_id,
                                            requiring: .renderMesh,
                                            context: context)
        return PreparedCapability(
            operations: [.scene(.setMeshColorTint(
                entityID: entityID,
                color: try capabilityVector(input.color, field: "color")
            ))],
            preview: CapabilityPreview(summary: "Set mesh colour",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }
}

public struct SetMeshVisibilityCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference(requires: [.renderMesh])
        public var entity_id: SceneEntityRef

        @AIField(description: "Whether the render mesh is visible.")
        public var is_visible: Bool

        public init() {}
    }

    public static let id = "scene.set_mesh_visibility"
    public static let title = "Set mesh visibility"
    public static let description = "Show or hide a render mesh."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        let entityID = try preparedEntityID(input.entity_id,
                                            requiring: .renderMesh,
                                            context: context)
        return PreparedCapability(
            operations: [.scene(.setRenderMeshVisibility(entityID: entityID,
                                                          isVisible: input.is_visible))],
            preview: CapabilityPreview(summary: "Set mesh visibility",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }
}

public struct SetConstraintEnabledCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference(requires: [.constraint])
        public var entity_id: SceneEntityRef

        @AIField(description: "Whether the constraint is enabled.")
        public var is_enabled: Bool

        public init() {}
    }

    public static let id = "scene.set_constraint_enabled"
    public static let title = "Set constraint enabled"
    public static let description = "Enable or disable a physics constraint."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        let entityID = try preparedEntityID(input.entity_id,
                                            requiring: .constraint,
                                            context: context)
        return PreparedCapability(
            operations: [.scene(.setConstraintEnabled(entityID: entityID,
                                                       value: input.is_enabled))],
            preview: CapabilityPreview(summary: "Set constraint enabled",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }
}

public struct SetAudioSourceCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @AIField(description: "Audio clip asset name.", maxLength: 1_024)
        public var audio_clip: String?

        @ValueRange(min: 0, max: 1)
        public var audio_volume: Double?

        @ValueRange(min: 0.01, max: 4)
        public var audio_pitch: Double?

        @AIField(description: "Whether playback loops.")
        public var audio_loop: Bool?

        @AIField(description: "Whether playback starts when play mode begins.")
        public var audio_play_on_awake: Bool?

        @ValueRange(min: 0, max: 1)
        public var audio_spatial_blend: Double?

        public init() {}
    }

    public static let id = "scene.set_audio_source"
    public static let title = "Set audio source"
    public static let description = "Configure an entity's audio source."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        guard input.audio_clip != nil
                || input.audio_volume != nil
                || input.audio_pitch != nil
                || input.audio_loop != nil
                || input.audio_play_on_awake != nil
                || input.audio_spatial_blend != nil else {
            throw SceneUtilityCapabilityPreparationError.noAudioFields
        }
        let entityID = try preparedEntityID(input.entity_id, context: context)
        var source = context.entities.first {
            $0.reference == input.entity_id.rawValue
        }?.audioSource ?? AudioSource()
        if let value = input.audio_clip { source.clipName = value }
        if let value = input.audio_volume {
            source.volume = try capabilityFloat(value, field: "audio_volume")
        }
        if let value = input.audio_pitch {
            source.pitch = try capabilityFloat(value, field: "audio_pitch")
        }
        if let value = input.audio_loop { source.loop = value }
        if let value = input.audio_play_on_awake { source.playOnAwake = value }
        if let value = input.audio_spatial_blend {
            source.spatialBlend = try capabilityFloat(value, field: "audio_spatial_blend")
        }
        return PreparedCapability(
            operations: [.scene(.setAudioSource(entityID: entityID, source: source))],
            preview: CapabilityPreview(summary: "Set audio source",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }
}

public enum CapabilityScriptScalar: CapabilitySchemaValue, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let decoded = try? value.decode(Bool.self) { self = .bool(decoded); return }
        if let decoded = try? value.decode(Double.self) { self = .number(decoded); return }
        if let decoded = try? value.decode(String.self) { self = .string(decoded); return }
        throw DecodingError.dataCorruptedError(in: value,
                                               debugDescription: "unsupported script scalar")
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .string(decoded): try value.encode(decoded)
        case let .number(decoded): try value.encode(decoded)
        case let .bool(decoded): try value.encode(decoded)
        }
    }

    public static var capabilitySchema: JSONSchema {
        .choice([.string(), .number(), .boolean()])
    }

    public static var capabilityPlaceholder: CapabilityScriptScalar { .string("") }

    fileprivate var foundationValue: Any {
        switch self {
        case let .string(value): return value
        case let .number(value): return value
        case let .bool(value): return value
        }
    }
}

public enum CapabilityScriptValue: CapabilitySchemaValue, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([CapabilityScriptScalar])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let decoded = try? value.decode(Bool.self) { self = .bool(decoded); return }
        if let decoded = try? value.decode(Double.self) { self = .number(decoded); return }
        if let decoded = try? value.decode(String.self) { self = .string(decoded); return }
        if let decoded = try? value.decode([CapabilityScriptScalar].self) {
            self = .array(decoded)
            return
        }
        throw DecodingError.dataCorruptedError(in: value,
                                               debugDescription: "unsupported script value")
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .string(decoded): try value.encode(decoded)
        case let .number(decoded): try value.encode(decoded)
        case let .bool(decoded): try value.encode(decoded)
        case let .array(decoded): try value.encode(decoded)
        }
    }

    public static var capabilitySchema: JSONSchema {
        .choice([
            .string(),
            .number(),
            .boolean(),
            .array(of: CapabilityScriptScalar.capabilitySchema, maximumItems: 256),
        ])
    }

    public static var capabilityPlaceholder: CapabilityScriptValue { .string("") }

    fileprivate var foundationValue: Any {
        switch self {
        case let .string(value): return value
        case let .number(value): return value
        case let .bool(value): return value
        case let .array(value): return value.map(\.foundationValue)
        }
    }
}

public struct SetScriptPropertyCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @ValueRange(min: 0, max: 255)
        public var script_index: Int?

        @AIField(description: "Script property name.", minLength: 1, maxLength: 256)
        public var script_property_name: String

        @AIField(description: "Bounded string, number, boolean, or scalar array value.")
        public var script_property_value: CapabilityScriptValue

        public init() {}
    }

    public static let id = "scene.set_script_property"
    public static let title = "Set script property"
    public static let description = "Set one bounded script parameter value."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        guard !input.script_property_name.isEmpty else {
            throw SceneUtilityCapabilityPreparationError.emptyScriptPropertyName
        }
        let entityID = try preparedEntityID(input.entity_id, context: context)
        let index = input.script_index ?? 0
        var bindings = context.entities.first {
            $0.reference == input.entity_id.rawValue
        }?.scriptBindings ?? []
        while bindings.count <= index {
            bindings.append(ScriptBinding(ScriptHandle(rawValue: 0)))
        }
        bindings[index].parametersJSON = try mergeScriptProperty(
            json: bindings[index].parametersJSON,
            name: input.script_property_name,
            value: input.script_property_value
        )
        return PreparedCapability(
            operations: [.scene(.setScriptBindings(entityID: entityID, bindings: bindings))],
            preview: CapabilityPreview(summary: "Set script property",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }

    private static func mergeScriptProperty(
        json: String,
        name: String,
        value: CapabilityScriptValue
    ) throws -> String {
        var object: [String: Any] = [:]
        if let data = json.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = decoded
        }
        object[name] = value.foundationValue
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw CapabilityRegistrationError.invalidInput(
                capabilityID: id,
                reason: "script parameters could not be encoded as UTF-8 JSON"
            )
        }
        return encoded
    }
}

public struct SetScriptBindingsCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @ValueRange(min: 0, max: 255)
        public var script_index: Int?

        @AIField(description: "Whether the selected script binding is enabled.")
        public var is_enabled: Bool

        public init() {}
    }

    public static let id = "scene.set_script_bindings"
    public static let title = "Set script enabled"
    public static let description = "Enable or disable an existing script binding."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        let entityID = try preparedEntityID(input.entity_id, context: context)
        let index = input.script_index ?? 0
        var bindings = context.entities.first {
            $0.reference == input.entity_id.rawValue
        }?.scriptBindings ?? []
        while bindings.count <= index {
            bindings.append(ScriptBinding(ScriptHandle(rawValue: 0)))
        }
        bindings[index].isEnabled = input.is_enabled
        return PreparedCapability(
            operations: [.scene(.setScriptBindings(entityID: entityID, bindings: bindings))],
            preview: CapabilityPreview(summary: "Set script binding",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }
}

public struct SetAnimationPlayerCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @AIField(description: "Animation clip name; an empty string selects the default clip.",
                 maxLength: 1_024)
        public var animation_clip: String?

        @ValueRange(min: 0)
        public var animation_speed: Double?

        @AIField(description: "Whether playback loops.")
        public var animation_loop: Bool?

        @AIField(description: "Whether playback is running.")
        public var animation_is_playing: Bool?

        public init() {}
    }

    public static let id = "scene.set_animation_player"
    public static let title = "Set animation player"
    public static let description = "Configure animation clip playback."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        guard input.animation_clip != nil
                || input.animation_speed != nil
                || input.animation_loop != nil
                || input.animation_is_playing != nil else {
            throw SceneUtilityCapabilityPreparationError.noAnimationFields
        }
        let entityID = try preparedEntityID(input.entity_id, context: context)
        var player = context.entities.first {
            $0.reference == input.entity_id.rawValue
        }?.animationPlayer ?? AnimationPlayer()
        if let value = input.animation_clip { player.clipName = value.isEmpty ? nil : value }
        if let value = input.animation_speed {
            player.speed = try capabilityFloat(value, field: "animation_speed")
        }
        if let value = input.animation_loop { player.loop = value }
        if let value = input.animation_is_playing { player.isPlaying = value }
        return PreparedCapability(
            operations: [.scene(.setAnimationPlayer(entityID: entityID,
                                                     clipName: player.clipName,
                                                     speed: player.speed,
                                                     loop: player.loop,
                                                     isPlaying: player.isPlaying))],
            preview: CapabilityPreview(summary: "Set animation player",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }
}
