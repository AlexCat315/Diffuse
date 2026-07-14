import CapabilityRuntime
import Foundation
import IntentRuntime

public enum CapabilityExposureSessionError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidSessionID
    case sessionNotFound
    case readCapabilityRequiresHostAdapter(String)

    public var description: String {
        switch self {
        case .invalidSessionID: return "capability session id must be a UUID"
        case .sessionNotFound: return "capability exposure session was not found or expired"
        case let .readCapabilityRequiresHostAdapter(id):
            return "read capability '\(id)' must be executed by a host adapter"
        }
    }
}

public struct CapabilitySearchActivation: Sendable, Equatable {
    public var snapshotID: UUID
    /// Contracts matching the current search (or core reads at bootstrap).
    public var contracts: [CapabilityContract]
    /// Complete current allow-list, used by transports to refresh tools after
    /// a scene-revision reset without retaining stale tool definitions.
    public var activeContracts: [CapabilityContract]
    public var activeToolCount: Int

    public init(snapshotID: UUID,
                contracts: [CapabilityContract],
                activeContracts: [CapabilityContract]? = nil,
                activeToolCount: Int) {
        self.snapshotID = snapshotID
        self.contracts = contracts
        self.activeContracts = activeContracts ?? contracts
        self.activeToolCount = activeToolCount
    }
}

/// Transport-neutral session state used by MCP and other local model clients.
/// It owns the host-side tool-name allow-list and Draft store; clients receive
/// generated tool definitions but never authority-bearing registry objects.
public actor CapabilityExposureSessionStore {
    public static let maximumSessions = 8
    public static let maximumActiveCapabilities = 16

    private struct Entry {
        var snapshot: CapabilityExposureSnapshot
        var drafts: CapabilityDraftStore
        var lastAccessedAt: Date
    }

    private let registry: CapabilityRegistry
    private let ttl: TimeInterval
    private var generation: UInt64 = 0
    private var sessions: [UUID: Entry] = [:]

    public init(registry: CapabilityRegistry = .aiDefault,
                ttl: TimeInterval = CapabilityDraftStore.defaultTTL) {
        self.registry = registry
        self.ttl = max(1, ttl)
    }

    /// Opens (or resumes) a session with only the small host-approved read set.
    /// This is used before a model has searched for any write capability.
    public func bootstrap(sessionID rawSessionID: String,
                          sceneRevision: UInt64,
                          now: Date = Date()) throws -> CapabilitySearchActivation {
        let sessionID = try validatedSessionID(rawSessionID)
        purgeExpired(now: now)
        var entry = sessionEntry(id: sessionID,
                                 sceneRevision: sceneRevision,
                                 now: now)
        entry.lastAccessedAt = now
        sessions[sessionID] = entry
        return CapabilitySearchActivation(snapshotID: entry.snapshot.id,
                                          contracts: entry.snapshot.contracts,
                                          activeContracts: entry.snapshot.contracts,
                                          activeToolCount: entry.snapshot.contracts.count)
    }

    public func search(sessionID rawSessionID: String,
                       query: String,
                       domain: String? = nil,
                       access: CapabilityAccess? = nil,
                       sceneRevision: UInt64,
                       now: Date = Date()) throws -> CapabilitySearchActivation {
        let sessionID = try validatedSessionID(rawSessionID)
        purgeExpired(now: now)
        var entry = sessionEntry(id: sessionID,
                                 sceneRevision: sceneRevision,
                                 now: now)

        let searchPolicy = CapabilityExposurePolicy(
            activeReleasePhase: .stable,
            allowedDomains: domain.map { [$0] } ?? ["scene"],
            maximumCapabilities: max(Self.maximumActiveCapabilities,
                                     registry.allVerbs().count)
        )
        let candidates = registry.searchContracts(query: query,
                                                  policy: searchPolicy,
                                                  limit: registry.allVerbs().count)
            .filter { !$0.id.hasPrefix("system.") }
            .filter { $0.domain == "scene" }
            .filter { access == nil || $0.access == access }

        let existingIDs = entry.snapshot.contracts.map(\.id)
        let existingSet = Set(existingIDs)
        let available = max(0, Self.maximumActiveCapabilities - existingIDs.count)
        let additions = candidates.filter { !existingSet.contains($0.id) }.prefix(available)
        let preferredIDs = existingIDs + additions.map(\.id)
        let includedIDs = Set(preferredIDs)

        generation &+= 1
        var expanded = registry.exposureSnapshot(
            policy: CapabilityExposurePolicy(activeReleasePhase: .stable,
                                             allowedDomains: ["scene"],
                                             maximumCapabilities: Self.maximumActiveCapabilities),
            sceneRevision: sceneRevision,
            generation: generation,
            preferredCapabilityIDs: preferredIDs,
            includedCapabilityIDs: includedIDs
        )
        // Expanding an allow-list must not invalidate Drafts already created in
        // the same session. Revision changes create a fresh Entry above.
        expanded.id = entry.snapshot.id
        expanded.createdAt = entry.snapshot.createdAt
        entry.snapshot = expanded
        entry.lastAccessedAt = now
        sessions[sessionID] = entry

        let activated = candidates.filter { expanded.contract(id: $0.id) != nil }
        return CapabilitySearchActivation(snapshotID: expanded.id,
                                          contracts: activated,
                                          activeContracts: expanded.contracts,
                                          activeToolCount: expanded.contracts.count)
    }

    public func contract(sessionID rawSessionID: String,
                         toolName: String,
                         sceneRevision: UInt64,
                         now: Date = Date()) throws -> CapabilityContract {
        let entry = try activeEntry(sessionID: rawSessionID,
                                    sceneRevision: sceneRevision,
                                    now: now)
        guard let contract = entry.snapshot.contract(forToolName: toolName) else {
            throw CapabilityDraftError.unknownTool(toolName)
        }
        return contract
    }

    public func createDraft(sessionID rawSessionID: String,
                            toolName: String,
                            input: Data,
                            sceneRevision: UInt64,
                            now: Date = Date()) async throws -> CapabilityInvocationDraft {
        let sessionID = try validatedSessionID(rawSessionID)
        let entry = try activeEntry(sessionID: rawSessionID,
                                    sceneRevision: sceneRevision,
                                    now: now)
        guard let contract = entry.snapshot.contract(forToolName: toolName) else {
            throw CapabilityDraftError.unknownTool(toolName)
        }
        guard contract.access.isWrite else {
            throw CapabilityExposureSessionError.readCapabilityRequiresHostAdapter(contract.id)
        }
        let draft = try await entry.drafts.createDraft(toolName: toolName,
                                                       input: input,
                                                       snapshot: entry.snapshot,
                                                       currentSceneRevision: sceneRevision,
                                                       now: now)
        if var current = sessions[sessionID] {
            current.lastAccessedAt = now
            sessions[sessionID] = current
        }
        return draft
    }

    public func validatedDrafts(sessionID rawSessionID: String,
                                ids: [UUID],
                                sceneRevision: UInt64,
                                now: Date = Date()) async throws
        -> (drafts: [CapabilityInvocationDraft], snapshot: CapabilityExposureSnapshot) {
        let sessionID = try validatedSessionID(rawSessionID)
        let entry = try activeEntry(sessionID: rawSessionID,
                                    sceneRevision: sceneRevision,
                                    now: now)
        let drafts = try await entry.drafts.validatedDrafts(ids: ids,
                                                            snapshot: entry.snapshot,
                                                            currentSceneRevision: sceneRevision,
                                                            now: now)
        if var current = sessions[sessionID] {
            current.lastAccessedAt = now
            sessions[sessionID] = current
        }
        return (drafts, entry.snapshot)
    }

    public func consume(sessionID rawSessionID: String,
                        ids: [UUID]) async throws {
        let sessionID = try validatedSessionID(rawSessionID)
        guard let entry = sessions[sessionID] else {
            throw CapabilityExposureSessionError.sessionNotFound
        }
        await entry.drafts.consume(ids: ids)
    }

    public func removeSession(_ rawSessionID: String) async throws {
        let sessionID = try validatedSessionID(rawSessionID)
        if let entry = sessions.removeValue(forKey: sessionID) {
            await entry.drafts.removeAll()
        }
    }

    private func activeEntry(sessionID rawSessionID: String,
                             sceneRevision: UInt64,
                             now: Date) throws -> Entry {
        let sessionID = try validatedSessionID(rawSessionID)
        purgeExpired(now: now)
        guard let entry = sessions[sessionID],
              entry.snapshot.sceneRevision == sceneRevision,
              now.timeIntervalSince(entry.snapshot.createdAt) >= 0,
              now.timeIntervalSince(entry.snapshot.createdAt) <= ttl else {
            sessions.removeValue(forKey: sessionID)
            throw CapabilityExposureSessionError.sessionNotFound
        }
        return entry
    }

    private func sessionEntry(id: UUID,
                              sceneRevision: UInt64,
                              now: Date) -> Entry {
        if let existing = sessions[id],
           existing.snapshot.sceneRevision == sceneRevision,
           now.timeIntervalSince(existing.snapshot.createdAt) >= 0,
           now.timeIntervalSince(existing.snapshot.createdAt) <= ttl {
            return existing
        }
        sessions.removeValue(forKey: id)
        if sessions.count >= Self.maximumSessions,
           let oldest = sessions.min(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt })?.key {
            sessions.removeValue(forKey: oldest)
        }
        generation &+= 1
        let coreReadIDs: Set<String> = [
            "scene.get_entities", "scene.get_selection", "scene.find_entities",
        ]
        let snapshot = registry.exposureSnapshot(
            policy: CapabilityExposurePolicy(activeReleasePhase: .stable,
                                             allowedDomains: ["scene"],
                                             maximumCapabilities: Self.maximumActiveCapabilities),
            sceneRevision: sceneRevision,
            generation: generation,
            preferredCapabilityIDs: Array(coreReadIDs).sorted(),
            includedCapabilityIDs: coreReadIDs
        )
        return Entry(snapshot: snapshot,
                     drafts: CapabilityDraftStore(registry: registry, ttl: ttl),
                     lastAccessedAt: now)
    }

    private func purgeExpired(now: Date) {
        sessions = sessions.filter {
            let age = now.timeIntervalSince($0.value.snapshot.createdAt)
            return age >= 0 && age <= ttl
        }
    }

    private func validatedSessionID(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else {
            throw CapabilityExposureSessionError.invalidSessionID
        }
        return id
    }
}
