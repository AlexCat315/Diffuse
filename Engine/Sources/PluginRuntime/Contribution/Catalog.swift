import Foundation

public struct ContributedValue<Value: Sendable>: Sendable {
    public let pluginID: String
    public let value: Value
}

public struct ContributionSnapshot<Value: Sendable>: Sendable {
    public let revision: UInt64
    public let values: [ContributedValue<Value>]
}

/// One domain's enabled declarations. Readers receive an immutable snapshot.
public final class ContributionCatalog<Value: Sendable>: @unchecked Sendable {
    private struct Entry {
        let generation: UUID
        let values: [Value]
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var revision: UInt64 = 0

    public init() {}

    public func register(_ values: [Value], pluginID: String) throws -> Registration {
        let generation = UUID()
        try lock.withLock {
            guard entries[pluginID] == nil else { throw PluginManagerError.alreadyEnabled(pluginID) }
            entries[pluginID] = Entry(generation: generation, values: values)
            revision &+= 1
        }
        return Registration { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard self.entries[pluginID]?.generation == generation else { return }
                self.entries.removeValue(forKey: pluginID)
                self.revision &+= 1
            }
        }
    }

    public var snapshot: ContributionSnapshot<Value> {
        lock.withLock {
            ContributionSnapshot(revision: revision, values: entries.keys.sorted().flatMap { id in
                (entries[id]?.values ?? []).map { ContributedValue(pluginID: id, value: $0) }
            })
        }
    }
}

