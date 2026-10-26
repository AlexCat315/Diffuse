public enum PhysicsBackendKind: String, CaseIterable, Sendable, Equatable {
    case none
    case natsel

    /// The backend selected when settings do not choose one.
    public static let preferred: PhysicsBackendKind = .natsel

    func makeBackend() -> any PhysicsBackend {
        switch self {
        case .none:
            return NullPhysicsBackend()
        case .natsel:
            return NatselPhysicsBackend()
        }
    }
}
