import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

enum DeveloperParticleDiagnosticSeverity: String, Equatable {
    case idle = "Idle"
    case nominal = "Nominal"
    case info = "Info"
    case warning = "Warning"
    case critical = "Critical"
}

struct DeveloperParticleDiagnosticSummary: Equatable {
    var severity: DeveloperParticleDiagnosticSeverity
    var status: String
    var primarySignal: String
    var recommendation: String
    var details: [String]
}

struct DeveloperParticleEmitterLabel: Equatable {
    var entityID: UInt64
    var name: String
    var kind: String
    var path: String
}

struct DeveloperParticleEmitterHotspot: Equatable {
    var entityID: UInt64
    var severity: DeveloperParticleDiagnosticSeverity
    var reason: String
    var primarySignal: String
    var recommendation: String
    var details: [String]
    var score: Int
    var liveParticleCount: Int
    var requestedSpawnCount: Int
    var spawnedParticleCount: Int
    var droppedSpawnCount: Int
    var capacityLimitedSpawnCount: Int
    var spawnBudgetLimitedCount: Int
    var eventDroppedSpawnCount: Int
    var liveBudgetText: String
    var spawnBudgetText: String
}
