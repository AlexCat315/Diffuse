public import Foundation

public struct PluginProcessContext: Codable, Sendable, Equatable {
    public var workspace: URL
    public var executables: [String: URL] = [:]
    public init(workspace: URL) { self.workspace = workspace }
}

public struct PluginProcessRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case start, poll, write, closeInput, stop }
    public var operation: Operation
    public var permission: String?
    public var arguments: [String] = []
    public var environment: [String: String] = [:]
    public var handle: UUID?
    public var input: Data?
    public init(_ operation: Operation) { self.operation = operation }
}

public struct PluginProcessUpdate: Codable, Sendable {
    public var handle: UUID
    public var stdout: Data = Data()
    public var stderr: Data = Data()
    public var exitStatus: Int32?
    public var failure: String?
    public init(handle: UUID) { self.handle = handle }
}

public enum PluginProcessError: Error, Sendable, Equatable {
    case notAuthorized
    case commandNotBound(String)
    case argumentsDenied
    case environmentDenied
    case invalidHandle
    case processLimit
    case invalidRequest
}
