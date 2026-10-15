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
        /// Owns the teardown registered for this entry. Disposing it releases
        /// the Draft store; every path that drops an entry disposes its scope
        /// instead of hand-running `drafts.removeAll()`.
        let scope: DisposalScope
    }

    private var registry: CapabilityRegistry
    private let ttl: TimeInterval
    private var exposurePolicy: CapabilityExposurePolicy
    private var pluginAuthorities: [String: PluginCapabilityAuthority]
    /// Host tool policy evaluated before a draft is created; `nil` is a
    /// pass-through.
    private let toolPolicy: ToolPolicy?
    private var workflowDocumentID: UUID?
    private var generation: UInt64 = 0
    private var sessions: [UUID: Entry] = [:]

    public init(registry: CapabilityRegistry = .aiDefault,
                ttl: TimeInterval = CapabilityDraftStore.defaultTTL,
                exposurePolicy: CapabilityExposurePolicy = CapabilityExposurePolicy(
                    allowedDomains: ["scene"]
                ),
                pluginAuthorities: [String: PluginCapabilityAuthority] = [:],
                toolPolicy: ToolPolicy? = nil) {
        self.registry = registry
        self.ttl = max(1, ttl)
        self.exposurePolicy = exposurePolicy
        self.pluginAuthorities = pluginAuthorities
        self.toolPolicy = toolPolicy
    }

    /// Atomically replaces the Registry and its matching exposure authority.
    /// Invalidation is scoped: sessions whose snapshots reference only
    /// unchanged, still-enabled plugins survive; a policy change outside
    /// plugin scoping, or a changed/removed plugin authority, drops the
    /// affected sessions and their Drafts first, so tools from a disabled or
    /// upgraded plugin cannot survive a dynamic catalog change.
    public func replaceRegistry(
        _ registry: CapabilityRegistry,
        exposurePolicy: CapabilityExposurePolicy,
        pluginAuthorities: [String: PluginCapabilityAuthority]
    ) async {
        // Switch authority first, then unwind the invalidated generation. An
        // interleaved caller during the unwind mints under the new Registry.
        let previousAuthorities = self.pluginAuthorities
        let previousPolicy = self.exposurePolicy
        self.registry = registry
        self.exposurePolicy = exposurePolicy
        self.pluginAuthorities = pluginAuthorities
        generation &+= 1
        await discardInvalidatedSessions(previousAuthorities: previousAuthorities,
                                         previousPolicy: previousPolicy)
    }

    /// A workflow or document change invalidates tools and drafts minted under
    /// the previous authoring context, including equal-revision scene swaps.
    public func setWorkflowScope(policy: CapabilityExposurePolicy, documentID: UUID) async {
        guard policy != exposurePolicy || documentID != workflowDocumentID else { return }
        let previous = sessions
        sessions.removeAll()
        exposurePolicy = policy
        workflowDocumentID = documentID
        generation &+= 1
        for entry in previous.values {
            await entry.scope.disposeAll()
        }
    }

    /// Plugin enablement, authorisation, upgrades, and PluginHost restarts all
    /// replace the authority set. Sessions that reference a changed, newly
    /// disabled, or removed plugin are discarded because their tool names and
    /// Drafts were minted under a different executable boundary; sessions that
    /// reference only unchanged plugins survive.
    public func replacePluginAuthorities(
        _ authorities: [String: PluginCapabilityAuthority],
        enabledPluginIDs: Set<String>
    ) async {
        let previousAuthorities = pluginAuthorities
        let previousPolicy = exposurePolicy
        pluginAuthorities = authorities
        exposurePolicy.enabledPluginIDs = enabledPluginIDs
        generation &+= 1
        await discardInvalidatedSessions(previousAuthorities: previousAuthorities,
                                         previousPolicy: previousPolicy)
    }

    /// Opens (or resumes) a session with only the small host-approved read set.
    /// This is used before a model has searched for any write capability.
    public func bootstrap(sessionID rawSessionID: String,
                          sceneRevision: UInt64,
                          now: Date = Date()) async throws -> CapabilitySearchActivation {
        let sessionID = try validatedSessionID(rawSessionID)
        await purgeExpired(now: now)
        var entry = try await sessionEntry(id: sessionID,
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
                       now: Date = Date()) async throws -> CapabilitySearchActivation {
        let sessionID = try validatedSessionID(rawSessionID)
        await purgeExpired(now: now)
        var entry = try await sessionEntry(id: sessionID,
                                       sceneRevision: sceneRevision,
                                       now: now)

        var searchPolicy = exposurePolicy
        searchPolicy.activeReleasePhase = .stable
        searchPolicy.allowedDomains = domain.map { requested in
            exposurePolicy.allowedDomains.map { $0.intersection([requested]) } ?? [requested]
        } ?? exposurePolicy.allowedDomains
        searchPolicy.maximumCapabilities = max(Self.maximumActiveCapabilities, registry.allVerbs().count)

        let candidates = registry.searchContracts(query: query,
                                                  policy: searchPolicy,
                                                  pluginAuthorities: pluginAuthorities,
                                                  limit: registry.allVerbs().count)
            .filter { !$0.id.hasPrefix("system.") }
            .filter { access == nil || $0.access == access }

        let existingIDs = entry.snapshot.contracts.map(\.id)
        let existingSet = Set(existingIDs)
        let available = max(0, Self.maximumActiveCapabilities - existingIDs.count)
        let additions = candidates.filter { !existingSet.contains($0.id) }.prefix(available)
        let preferredIDs = existingIDs + additions.map(\.id)
        let includedIDs = Set(preferredIDs)

        generation &+= 1
        var activePolicy = exposurePolicy
        activePolicy.activeReleasePhase = .stable
        activePolicy.maximumCapabilities = Self.maximumActiveCapabilities
        var expanded = registry.exposureSnapshot(
            policy: activePolicy,
            sceneRevision: sceneRevision,
            generation: generation,
            preferredCapabilityIDs: preferredIDs,
            includedCapabilityIDs: includedIDs,
            pluginAuthorities: pluginAuthorities
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
                         now: Date = Date()) async throws -> CapabilityContract {
        let entry = try await activeEntry(sessionID: rawSessionID,
                                          sceneRevision: sceneRevision,
                                          now: now)
        guard let contract = entry.snapshot.contract(forToolName: toolName) else {
            throw CapabilityDraftError.unknownTool(toolName)
        }
        return contract
    }

    public func snapshot(sessionID rawSessionID: String,
                         sceneRevision: UInt64,
                         now: Date = Date()) async throws -> CapabilityExposureSnapshot {
        try await activeEntry(sessionID: rawSessionID,
                              sceneRevision: sceneRevision,
                              now: now).snapshot
    }

    public func createDraft(sessionID rawSessionID: String,
                            toolName: String,
                            input: Data,
                            sceneRevision: UInt64,
                            now: Date = Date()) async throws -> CapabilityInvocationDraft {
        let sessionID = try validatedSessionID(rawSessionID)
        let entry = try await activeEntry(sessionID: rawSessionID,
                                          sceneRevision: sceneRevision,
                                          now: now)
        guard let contract = entry.snapshot.contract(forToolName: toolName) else {
            throw CapabilityDraftError.unknownTool(toolName)
        }
        guard contract.access.isWrite else {
            throw CapabilityExposureSessionError.readCapabilityRequiresHostAdapter(contract.id)
        }
        let validatedInput: Data
        if let toolPolicy {
            validatedInput = try toolPolicy.evaluate(
                ToolCall(name: toolName, arguments: input, origin: .mcp)
            ).arguments
        } else {
            validatedInput = input
        }
        let draft = try await entry.drafts.createDraft(toolName: toolName,
                                                       input: validatedInput,
                                                       snapshot: entry.snapshot,
                                                       currentSceneRevision: sceneRevision,
                                                       now: now,
                                                       registry: registry)
        try requireCurrentEntry(entry, id: sessionID)
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
        let entry = try await activeEntry(sessionID: rawSessionID,
                                          sceneRevision: sceneRevision,
                                          now: now)
        let drafts = try await entry.drafts.validatedDrafts(ids: ids,
                                                            snapshot: entry.snapshot,
                                                            currentSceneRevision: sceneRevision,
                                                            now: now,
                                                            registry: registry)
        try requireCurrentEntry(entry, id: sessionID)
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
            await entry.scope.disposeAll()
        }
    }

    private func activeEntry(sessionID rawSessionID: String,
                             sceneRevision: UInt64,
                             now: Date) async throws -> Entry {
        let sessionID = try validatedSessionID(rawSessionID)
        await purgeExpired(now: now)
        guard let entry = sessions[sessionID],
              entry.snapshot.sceneRevision == sceneRevision,
              snapshotAuthoritiesAreCurrent(entry.snapshot),
              now.timeIntervalSince(entry.snapshot.createdAt) >= 0,
              now.timeIntervalSince(entry.snapshot.createdAt) <= ttl else {
            if let discarded = sessions.removeValue(forKey: sessionID) {
                await discarded.scope.disposeAll()
            }
            throw CapabilityExposureSessionError.sessionNotFound
        }
        return entry
    }

    private func sessionEntry(id: UUID,
                              sceneRevision: UInt64,
                              now: Date) async throws -> Entry {
        if let existing = sessions[id],
           existing.snapshot.sceneRevision == sceneRevision,
           now.timeIntervalSince(existing.snapshot.createdAt) >= 0,
           now.timeIntervalSince(existing.snapshot.createdAt) <= ttl {
            return existing
        }
        // Everything up to the install is synchronous, so a concurrent create
        // either sees the previous entry or the fresh one — never a half state.
        // The previous generation unwinds after the new entry is visible.
        let replaced = sessions.removeValue(forKey: id)
        var evicted: Entry?
        if sessions.count >= Self.maximumSessions,
           let oldest = sessions.min(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt })?.key {
            evicted = sessions.removeValue(forKey: oldest)
        }
        generation &+= 1
        let coreReadIDs: Set<String> = [
            "scene.get_entities", "scene.get_selection", "scene.find_entities",
        ]
        var initialPolicy = exposurePolicy
        initialPolicy.maximumCapabilities = Self.maximumActiveCapabilities
        let snapshot = registry.exposureSnapshot(
            policy: initialPolicy,
            sceneRevision: sceneRevision,
            generation: generation,
            preferredCapabilityIDs: Array(coreReadIDs).sorted(),
            includedCapabilityIDs: coreReadIDs,
            pluginAuthorities: pluginAuthorities
        )
        let drafts = CapabilityDraftStore(registry: registry, ttl: ttl)
        let scope = DisposalScope()
        scope.track { await drafts.removeAll() }
        let entry = Entry(snapshot: snapshot,
                          drafts: drafts,
                          lastAccessedAt: now,
                          scope: scope)
        sessions[id] = entry
        if let replaced {
            await replaced.scope.disposeAll()
        }
        if let evicted {
            await evicted.scope.disposeAll()
        }
        try requireCurrentEntry(entry, id: id)
        return entry
    }

    /// An actor hop for draft creation or teardown can invalidate/replace the
    /// entry. Never return authority or reinstall state from that old lifetime.
    private func requireCurrentEntry(_ entry: Entry, id: UUID) throws {
        guard sessions[id]?.snapshot.id == entry.snapshot.id,
              snapshotAuthoritiesAreCurrent(entry.snapshot) else {
            throw CapabilityExposureSessionError.sessionNotFound
        }
    }

    private func purgeExpired(now: Date) async {
        var expired: [DisposalScope] = []
        sessions = sessions.filter {
            let age = now.timeIntervalSince($0.value.snapshot.createdAt)
            let keep = age >= 0 && age <= ttl
            if !keep { expired.append($0.value.scope) }
            return keep
        }
        for scope in expired {
            await scope.disposeAll()
        }
    }

    /// Drops sessions whose referenced plugins changed authority, were
    /// disabled, or whose exposure policy changed outside plugin scoping.
    /// Built-in-only sessions survive a plugin catalog change, and a session
    /// referencing a plugin whose authority is byte-identical survives a
    /// reload of that plugin.
    private func discardInvalidatedSessions(
        previousAuthorities: [String: PluginCapabilityAuthority],
        previousPolicy: CapabilityExposurePolicy
    ) async {
        let policyChanged = exposurePolicy.scopedIdentity
            != previousPolicy.scopedIdentity
        var discarded: [DisposalScope] = []
        sessions = sessions.filter { _, entry in
            let referencedPluginIDs = Set(entry.snapshot.contracts.compactMap(\.source.pluginID))
            let keep: Bool
            if policyChanged {
                keep = false
            } else {
                keep = referencedPluginIDs.allSatisfy { pluginID in
                    exposurePolicy.enabledPluginIDs.contains(pluginID)
                        && pluginAuthorities[pluginID] == previousAuthorities[pluginID]
                } && snapshotContractsAreCurrent(entry.snapshot)
            }
            if !keep { discarded.append(entry.scope) }
            return keep
        }
        for scope in discarded {
            await scope.disposeAll()
        }
    }

    private func validatedSessionID(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else {
            throw CapabilityExposureSessionError.invalidSessionID
        }
        return id
    }

    private func snapshotAuthoritiesAreCurrent(
        _ snapshot: CapabilityExposureSnapshot
    ) -> Bool {
        guard snapshotContractsAreCurrent(snapshot) else { return false }
        let pluginIDs = Set(snapshot.contracts.compactMap(\.source.pluginID))
        for pluginID in pluginIDs {
            guard snapshot.authority(forPluginID: pluginID) == pluginAuthorities[pluginID],
                  exposurePolicy.enabledPluginIDs.contains(pluginID) else {
                return false
            }
        }
        return true
    }

    private func snapshotContractsAreCurrent(_ snapshot: CapabilityExposureSnapshot) -> Bool {
        snapshot.contracts.allSatisfy { contract in
            registry.descriptor(for: contract.id)?.contract == contract
        }
    }
}

private extension CapabilityExposurePolicy {
    /// Policy identity excluding the enabled plugin set, which is compared per
    /// referenced plugin through the plugin authority records instead.
    var scopedIdentity: CapabilityExposurePolicy {
        var copy = self
        copy.enabledPluginIDs = []
        return copy
    }
}
