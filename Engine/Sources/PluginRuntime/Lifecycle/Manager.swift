import Foundation
import CapabilityRuntime

/// The sole owner of package state, activation and contribution release.
/// Operations queue internally, so callers need not arrange lifecycle ordering.
public final class PluginManager: @unchecked Sendable {
    final class Entry {
        let package: ValidatedPluginPackage
        let inspection: PluginInspection
        var authorization: PluginAuthorizationRecord?
        var scope: DisposalScope?
        var binding: PluginExecutionBinding?
        var failure: String?

        init(_ package: ValidatedPluginPackage) {
            self.package = package
            inspection = PluginInspection(package: package, contracts: PluginWITContractDeriver.contracts(for: package))
        }
    }

    let lock = NSLock()
    var entries: [String: Entry] = [:]
    var epoch: UInt64 = 0
    var stopped = false
    var pendingCount = 0
    var events = Set<String>()
    let registrar: ContributionRegistrar
    let loader: PluginPackageLoader
    let hostCapabilities: [String: Int]
    var driver: PluginRuntimeDriver?
    @MainActor private var tail: Task<Void, Never>?

    public init(registrar: ContributionRegistrar, loader: PluginPackageLoader = .init(),
                hostCapabilities: [String: Int] = [:]) {
        self.registrar = registrar
        self.loader = loader
        self.hostCapabilities = hostCapabilities
    }

    public func configureRuntime(_ driver: PluginRuntimeDriver) {
        lock.withLock { self.driver = driver }
    }

    public var isBusy: Bool { lock.withLock { pendingCount > 0 } }

    public var statuses: [PluginStatus] {
        lock.withLock {
            entries.keys.sorted().compactMap { id in
                guard let entry = entries[id] else { return nil }
                return PluginStatus(inspection: entry.inspection,
                    phase: entry.failure != nil ? .failed : entry.binding != nil ? .activated
                        : entry.scope != nil ? .enabled : .installed,
                    isEnabled: entry.scope != nil, failure: entry.failure)
            }
        }
    }

    public var enabledInspections: [PluginInspection] { statuses.filter(\.isEnabled).map(\.inspection) }
    public var enabledManifests: [String: GuavaPluginManifest] {
        Dictionary(uniqueKeysWithValues: enabledInspections.map { ($0.manifest.id, $0.manifest) })
    }
    public var activeBindings: [String: PluginExecutionBinding] {
        lock.withLock { entries.compactMapValues(\.binding) }
    }
    public var packageURLs: [String: URL] {
        lock.withLock { entries.mapValues(\.package.rootURL) }
    }

    @MainActor
    public func install(at url: URL) async throws -> PluginInspection {
        try await enqueue {
            let package = try self.loader.load(at: url)
            let id = package.manifest.id
            return try self.lock.withLock {
                guard !self.stopped else { throw PluginManagerError.stopped }
                guard self.entries[id]?.scope == nil else { throw PluginManagerError.alreadyEnabled(id) }
                let entry = Entry(package)
                self.entries[id] = entry
                return entry.inspection
            }
        }
    }

    @MainActor
    public func enable(at url: URL, authorization: PluginAuthorizationRecord) async throws -> PluginInspection {
        try await enqueue {
            let package = try self.loader.load(at: url)
            let entry = Entry(package), id = package.manifest.id
            guard authorization.isStillValid(for: entry.inspection) else { throw PluginAuthorizationError.noLongerValid }
            guard self.lock.withLock({ self.entries[id]?.scope == nil }) else {
                throw PluginManagerError.alreadyEnabled(id)
            }
            let unmet = PluginRequirementResolver.unmet(package.manifest.requires, requiredBy: id,
                enabledPlugins: self.enabledManifests.mapValues(\.version),
                providedCapabilities: self.availableCapabilities)
            guard unmet.isEmpty else { throw UnmetPluginRequirements(pluginID: id, violations: unmet) }
            self.lock.withLock { entry.authorization = authorization; self.entries[id] = entry }
            do {
                let scope = try self.registrar.install(package)
                let accepted = self.lock.withLock {
                    guard !self.stopped else { return false }
                    entry.scope = scope
                    return true
                }
                guard accepted else { try? scope.dispose(); throw PluginManagerError.stopped }
                let seen = self.lock.withLock { self.events }
                if Self.activationEvents(for: entry).contains(where: { event in seen.contains(where: { Self.matches(event, $0) }) }) {
                    try await self.activateEntry(id, visiting: [])
                }
                return entry.inspection
            } catch {
                self.lock.withLock { entry.failure = String(describing: error) }
                throw error
            }
        }
    }

    @MainActor
    public func disable(id: String) async throws {
        try await enqueue {
            guard self.enabledManifests[id] != nil else { throw PluginManagerError.notEnabled(id) }
            let dependents = self.dependents(of: id)
            guard dependents.isEmpty else { throw RequiredPluginStillNeeded(pluginID: id, dependents: dependents) }
            try await self.withdraw([id], failure: nil)
        }
    }

    @MainActor
    public func uninstall(id: String) async throws {
        try await enqueue {
            guard self.lock.withLock({ self.entries[id] != nil }) else { throw PluginManagerError.notInstalled(id) }
            let dependents = self.dependents(of: id)
            guard dependents.isEmpty else { throw RequiredPluginStillNeeded(pluginID: id, dependents: dependents) }
            try await self.withdraw([id], failure: nil)
            self.lock.withLock { _ = self.entries.removeValue(forKey: id) }
        }
    }

    @MainActor
    public func reload(id: String) async throws {
        try await enqueue {
            guard let previous = self.lock.withLock({ self.entries[id] }), previous.scope != nil,
                  let authorization = previous.authorization else { throw PluginManagerError.notEnabled(id) }
            let next = Entry(try self.loader.load(at: previous.package.rootURL))
            guard authorization.isStillValid(for: next.inspection) else { throw PluginAuthorizationError.noLongerValid }
            let wasActive = previous.binding != nil
            do {
                try await self.withdraw([id], failure: nil)
                let scope = try self.registrar.install(next.package)
                let accepted = self.lock.withLock {
                    guard !self.stopped else { return false }
                    next.authorization = authorization; next.scope = scope
                    self.entries[id] = next
                    return true
                }
                guard accepted else { try? scope.dispose(); throw PluginManagerError.stopped }
                if wasActive { try await self.activateEntry(id, visiting: []) }
            } catch {
                let affected = self.dependentClosure(of: id)
                try? await self.withdraw(affected, failure: String(describing: error))
                throw error
            }
        }
    }

    @MainActor
    public func activate(event: String) async throws {
        guard PluginActivationEvent.isValid(event) else {
            throw PluginManifestValidationError.invalidContribution("activation")
        }
        try await enqueue {
            self.lock.withLock { _ = self.events.insert(event) }
            let ids = self.lock.withLock {
                self.entries.keys.sorted().filter { id in
                    guard let entry = self.entries[id], entry.scope != nil, entry.package.runtime != nil else { return false }
                    return Self.activationEvents(for: entry).contains { Self.matches($0, event) }
                }
            }
            var firstError: (any Error)?
            for id in ids {
                do { try await self.activateEntry(id, visiting: []) }
                catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
        }
    }

    @MainActor
    public func activate(id: String) async throws -> PluginExecutionBinding {
        try await enqueue {
            try await self.activateEntry(id, visiting: [])
            guard let binding = self.activeBindings[id] else { throw PluginPackageError.runtimeRequired }
            return binding
        }
    }

    @MainActor @discardableResult
    public func invalidateRuntime(before generation: UInt64? = nil) async -> Bool {
        (try? await enqueue {
            var affected = Set<String>()
            for (id, binding) in self.activeBindings where generation.map({ binding.hostGeneration < $0 }) ?? true {
                affected.formUnion(self.dependentClosure(of: id))
            }
            try? await self.withdraw(affected.sorted(), failure: "Plugin host invalidated")
            return !affected.isEmpty
        }) ?? false
    }

    public func stop() {
        let (scopes, runtime) = lock.withLock { () -> ([DisposalScope], PluginRuntimeDriver?) in
            guard !stopped else { return ([], nil) }
            stopped = true
            epoch &+= 1
            let manifests = entries.mapValues(\.package.manifest)
            var seen = Set<String>(), ordered: [String] = []
            func visit(_ id: String) {
                guard seen.insert(id).inserted else { return }
                for dependent in PluginRequirementResolver.dependents(of: id,
                    providing: Set(entries[id]?.inspection.contracts.map(\.id) ?? []), among: manifests) {
                    visit(dependent)
                }
                ordered.append(id)
            }
            for id in entries.keys.sorted() { visit(id) }
            let scopes = ordered.compactMap { entries[$0]?.scope }
            entries.removeAll()
            return (scopes, driver)
        }
        for scope in scopes { try? scope.dispose() }
        runtime?.stop()
    }

    @MainActor
    func enqueue<T: Sendable>(_ operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        lock.withLock { pendingCount += 1 }
        let task = Task { @MainActor in
            await previous?.value
            defer { self.lock.withLock { self.pendingCount -= 1 } }
            guard !self.lock.withLock({ self.stopped }) else { throw PluginManagerError.stopped }
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

