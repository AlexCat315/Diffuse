import Foundation

public enum ManifestScanner {
    public struct ScanResult: Sendable {
        public var manifests: [PerceptionModelManifest]
        public var errors: [(url: URL, error: String)]

        public init(manifests: [PerceptionModelManifest], errors: [(url: URL, error: String)]) {
            self.manifests = manifests
            self.errors = errors
        }
    }

    /// Scans `directory` recursively for files named `manifest.json` or ending in
    /// `.perception.json`. Each file is parsed as a `PerceptionModelManifest`; files
    /// that fail schema validation or JSON decoding are collected in `errors`.
    public static func scan(directory: URL) -> ScanResult {
        var manifests: [PerceptionModelManifest] = []
        var errors: [(url: URL, error: String)] = []

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ScanResult(manifests: [], errors: [])
        }

        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            guard name == "manifest.json" || name.hasSuffix(".perception.json") else {
                continue
            }
            do {
                let data = try Data(contentsOf: fileURL)
                let manifest = try JSONDecoder().decode(PerceptionModelManifest.self, from: data)
                try PerceptionSchemaValidator.validate(manifest)
                manifests.append(manifest)
            } catch {
                errors.append((url: fileURL, error: error.localizedDescription))
            }
        }

        return ScanResult(manifests: manifests, errors: errors)
    }
}
