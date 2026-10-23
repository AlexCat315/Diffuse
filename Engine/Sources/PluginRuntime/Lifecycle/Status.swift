import Foundation

public enum PluginPhase: String, Codable, Sendable {
    case installed, enabled, activated, failed
}

public struct PluginStatus: Sendable {
    public let inspection: PluginInspection
    public let phase: PluginPhase
    public let isEnabled: Bool
    public let failure: String?
}

public enum PluginManagerError: Error, Sendable, Equatable, CustomStringConvertible {
    case alreadyEnabled(String)
    case notInstalled(String)
    case notEnabled(String)
    case runtimeUnavailable
    case stopped
    case activationCycle(String)

    public var description: String {
        switch self {
        case let .alreadyEnabled(id): "Plugin '\(id)' is already enabled."
        case let .notInstalled(id): "Plugin '\(id)' is not installed."
        case let .notEnabled(id): "Plugin '\(id)' is not enabled."
        case .runtimeUnavailable: "The plugin runtime is unavailable."
        case .stopped: "The plugin manager has stopped."
        case let .activationCycle(id): "Plugin activation cycle at '\(id)'."
        }
    }
}

public struct PluginRuntimeActivation: Sendable {
    let binding: PluginExecutionBinding
    let registration: Registration?

    public init(binding: PluginExecutionBinding, registration: Registration? = nil) {
        self.binding = binding; self.registration = registration
    }
}

public struct PluginRuntimeDriver: Sendable {
    let activate: @Sendable (URL, PluginAuthorizationRecord) async throws -> PluginRuntimeActivation
    let deactivate: @Sendable (PluginExecutionBinding) async throws -> Void
    let stop: @Sendable () -> Void

    public init(
        activate: @escaping @Sendable (URL, PluginAuthorizationRecord) async throws -> PluginRuntimeActivation,
        deactivate: @escaping @Sendable (PluginExecutionBinding) async throws -> Void,
        stop: @escaping @Sendable () -> Void
    ) {
        self.activate = activate
        self.deactivate = deactivate
        self.stop = stop
    }
}

