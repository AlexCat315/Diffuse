public import Foundation

/// A resolved command. Executable lookup and authority belong to the caller's
/// policy boundary; the runner never invokes a shell or searches PATH.
public struct ProcessCommand: Sendable, Equatable, Codable {
    public var executable: URL
    public var arguments: [String] = []
    public var directory: URL
    public var environment: [String: String] = [:]

    public init(executable: URL, directory: URL) {
        self.executable = executable
        self.directory = directory
    }
}

public struct ProcessBudget: Sendable, Equatable, Codable {
    public var outputBytes = 1_048_576
    public var pendingInputBytes = 4_194_304
    public var lifetimeMilliseconds: Int? = 30_000
    public init() {}
}

public enum ProcessEvent: Sendable {
    case stdout(Data)
    case stderr(Data)
    case exited(Int32)
    case stdoutClosed
    case stderrClosed
}

public enum ProcessRuntimeError: Error, Sendable, Equatable {
    case unavailable
    case invalidCommand
    case invalidBudget
    case outputLimit
    case inputLimit
    case timedOut
    case stopped
}

public struct ProcessOutput: Sendable {
    public var stdout = Data()
    public var stderr = Data()
    public var status: Int32 = 0
    public init() {}
}
