public enum PhysicsBackendKind: String, CaseIterable, Sendable, Equatable {
    case none
    case jolt
#if os(macOS) || os(iOS) || os(Linux)
    case natsel
#endif

    /// The backend selected when settings do not choose one.
    public static let preferred: PhysicsBackendKind = {
        #if os(macOS) || os(iOS) || os(Linux)
        .natsel
        #else
        .jolt
        #endif
    }()

    func makeBackend() -> any PhysicsBackend {
        switch self {
        case .none:
            return NullPhysicsBackend()
        case .jolt:
            return JoltPhysicsBackend()
        #if os(macOS) || os(iOS) || os(Linux)
        case .natsel:
            return NatselPhysicsBackend()
        #endif
        }
    }
}
