import Foundation

/// Transient health and retry policy, independent of authored document roots.
struct ScriptLanguageLifecycle {
    var generation = UUID()
    var connectionID: UUID?
    var state: ScriptLanguageServiceState = .inactive
    var onStateChange: ScriptLanguageSupport.StateHandler?
    var recoveryAttempt = 0
    var recoveryTask: Task<Void, Never>?
    var readySince: ContinuousClock.Instant?
}

/// Revision orders UI deliveries across stop, restart and recovery callbacks.
public struct ScriptLanguageServiceUpdate: Sendable, Equatable {
    public let revision: UInt64
    public let state: ScriptLanguageServiceState

    public init(revision: UInt64, state: ScriptLanguageServiceState) {
        self.revision = revision
        self.state = state
    }
}
