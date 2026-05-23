import Foundation

public enum PerceptionRuntimeError: Error, CustomStringConvertible, LocalizedError {
    case fileNotFound(String)
    case workerUnavailable(String)
    case inferenceFailed(String)
    case noObservations
    case licenseDenied(LicenseGateDecision)

    public var description: String {
        switch self {
        case let .fileNotFound(path):
            return "Perception input file not found: \(path)"
        case let .workerUnavailable(reason):
            return "Perception worker unavailable: \(reason)"
        case let .inferenceFailed(reason):
            return "Perception inference failed: \(reason)"
        case .noObservations:
            return "Perception inference produced no observations"
        case let .licenseDenied(decision):
            return "Perception model denied by license gate: \(decision)"
        }
    }

    public var errorDescription: String? { description }
}

public protocol PerceptionWorker: Sendable {
    var manifest: PerceptionModelManifest { get }
    func analyzeImage(at url: URL, requestID: String, maxResults: Int) throws -> PerceptionResult
}

public extension PerceptionWorker {
    func analyzeImage(at url: URL) throws -> PerceptionResult {
        try analyzeImage(at: url, requestID: UUID().uuidString, maxResults: 5)
    }

    func analyzeImage(at url: URL, maxResults: Int) throws -> PerceptionResult {
        try analyzeImage(at: url, requestID: UUID().uuidString, maxResults: maxResults)
    }
}
