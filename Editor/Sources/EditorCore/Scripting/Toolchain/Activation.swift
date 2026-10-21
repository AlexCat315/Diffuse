struct ScriptToolchainActivation: Sendable {
    let suspend: @MainActor @Sendable () async -> Void
    let activate: @MainActor @Sendable () async throws -> Void
    let recover: @MainActor @Sendable () async throws -> Void
}

struct ScriptToolchainLanguageIntent {
    var suspended: Bool
    var didSuspend = false
}
