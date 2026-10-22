public enum PhysicsBackendKind: String, CaseIterable, Sendable, Equatable {
    case none
    case jolt

    /// The backend selected when settings do not choose one.
    public static let preferred: PhysicsBackendKind = .jolt

    func makeBackend() -> any PhysicsBackend {
        switch self {
        case .none:
            return NullPhysicsBackend()
        case .jolt:
            return JoltPhysicsBackend()
        }
    }
}
