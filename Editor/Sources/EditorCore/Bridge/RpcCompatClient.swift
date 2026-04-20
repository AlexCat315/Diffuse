import Foundation

public struct RpcResponse: Sendable {
    public var payload: [String: String]

    public init(payload: [String: String]) {
        self.payload = payload
    }
}

public protocol RpcCompatClient: Sendable {
    func call(method: String, params: [String: String]) async throws -> RpcResponse
}

public enum RpcCompatError: Error {
    case notImplemented
}

public struct StubRpcCompatClient: RpcCompatClient {
    public init() {}

    public func call(method: String, params: [String: String]) async throws -> RpcResponse {
        _ = params
        switch method {
        case "editor.ping":
            return RpcResponse(payload: ["ok": "true"])
        case "editor.getCapabilities":
            return RpcResponse(payload: ["version": "stub-v1"])
        default:
            throw RpcCompatError.notImplemented
        }
    }
}
