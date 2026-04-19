import MouseEngineCore

public struct RPCRequest: Sendable {
    public let method: String
    public let params: [String: String]

    public init(method: String, params: [String: String] = [:]) {
        self.method = method
        self.params = params
    }
}

public struct RPCResponse: Sendable {
    public let ok: Bool
    public let message: String

    public init(ok: Bool, message: String) {
        self.ok = ok
        self.message = message
    }
}

public final class RPCBridge {
    private let app: Application

    public init(app: Application) {
        self.app = app
    }

    public func handle(_ request: RPCRequest) -> RPCResponse {
        switch request.method {
        case "engine.start":
            app.start()
            return RPCResponse(ok: true, message: "started")
        case "engine.stop":
            app.stop()
            return RPCResponse(ok: true, message: "stopped")
        default:
            return RPCResponse(ok: false, message: "method not found")
        }
    }
}
