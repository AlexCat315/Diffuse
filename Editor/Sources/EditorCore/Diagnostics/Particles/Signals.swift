import Foundation
import RenderBackend
import SceneRuntime

public enum DeveloperParticleDiagnosticSeverity: String, Codable, Sendable, Equatable {
    case idle = "Idle"
    case nominal = "Nominal"
    case info = "Info"
    case warning = "Warning"
    case critical = "Critical"
}

public struct DeveloperParticleDiagnosticSummary: Codable, Sendable, Equatable {
    public let severity: DeveloperParticleDiagnosticSeverity
    public let status: String
    public let primarySignal: String
    public let recommendation: String
    public let details: [String]
}

public struct DeveloperParticleEmitterLabel: Codable, Sendable, Equatable {
    public let entityID: UInt64
    public let name: String
    public let kind: String
    public let path: String
}

public struct DeveloperParticleEmitterHotspot: Codable, Sendable, Equatable {
    public let entityID: UInt64
    public let severity: DeveloperParticleDiagnosticSeverity
    public let reason: String
    public let primarySignal: String
    public let recommendation: String
    public let details: [String]
    public let score: Int
    public let liveParticleCount: Int
    public let requestedSpawnCount: Int
    public let spawnedParticleCount: Int
    public let droppedSpawnCount: Int
    public let capacityLimitedSpawnCount: Int
    public let spawnBudgetLimitedCount: Int
    public let eventDroppedSpawnCount: Int
    public let liveBudgetText: String
    public let spawnBudgetText: String
}
