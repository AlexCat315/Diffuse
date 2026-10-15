import AIRuntime

/// Tool enforcement and exposure state share the same host policy for the
/// entire Editor lifetime, including replacement assistant sessions.
struct EditorToolAccess {
    let policy: ToolPolicy
    let capabilitySessions: CapabilityExposureSessionStore

    init(policy: ToolPolicy) {
        self.policy = policy
        capabilitySessions = CapabilityExposureSessionStore(toolPolicy: policy)
    }
}
