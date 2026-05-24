import Foundation

// MARK: - FileBackedSemanticMemoryStore

/// Persistent `SemanticMemoryStore` that survives app restarts.
///
/// Entries are stored as a JSON array at `storageURL`. Writes are synchronous and
/// actor-isolated; the file is always current after `record` returns.
///
/// The fingerprint hash key uses the same coarse topology signature as
/// `EphemeralSemanticMemoryStore`. Replace `hashKey(_:)` with a real spectral
/// hash when geometry analysis is upgraded.
public actor FileBackedSemanticMemoryStore: SemanticMemoryStore {
    private let storageURL: URL
    private var index: [String: [SemanticMemoryEntry]] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(storageURL: URL) throws {
        let dir = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true,
                                                attributes: nil)
        self.storageURL = storageURL

        if FileManager.default.fileExists(atPath: storageURL.path) {
            let data = try Data(contentsOf: storageURL)
            let all = try JSONDecoder().decode([SemanticMemoryEntry].self, from: data)
            for entry in all {
                index[entry.fingerprintHash, default: []].append(entry)
            }
        }
    }

    // MARK: - SemanticMemoryStore

    public func lookup(fingerprint: GeometryFingerprint) async -> [SemanticMemoryEntry] {
        index[hashKey(fingerprint)] ?? []
    }

    public func record(regionID: String,
                       fingerprint: GeometryFingerprint,
                       confirmation: SemanticConfirmation) async {
        guard case let .accepted(label) = confirmation.outcome else { return }
        let key = hashKey(fingerprint)
        let entry = SemanticMemoryEntry(
            fingerprintHash: key,
            assetURI: confirmation.regionID,
            regionAlias: regionID,
            label: label,
            scope: .asset,
            source: .confirmed,
            confidence: 1.0,
            updatedAt: confirmation.confirmedAt
        )
        index[key, default: []].append(entry)
        try? persist()
    }

    // MARK: - Explicit write

    /// Adds a raw entry directly (e.g. for bulk import from legacy stores).
    public func insert(_ entry: SemanticMemoryEntry) {
        index[entry.fingerprintHash, default: []].append(entry)
        try? persist()
    }

    // MARK: - Private

    private func persist() throws {
        let all = index.values.flatMap { $0 }
        let data = try encoder.encode(all)
        try data.write(to: storageURL, options: .atomic)
    }

    private func hashKey(_ fp: GeometryFingerprint) -> String {
        "\(fp.genus):\(fp.boundaryLoops):\(fp.faceCountBucket):\(fp.version)"
    }
}
