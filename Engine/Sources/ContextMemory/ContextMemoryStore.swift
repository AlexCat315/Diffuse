import Foundation
import IntentRuntime

// MARK: - ContextMemoryStore

/// Long-term AI context memory, persisted as a JSON file between sessions.
///
/// Entries are produced by a `ReducerRegistry` applied to incoming `WorldEvent`s.
/// Reducers must be pure functions so that replaying the same event sequence
/// always yields an identical entry set.
///
/// **Invariants:**
/// - Entry payloads contain only LLM-safe strings / numeric literals.
///   No vectors, embeddings, or raw image bytes.
/// - Maximum `capacity` entries are retained; excess is evicted by ascending importance.
public actor ContextMemoryStore {
    private var entries: [String: ContextEntry]
    private let reducers: ReducerRegistry
    private let capacity: Int
    private let storageURL: URL?

    public init(reducers: ReducerRegistry = .default,
                capacity: Int = 512,
                storageURL: URL? = nil) throws {
        self.reducers = reducers
        self.capacity = max(1, capacity)
        self.storageURL = storageURL

        if let url = storageURL, FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let loaded = try JSONDecoder().decode([ContextEntry].self, from: data)
            var index: [String: ContextEntry] = [:]
            for entry in loaded { index[entry.id] = entry }
            self.entries = index
        } else {
            self.entries = [:]
        }
    }

    // MARK: - Event ingestion

    /// Applies `event` through all registered reducers and applies the resulting mutations.
    public func apply(event: WorldEvent) {
        let mutations = reducers.apply(existing: entries, event: event)
        for mutation in mutations {
            switch mutation {
            case let .upsert(entry): entries[entry.id] = entry
            case let .delete(id):   entries.removeValue(forKey: id)
            }
        }
        evictIfNeeded()
    }

    /// Applies a batch of events in order.
    public func apply(events: [WorldEvent]) {
        for event in events { apply(event: event) }
    }

    // MARK: - Lookup

    public func lookup(subject: String) -> [ContextEntry] {
        entries.values.filter { $0.subject == subject }
            .sorted { $0.importance > $1.importance }
    }

    public func lookup(kind: EntryKind) -> [ContextEntry] {
        entries.values.filter { $0.kind == kind }
            .sorted { $0.importance > $1.importance }
    }

    public func entry(id: String) -> ContextEntry? {
        entries[id]
    }

    public func allEntries() -> [ContextEntry] {
        entries.values.sorted { $0.importance > $1.importance }
    }

    // MARK: - SymbolicView

    /// Returns an LLM-safe dictionary view of the most important entries, capped at `budget` entries.
    ///
    /// Keys are entry IDs; values are dictionaries of kind, subject, and payload fields.
    public func symbolicView(budget: Int = 20) -> [[String: String]] {
        let ranked = entries.values.sorted { $0.importance > $1.importance }.prefix(budget)
        return ranked.map { entry in
            var d: [String: String] = [
                "id": entry.id,
                "kind": entry.kind.rawValue,
                "subject": entry.subject,
            ]
            for (k, v) in entry.payload { d[k] = v }
            return d
        }
    }

    // MARK: - Persistence

    /// Persists all entries to `storageURL` (if configured).
    public func flush() throws {
        guard let url = storageURL else { return }
        let all = Array(entries.values)
        let data = try JSONEncoder().encode(all)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Private helpers

    private func evictIfNeeded() {
        guard entries.count > capacity else { return }
        let sorted = entries.values.sorted { $0.importance < $1.importance }
        let toRemove = sorted.prefix(entries.count - capacity)
        for entry in toRemove { entries.removeValue(forKey: entry.id) }
    }
}
