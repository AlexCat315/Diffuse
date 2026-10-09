import Foundation

/// Creates `PerceptionWorker` instances from manifests by matching `manifest.backendFamily`
/// against registered builder closures. Callers register one builder per backend family;
/// the factory remains backend-agnostic and doesn't import any ML framework directly.
public struct PerceptionWorkerFactory: Sendable {
    public typealias Builder = @Sendable (PerceptionModelManifest) -> (any PerceptionWorker)?

    private var builders: [String: Builder]

    public init() {
        builders = [:]
    }

    public mutating func register(backendFamily: String, builder: @escaping Builder) {
        builders[backendFamily] = builder
    }

    /// Returns a worker for `manifest.backendFamily`, or `nil` if no builder is registered
    /// for that family. Callers should check `LicenseGate` separately before using the worker.
    public func makeWorker(for manifest: PerceptionModelManifest) -> (any PerceptionWorker)? {
        builders[manifest.backendFamily]?(manifest)
    }
}

// MARK: - PerceptionService + discovery

extension PerceptionService {
    /// Scans `directory` for manifest files, runs each through `factory` and `licenseGate`,
    /// and registers the resulting workers. Returns the scan result so callers can surface errors.
    @discardableResult
    public func discoverAndRegister(from directory: URL,
                                    factory: PerceptionWorkerFactory) -> ManifestScanner.ScanResult {
        let scan = ManifestScanner.scan(directory: directory)
        for manifest in scan.manifests {
            guard let worker = factory.makeWorker(for: manifest) else { continue }
            register(worker)
        }
        return scan
    }
}
