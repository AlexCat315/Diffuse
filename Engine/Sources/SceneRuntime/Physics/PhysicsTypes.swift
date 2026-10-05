import Foundation
import SIMDCompat

public enum PhysicsSimulationMode: String, CaseIterable, Sendable, Equatable {
    case off
    case preview
    case play
    case bake
}

public enum PhysicsBackendKind: String, Sendable, Equatable {
    case none
    case jolt
}

public enum PhysicsBackendErrorCode: String, Sendable, Equatable {
    case abiMismatch
    case invalidArgument
    case invalidShape
    case bodyCreationFailed
    case updateFailed
    case unknown
}

public struct PhysicsBackendError: Error, Sendable, Equatable {
    public var code: PhysicsBackendErrorCode
    public var message: String

    public init(code: PhysicsBackendErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}
