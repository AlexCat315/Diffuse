public enum ScriptToolchainActivity: Sendable, Equatable {
    case idle
    case selecting
    case installation(SwiftToolchainInstallProgress)
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .selecting, .installation(.downloading), .installation(.verifying), .installation(.installing): true
        default: false
        }
    }
}
