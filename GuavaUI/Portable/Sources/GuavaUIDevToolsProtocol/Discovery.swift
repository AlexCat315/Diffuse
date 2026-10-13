import Foundation

/// Transient launch data shared by the CLI and application diagnostics adapters.
public struct DevToolsLaunch: Codable, Sendable, Equatable {
    public let id: String
    public let token: String
    public let descriptorPath: String
    public let appTitle: String
    public init(id: String, token: String, descriptorPath: String, appTitle: String) {
        self.id = id; self.token = token; self.descriptorPath = descriptorPath; self.appTitle = appTitle
    }
}

/// Runtime-owned discovery record. Never part of authored application configuration.
public struct DevToolsDiscovery: Codable, Sendable, Equatable {
    public let id: String
    public let pid: Int
    public let endpoint: String
    public init(id: String, pid: Int, endpoint: String) {
        self.id = id; self.pid = pid; self.endpoint = endpoint
    }
}
