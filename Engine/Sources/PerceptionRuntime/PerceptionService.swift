import Foundation
import IntentRuntime

/// High-level orchestrator that registers PerceptionWorkers, selects the right one for a
/// given task, runs inference off the calling thread, and maps the result to WorldEvents
/// ready to inject into AIWorldContext.
public actor PerceptionService {
    private var workers: [any PerceptionWorker] = []
    private let licenseGate: LicenseGate
    private let distributionMode: PerceptionDistributionMode
    private let mapper: PerceptionWorldEventMapper

    public init(licenseGate: LicenseGate = LicenseGate(),
                distributionMode: PerceptionDistributionMode = .localDev,
                mapper: PerceptionWorldEventMapper = PerceptionWorldEventMapper()) {
        self.licenseGate = licenseGate
        self.distributionMode = distributionMode
        self.mapper = mapper
    }

    // MARK: - Registration

    public func register(_ worker: some PerceptionWorker) {
        workers.append(worker)
    }

    // MARK: - Query

    /// Returns the first registered worker for `task` that passes the license gate.
    public func availableWorker(for task: PerceptionTask) -> (any PerceptionWorker)? {
        workers.first { w in
            guard w.manifest.task == task else { return false }
            let decision = licenseGate.evaluate(w.manifest, distributionMode: distributionMode)
            return decision == .allowed || decision == .allowedWithAttribution
        }
    }

    // MARK: - Perception → WorldEvents

    /// Runs perception on `imageURL` and returns `[WorldEvent]` to inject into AIWorldContext.
    ///
    /// - Parameters:
    ///   - entityRef: The entity reference (e.g. "scene:42") that owns the image.
    ///   - imageURL: Local file URL of the image to analyse.
    ///   - task: Which perception task to run. Defaults to `.classification`.
    ///   - maxResults: Maximum number of observations to request. Defaults to 5.
    /// - Returns: WorldEvents encoding inferred properties on `entityRef`.
    /// - Throws: `PerceptionRuntimeError.workerUnavailable` if no suitable worker is registered.
    public func tag(entityRef: String,
                    imageURL: URL,
                    task: PerceptionTask = .classification,
                    maxResults: Int = 5) async throws -> [WorldEvent] {
        guard let worker = availableWorker(for: task) else {
            throw PerceptionRuntimeError.workerUnavailable(
                "no registered worker for task '\(task.rawValue)'")
        }
        let result = try await worker.analyzeImageAsync(at: imageURL, maxResults: maxResults)
        return mapper.makeWorldEvents(from: result, targetRef: entityRef)
    }
}
