import Foundation

public struct SemanticMemoryEntry: Sendable {
    public var fingerprintHash: String
    public var assetURI: String
    public var regionAlias: String
    public var label: String
    public var scope: MemoryScope
    public var source: MemorySource
    public var confidence: Float
    public var updatedAt: Date

    public enum MemoryScope: String, Sendable, Codable {
        case asset
        case family
        case global
    }

    public enum MemorySource: String, Sendable, Codable {
        case confirmed
        case inferred
    }

    public init(fingerprintHash: String,
                assetURI: String,
                regionAlias: String,
                label: String,
                scope: MemoryScope,
                source: MemorySource,
                confidence: Float,
                updatedAt: Date = Date()) {
        self.fingerprintHash = fingerprintHash
        self.assetURI = assetURI
        self.regionAlias = regionAlias
        self.label = label
        self.scope = scope
        self.source = source
        self.confidence = confidence
        self.updatedAt = updatedAt
    }
}

/// Cross-session store that lets confirmed region labels survive asset re-imports.
/// Addressed by geometry fingerprint so topology-stable re-imports hit the cache automatically.
public protocol SemanticMemoryStore: Sendable {
    func lookup(fingerprint: GeometryFingerprint) async -> [SemanticMemoryEntry]
    func record(regionID: String,
                fingerprint: GeometryFingerprint,
                confirmation: SemanticConfirmation) async
}

/// In-memory implementation for tests and offline use.
public final class EphemeralSemanticMemoryStore: SemanticMemoryStore, @unchecked Sendable {
    private var entries: [String: [SemanticMemoryEntry]] = [:]
    private let lock = NSLock()

    public init() {}

    public func lookup(fingerprint: GeometryFingerprint) async -> [SemanticMemoryEntry] {
        let key = hashKey(fingerprint)
        return lock.withLock { entries[key] ?? [] }
    }

    public func record(regionID: String,
                       fingerprint: GeometryFingerprint,
                       confirmation: SemanticConfirmation) async {
        guard case let .accepted(label) = confirmation.outcome else { return }
        let key = hashKey(fingerprint)
        let entry = SemanticMemoryEntry(
            fingerprintHash: key,
            assetURI: "",
            regionAlias: regionID,
            label: label,
            scope: .asset,
            source: .confirmed,
            confidence: 1.0,
            updatedAt: confirmation.confirmedAt
        )
        lock.withLock { entries[key, default: []].append(entry) }
    }

    private func hashKey(_ fp: GeometryFingerprint) -> String {
        // Minimal stable key from topology signature; replaced by real hash when geometry is computed.
        "\(fp.genus):\(fp.boundaryLoops):\(fp.faceCountBucket):\(fp.version)"
    }
}
