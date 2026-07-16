import CapabilityRuntime
import Foundation
import IntentRuntime

public struct CapabilityInvocationDraft: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var capabilityID: String
    public var capabilityVersion: Int
    public var schemaHash: String
    public var sourcePluginID: String?
    public var pluginAuthority: PluginCapabilityAuthority?
    public var validatedInput: Data
    public var snapshotID: UUID
    public var sceneRevision: UInt64
    public var createdAt: Date

    public init(id: UUID = UUID(),
                capabilityID: String,
                capabilityVersion: Int,
                schemaHash: String,
                sourcePluginID: String? = nil,
                pluginAuthority: PluginCapabilityAuthority? = nil,
                validatedInput: Data,
                snapshotID: UUID,
                sceneRevision: UInt64,
                createdAt: Date = Date()) {
        self.id = id
        self.capabilityID = capabilityID
        self.capabilityVersion = capabilityVersion
        self.schemaHash = schemaHash
        self.sourcePluginID = sourcePluginID
        self.pluginAuthority = pluginAuthority
        self.validatedInput = validatedInput
        self.snapshotID = snapshotID
        self.sceneRevision = sceneRevision
        self.createdAt = createdAt
    }
}

public enum CapabilityDraftError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownTool(String)
    case readCapabilityCannotBeDrafted(String)
    case externalSideEffectDisabled(String)
    case staleSnapshot
    case staleSceneRevision(expected: UInt64, actual: UInt64)
    case contractChanged(String)
    case invalidInput(String)
    case inputTooLarge
    case draftNotFound(UUID)
    case draftExpired(UUID)
    case tooManyDrafts
    case duplicateDraftID(UUID)
    case unsupportedBuiltInCapability(String)

    public var description: String {
        switch self {
        case let .unknownTool(name): return "unknown or unexposed capability tool '\(name)'"
        case let .readCapabilityCannotBeDrafted(id): return "read capability '\(id)' cannot create a write draft"
        case let .externalSideEffectDisabled(id): return "external side-effect capability '\(id)' is disabled"
        case .staleSnapshot: return "capability exposure snapshot is stale"
        case let .staleSceneRevision(expected, actual):
            return "scene revision changed (expected \(expected), actual \(actual))"
        case let .contractChanged(id): return "capability contract changed for '\(id)'"
        case let .invalidInput(reason): return "invalid capability input: \(reason)"
        case .inputTooLarge: return "capability input exceeds 1 MiB"
        case let .draftNotFound(id): return "capability draft '\(id)' was not found"
        case let .draftExpired(id): return "capability draft '\(id)' expired"
        case .tooManyDrafts: return "a plan may contain at most 100 capability drafts"
        case let .duplicateDraftID(id): return "capability draft '\(id)' cannot be submitted twice"
        case let .unsupportedBuiltInCapability(id):
            return "capability '\(id)' cannot be lowered by the built-in scene adapter"
        }
    }
}

/// Actor-isolated, fail-closed storage for validated model write proposals.
/// Creating a draft never mutates a scene.
public actor CapabilityDraftStore {
    public static let defaultTTL: TimeInterval = CapabilityDraftLimits.timeToLiveSeconds
    public static let maximumInputBytes = CapabilityDraftLimits.maximumInputBytes
    public static let maximumDraftsPerPlan = CapabilityDraftLimits.maximumDraftsPerPlan

    private let registry: CapabilityRegistry
    private let ttl: TimeInterval
    private var drafts: [UUID: CapabilityInvocationDraft] = [:]

    public init(registry: CapabilityRegistry = .aiDefault,
                ttl: TimeInterval = CapabilityDraftStore.defaultTTL) {
        self.registry = registry
        self.ttl = max(1, ttl)
    }

    @discardableResult
    public func createDraft(toolName: String,
                            input: Data,
                            snapshot: CapabilityExposureSnapshot,
                            currentSceneRevision: UInt64,
                            now: Date = Date()) throws -> CapabilityInvocationDraft {
        guard input.count <= Self.maximumInputBytes else { throw CapabilityDraftError.inputTooLarge }
        let snapshotAge = now.timeIntervalSince(snapshot.createdAt)
        guard snapshotAge >= 0, snapshotAge <= ttl else { throw CapabilityDraftError.staleSnapshot }
        guard snapshot.sceneRevision == nil || snapshot.sceneRevision == currentSceneRevision else {
            throw CapabilityDraftError.staleSceneRevision(expected: snapshot.sceneRevision ?? currentSceneRevision,
                                                          actual: currentSceneRevision)
        }
        guard let exposed = snapshot.contract(forToolName: toolName) else {
            throw CapabilityDraftError.unknownTool(toolName)
        }
        guard exposed.access.isWrite else {
            throw CapabilityDraftError.readCapabilityCannotBeDrafted(exposed.id)
        }
        guard exposed.access != .externalSideEffect else {
            throw CapabilityDraftError.externalSideEffectDisabled(exposed.id)
        }
        guard let current = registry.descriptor(for: exposed.id)?.contract,
              current.version == exposed.version,
              current.schemaHash == exposed.schemaHash,
              current.access == exposed.access,
              current.source == exposed.source else {
            throw CapabilityDraftError.contractChanged(exposed.id)
        }
        let canonical = try canonicalise(input)
        do {
            try JSONSchemaValidator.validate(data: canonical, against: exposed.inputSchema)
        } catch {
            throw CapabilityDraftError.invalidInput(String(describing: error))
        }
        purgeExpired(now: now)
        let draft = CapabilityInvocationDraft(capabilityID: exposed.id,
                                              capabilityVersion: exposed.version,
                                              schemaHash: exposed.schemaHash,
                                              sourcePluginID: exposed.source.pluginID,
                                              pluginAuthority: try pluginAuthority(
                                                for: exposed,
                                                snapshot: snapshot
                                              ),
                                              validatedInput: canonical,
                                              snapshotID: snapshot.id,
                                              sceneRevision: currentSceneRevision,
                                              createdAt: now)
        drafts[draft.id] = draft
        return draft
    }

    /// Revalidates every authority-bearing field. Drafts remain available until
    /// the caller explicitly consumes them after a transaction is staged.
    public func validatedDrafts(ids: [UUID],
                                snapshot: CapabilityExposureSnapshot,
                                currentSceneRevision: UInt64,
                                now: Date = Date()) throws -> [CapabilityInvocationDraft] {
        guard ids.count <= Self.maximumDraftsPerPlan else { throw CapabilityDraftError.tooManyDrafts }
        if let duplicate = Dictionary(grouping: ids, by: { $0 })
            .first(where: { $0.value.count > 1 })?.key {
            throw CapabilityDraftError.duplicateDraftID(duplicate)
        }
        let snapshotAge = now.timeIntervalSince(snapshot.createdAt)
        guard snapshotAge >= 0, snapshotAge <= ttl else { throw CapabilityDraftError.staleSnapshot }
        purgeExpired(now: now)
        return try ids.map { id in
            guard let draft = drafts[id] else { throw CapabilityDraftError.draftNotFound(id) }
            guard now.timeIntervalSince(draft.createdAt) <= ttl else {
                drafts.removeValue(forKey: id)
                throw CapabilityDraftError.draftExpired(id)
            }
            guard draft.snapshotID == snapshot.id else { throw CapabilityDraftError.staleSnapshot }
            guard draft.sceneRevision == currentSceneRevision else {
                throw CapabilityDraftError.staleSceneRevision(expected: draft.sceneRevision,
                                                              actual: currentSceneRevision)
            }
            guard let exposed = snapshot.contract(id: draft.capabilityID),
                  let current = registry.descriptor(for: draft.capabilityID)?.contract,
                  exposed.version == draft.capabilityVersion,
                  exposed.schemaHash == draft.schemaHash,
                  exposed.access == current.access,
                  exposed.source.pluginID == draft.sourcePluginID,
                  exposed.source == current.source,
                  current.version == draft.capabilityVersion,
                  current.schemaHash == draft.schemaHash,
                  try pluginAuthority(for: exposed, snapshot: snapshot)
                    == draft.pluginAuthority else {
                throw CapabilityDraftError.contractChanged(draft.capabilityID)
            }
            do {
                try JSONSchemaValidator.validate(data: draft.validatedInput,
                                                 against: current.inputSchema)
            } catch {
                throw CapabilityDraftError.invalidInput(String(describing: error))
            }
            return draft
        }
    }

    public func consume(ids: [UUID]) {
        for id in ids { drafts.removeValue(forKey: id) }
    }

    public func removeAll() {
        drafts.removeAll()
    }

    private func purgeExpired(now: Date) {
        drafts = drafts.filter { now.timeIntervalSince($0.value.createdAt) <= ttl }
    }

    private func canonicalise(_ data: Data) throws -> Data {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CapabilityDraftError.invalidInput("invalid JSON")
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CapabilityDraftError.invalidInput("input must be a JSON object")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func pluginAuthority(
        for contract: CapabilityContract,
        snapshot: CapabilityExposureSnapshot
    ) throws -> PluginCapabilityAuthority? {
        guard let pluginID = contract.source.pluginID else { return nil }
        guard let authority = snapshot.authority(forPluginID: pluginID),
              authority.pluginID == pluginID else {
            throw CapabilityDraftError.contractChanged(contract.id)
        }
        return authority
    }
}

/// Compatibility lowering used while the old SceneEditStep wire format remains.
/// Plugin composition also lowers to these same host-owned primitive calls.
public enum SceneCapabilityDraftLowering {
    public static func plan(summary: String,
                            reasoning: String? = nil,
                            drafts: [CapabilityInvocationDraft]) throws -> SceneEditPlan {
        let steps = try drafts.map { draft -> SceneEditStep in
            guard let operation = SceneEditOp(capabilityID: draft.capabilityID) else {
                throw CapabilityDraftError.unsupportedBuiltInCapability(draft.capabilityID)
            }
            guard var input = try JSONSerialization.jsonObject(with: draft.validatedInput) as? [String: Any] else {
                throw CapabilityDraftError.invalidInput("draft input is not an object")
            }
            input["op"] = operation.rawValue
            let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            return try JSONDecoder().decode(SceneEditStep.self, from: data)
        }
        return SceneEditPlan(summary: summary, reasoning: reasoning, steps: steps)
    }
}
