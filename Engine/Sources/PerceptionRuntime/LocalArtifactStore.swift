import Foundation

/// Content-addressed store for large binary artifacts (embeddings, masks, depth maps).
/// Artifacts are indexed by SHA-256 of content so identical data is never stored twice.
/// All file I/O is async and actor-isolated; the `artifacts://` URI scheme is resolved
/// back to a file path via `resolve(_:)`.
public actor LocalArtifactStore {
    public let baseURL: URL

    private var index: [String: URL] = [:]

    public init(baseURL: URL) throws {
        self.baseURL = baseURL
        try FileManager.default.createDirectory(at: baseURL,
                                                withIntermediateDirectories: true,
                                                attributes: nil)
    }

    // MARK: - Writing

    /// Writes `data` into the store and returns an `ArtifactRef` whose URI is
    /// `artifacts://<sha256>`. Idempotent: if the same content was written before,
    /// the existing file is reused and a fresh `ArtifactRef` is returned.
    public func write(_ data: Data,
                      mediaType: String,
                      semanticKind: String,
                      redaction: String = "prompt_forbidden") throws -> ArtifactRef {
        let hash = SHA256Portable.hexDigest(data)
        let ext = fileExtension(for: mediaType)
        let fileURL = baseURL.appendingPathComponent("\(hash).\(ext)")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL, options: .atomic)
        }
        index[hash] = fileURL
        return ArtifactRef(uri: "artifacts://\(hash)",
                           contentHash: hash,
                           mediaType: mediaType,
                           semanticKind: semanticKind,
                           redaction: redaction)
    }

    // MARK: - Reading

    /// Resolves an `artifacts://` URI to the local file URL, or returns `nil` if
    /// the artifact is not present in this store.
    public func resolve(_ ref: ArtifactRef) -> URL? {
        guard ref.uri.hasPrefix("artifacts://") else { return nil }
        let hash = String(ref.uri.dropFirst("artifacts://".count))
        if let cached = index[hash] {
            return FileManager.default.fileExists(atPath: cached.path) ? cached : nil
        }
        let ext = fileExtension(for: ref.mediaType)
        let candidate = baseURL.appendingPathComponent("\(hash).\(ext)")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    public func read(_ ref: ArtifactRef) throws -> Data {
        guard let url = resolve(ref) else {
            throw ArtifactStoreError.notFound(ref.uri)
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Helpers

    private func fileExtension(for mediaType: String) -> String {
        switch mediaType {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "application/json": return "json"
        default: return "bin"
        }
    }
}

public struct ArtifactStoreError: Error, CustomStringConvertible, Sendable {
    public var uri: String

    public init(notFound uri: String) { self.uri = uri }

    public var description: String { "Artifact not found in local store: \(uri)" }

    public static func notFound(_ uri: String) -> ArtifactStoreError {
        ArtifactStoreError(notFound: uri)
    }
}
