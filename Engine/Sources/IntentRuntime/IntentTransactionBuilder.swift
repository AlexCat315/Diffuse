import Foundation
import SceneRuntime
import SIMDCompat

public struct IntentTransactionBuildContext {
    public var sceneRuntime: SceneRuntime
    public var selectedEntityID: UInt64?
    public var defaultSpawnMeshIndex: Int

    public init(sceneRuntime: SceneRuntime,
                selectedEntityID: UInt64? = nil,
                defaultSpawnMeshIndex: Int = 0) {
        self.sceneRuntime = sceneRuntime
        self.selectedEntityID = selectedEntityID
        self.defaultSpawnMeshIndex = defaultSpawnMeshIndex
    }
}

public enum IntentTransactionBuilderError: Error, CustomStringConvertible, Equatable {
    case unsupportedVerb(String)
    case missingArgument(verbID: String, argument: String)
    case invalidArgument(verbID: String, argument: String)
    case missingTarget(verbID: String)
    case invalidTarget(String)

    public var description: String {
        switch self {
        case let .unsupportedVerb(verbID):
            return "unsupported intent verb: \(verbID)"
        case let .missingArgument(verbID, argument):
            return "intent \(verbID) is missing argument \(argument)"
        case let .invalidArgument(verbID, argument):
            return "intent \(verbID) has invalid argument \(argument)"
        case let .missingTarget(verbID):
            return "intent \(verbID) requires a target entity"
        case let .invalidTarget(target):
            return "invalid intent target: \(target)"
        }
    }
}

public struct IntentTransactionBuilder: Sendable {
    public init() {}

    public func buildTransaction(from intent: IntentIR,
                                 context: IntentTransactionBuildContext) throws -> TransactionIR {
        let mutations: [SceneMutation]
        let summary: String

        switch intent.verb {
        case "scene.spawn_entity", "scene.create_instance":
            let label = stringArgument("label", in: intent) ?? "AI Entity"
            let position = vec3Argument("position", in: intent) ?? .zero
            mutations = [
                .spawnImportedMeshEntity(label: label,
                                         kindLabel: "Static Mesh",
                                         meshIndex: context.defaultSpawnMeshIndex,
                                         position: position)
            ]
            summary = intent.summary.isEmpty ? "Spawn scene entity" : intent.summary

        case "scene.set_name":
            let entityID = try targetEntityID(for: intent, context: context)
            guard let name = stringArgument("name", in: intent) else {
                throw IntentTransactionBuilderError.missingArgument(verbID: intent.verb, argument: "name")
            }
            mutations = [.setSceneName(entityID: entityID, value: name)]
            summary = intent.summary.isEmpty ? "Rename selected entity" : intent.summary

        case "scene.duplicate_entity":
            let entityID = try targetEntityID(for: intent, context: context)
            mutations = [.duplicateEntity(entityID: entityID)]
            summary = intent.summary.isEmpty ? "Duplicate selected entity" : intent.summary

        case "scene.delete_entity", "scene.delete_instance":
            let entityID = try targetEntityID(for: intent, context: context)
            mutations = [.deleteEntity(entityID: entityID)]
            summary = intent.summary.isEmpty ? "Delete selected entity" : intent.summary

        case "scene.set_transform", "scene.set_local_transform":
            let entityID = try targetEntityID(for: intent, context: context)
            guard let translation = vec3Argument("translation", in: intent)
                    ?? vec3Argument("position", in: intent)
            else {
                throw IntentTransactionBuilderError.missingArgument(verbID: intent.verb, argument: "translation")
            }
            let entity = entityIDFromRaw(entityID)
            guard context.sceneRuntime.contains(entity) else {
                throw IntentTransactionBuilderError.invalidTarget("scene:\(entityID)")
            }
            var transform = context.sceneRuntime.localTransform(for: entity) ?? LocalTransform()
            transform.matrix.columns.3 = SIMD4<Float>(translation, 1)
            mutations = [.setLocalTransform(entityID: entityID, transform: transform)]
            summary = intent.summary.isEmpty ? "Set selected transform" : intent.summary

        case "scene.snap_to_ground":
            let entityID = try targetEntityID(for: intent, context: context)
            let entity = entityIDFromRaw(entityID)
            guard context.sceneRuntime.contains(entity) else {
                throw IntentTransactionBuilderError.invalidTarget("scene:\(entityID)")
            }
            var transform = context.sceneRuntime.localTransform(for: entity) ?? LocalTransform()
            transform.matrix.columns.3.y = 0
            mutations = [.setLocalTransform(entityID: entityID, transform: transform)]
            summary = "Snap entity to ground"

        case "scene.set_camera_pose":
            let entityID = try targetEntityID(for: intent, context: context)
            let position = vec3Argument("position", in: intent) ?? .zero
            let target = vec3Argument("target", in: intent) ?? SIMD3<Float>(0, 0, -1)
            var transform = LocalTransform()
            transform.matrix.columns.3 = SIMD4<Float>(position, 1)
            mutations = [.setCameraPose(entityID: entityID,
                                         localTransform: transform,
                                         target: target,
                                         up: nil)]
            summary = "Set camera pose"

        default:
            throw IntentTransactionBuilderError.unsupportedVerb(intent.verb)
        }

        return TransactionIR(intent: intent,
                             summary: summary,
                             operations: mutations.map(TransactionOperation.scene),
                             baseRevisions: TransactionBaseRevisions(sceneRevision: context.sceneRuntime.snapshot.revision),
                             provenance: intent.source == .ai ? .proposal : .authored)
    }

    private func targetEntityID(for intent: IntentIR,
                                context: IntentTransactionBuildContext) throws -> UInt64 {
        if let raw = stableIDArgument("entity_id", in: intent) {
            return raw
        }
        if let target = intent.targetObjectIDs.first {
            return try rawEntityID(fromTargetObjectID: target)
        }
        if let selected = context.selectedEntityID {
            return selected
        }
        throw IntentTransactionBuilderError.missingTarget(verbID: intent.verb)
    }

    private func stringArgument(_ name: String, in intent: IntentIR) -> String? {
        guard case let .string(value) = intent.arguments[name] else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func stableIDArgument(_ name: String, in intent: IntentIR) -> UInt64? {
        switch intent.arguments[name] {
        case let .stableID(value):
            return value
        case let .integer(value) where value >= 0:
            return UInt64(value)
        default:
            return nil
        }
    }

    private func vec3Argument(_ name: String, in intent: IntentIR) -> SIMD3<Float>? {
        guard case let .vec3(value) = intent.arguments[name] else {
            return nil
        }
        return value.simdValue
    }

    private func rawEntityID(fromTargetObjectID target: String) throws -> UInt64 {
        let raw = target.hasPrefix("scene:")
            ? String(target.dropFirst("scene:".count))
            : target
        guard let entityID = UInt64(raw) else {
            throw IntentTransactionBuilderError.invalidTarget(target)
        }
        return entityID
    }

    private func entityIDFromRaw(_ rawID: UInt64) -> EntityID {
        EntityID(index: UInt32(rawID & 0xFFFF_FFFF),
                 generation: UInt32(rawID >> 32))
    }
}
