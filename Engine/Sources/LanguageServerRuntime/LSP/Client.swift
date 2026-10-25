import Foundation
import GuavaLogging
internal import GuavaProcess

/// Owns one `sourcekit-lsp` child process and speaks JSON-RPC over its pipes.
///
/// Responsibilities are deliberately narrow: process lifecycle, request/response
/// correlation, and turning server requests we do not implement into a clean
/// error reply. What the messages *mean* lives in
/// ``ScriptLanguageRequest``/``ScriptLanguageResponse``.
public actor LSPClient {
    public typealias NotificationHandler = @Sendable (LSPNotification) -> Void
    public typealias FailureHandler = @Sendable (LSPFailure) -> Void

    private static let shutdownTimeout: Duration = .seconds(2)
    /// Tail of stderr retained so it can be attached to a mid-flight failure.
    private static let stderrTailCapacity = 8_192

    private let configuration: LanguageServerConfiguration

    private var connection: LSPConnection?
    private var decoder = LSPMessageFramer.Decoder()
    private var pending: [Int: CheckedContinuation<Data?, Error>] = [:]
    private var nextRequestID = 1
    private var notificationHandler: NotificationHandler?
    private var stderrTail = Data()
    private var failureHandler: FailureHandler?
    private var isShuttingDown = false
    public init(configuration: LanguageServerConfiguration) { self.configuration = configuration }

    deinit {
        connection?.close()
    }

    // MARK: - Lifecycle

    public func start(notificationHandler: NotificationHandler? = nil,
                      onFailure: FailureHandler? = nil) throws {
        guard connection?.isRunning != true else { return }
        stop()
        let connection: LSPConnection
        do { connection = try LSPConnection(configuration: configuration) }
        catch { throw LSPClientError.launchFailed(String(describing: error)) }
        self.connection = connection
        decoder = LSPMessageFramer.Decoder()
        stderrTail = Data()
        self.notificationHandler = notificationHandler
        failureHandler = onFailure
        isShuttingDown = false
        let id = connection.id
        let events = connection.events
        connection.consumer = Task { [weak self] in
            do {
                for try await event in events {
                    guard !Task.isCancelled else { return }
                    await self?.receive(event, connectionID: id)
                }
            } catch { await self?.transportFailed(error, connectionID: id) }
        }
    }

    public func initialize() async throws {
        guard connection?.isRunning == true else { throw LSPClientError.notRunning }
        _ = try await request("initialize",
                              params: try LSPJSON.data(initializeParams()))
        try notify("initialized", params: try LSPJSON.data([String: String]()))
    }

    // MARK: - Messaging

    public func request(_ method: String,
                        params: Data? = nil,
                        timeout: Duration = .seconds(30)) async throws -> Data? {
        guard connection?.isRunning == true else { throw LSPClientError.notRunning }
        let requestID = nextRequestID
        nextRequestID += 1
        let body = try Self.requestBody(id: requestID, method: method, params: params)

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            do {
                try write(body)
            } catch {
                pending.removeValue(forKey: requestID)?.resume(throwing: error)
                failConnection(.connectionClosed)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expireRequest(requestID, method: method)
            }
        }
    }

    public func notify(_ method: String, params: Data? = nil) throws {
        guard connection?.isRunning == true else { throw LSPClientError.notRunning }
        let body = try Self.notificationBody(method: method, params: params)
        do { try write(body) } catch {
            failConnection(.connectionClosed)
            throw error
        }
    }

    /// Intentional shutdown never reports a transport failure to the owner.
    public func stop() {
        let old = connection
        connection = nil // Queued events from this connection are now stale.
        old?.close()
        notificationHandler = nil
        failureHandler = nil
        failPending(LSPClientError.notRunning)
    }

    public func shutdown() async {
        isShuttingDown = true
        if connection?.isRunning == true {
            _ = try? await request("shutdown", timeout: Self.shutdownTimeout)
            try? notify("exit")
        }
        stop()
    }

    public var isRunning: Bool { connection?.isRunning == true }

    // MARK: - Client capabilities

    private var workspaceFolders: [[String: String]] {
        ([configuration.workspace] + configuration.additionalWorkspaces).map {
            ["uri": $0.standardizedFileURL.absoluteString, "name": $0.lastPathComponent]
        }
    }

    private func initializeParams() throws -> [String: Any] {
        let rootURI = configuration.workspace.standardizedFileURL.absoluteString
        var params: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "clientInfo": ["name": "GuavaStudioEditor", "version": "0.0.9"],
            "rootUri": rootURI,
            "workspaceFolders": workspaceFolders,
            "capabilities": Self.clientCapabilities,
            "trace": "off",
        ]
        if let options = configuration.initializationOptions {
            params["initializationOptions"] = try JSONSerialization.jsonObject(with: options, options: [.fragmentsAllowed])
        }
        return params
    }

    private static var clientCapabilities: [String: Any] {
        [
            "workspace": [
                "applyEdit": false,
                "workspaceEdit": ["documentChanges": true, "resourceOperations": [String](), "failureHandling": "abort"],
                "workspaceFolders": true,
                "configuration": true,
                "symbol": ["dynamicRegistration": false],
                "didChangeWatchedFiles": ["dynamicRegistration": false],
            ],
            "textDocument": [
                "synchronization": ["dynamicRegistration": false, "willSave": false, "didSave": true],
                "completion": [
                    "completionItem": [
                        "snippetSupport": true,
                        "documentationFormat": ["markdown", "plaintext"],
                        "resolveSupport": ["properties": ["documentation", "detail"]],
                    ],
                ],
                "hover": ["contentFormat": ["markdown", "plaintext"]],
                "definition": ["dynamicRegistration": false],
                "references": ["dynamicRegistration": false],
                "rename": ["dynamicRegistration": false, "prepareSupport": true],
                "codeAction": ["dynamicRegistration": false, "dataSupport": true,
                               "disabledSupport": true, "isPreferredSupport": true,
                               "resolveSupport": ["properties": ["edit"]],
                               "codeActionLiteralSupport": ["codeActionKind": ["valueSet": ["quickfix", "refactor", "source"]]]],
                "signatureHelp": ["signatureInformation": ["documentationFormat": ["markdown", "plaintext"],
                                                            "parameterInformation": ["labelOffsetSupport": true],
                                                            "activeParameterSupport": true]],
                "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
                "formatting": ["dynamicRegistration": false],
                "rangeFormatting": ["dynamicRegistration": false],
                "documentHighlight": ["dynamicRegistration": false],
                "publishDiagnostics": ["relatedInformation": true],
            ],
            "window": ["workDoneProgress": true],
        ]
    }

    // MARK: - Encoding

    private static func requestBody(id: Int, method: String, params: Data?) throws -> Data {
        var body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { body["params"] = try JSONSerialization.jsonObject(with: params, options: [.fragmentsAllowed]) }
        return try LSPJSON.data(body)
    }

    private static func notificationBody(method: String, params: Data?) throws -> Data {
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { body["params"] = try JSONSerialization.jsonObject(with: params, options: [.fragmentsAllowed]) }
        return try LSPJSON.data(body)
    }

    private func write(_ body: Data) throws {
        guard let connection else { throw LSPClientError.notRunning }
        try connection.transport.write(LSPMessageFramer.frame(body))
    }

    // MARK: - Decoding

    private func consume(_ data: Data) {
        do {
            for body in try decoder.append(data) {
                try consumeMessage(body)
            }
        } catch {
            failConnection(error as? LSPClientError ?? .protocolViolation(error.localizedDescription))
        }
    }

    private func consumeMessage(_ body: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw LSPClientError.protocolViolation("message body is not an object")
        }

        if let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let errorObject = object["error"] as? [String: Any] {
                let code = errorObject["code"] as? Int ?? -32000
                let message = errorObject["message"] as? String ?? "Unknown server error"
                continuation.resume(throwing: LSPClientError.serverError(code: code, message: message))
            } else if let result = object["result"] {
                continuation.resume(returning: try LSPJSON.data(result))
            } else {
                continuation.resume(returning: Data("null".utf8))
            }
            return
        }

        guard let method = object["method"] as? String else { return }
        if let requestID = object["id"] {
            try respondToServerRequest(id: requestID, method: method, params: object["params"])
            return
        }
        let params = try LSPJSON.object(object["params"])
        notificationHandler?(LSPNotification(method: method, params: params))
    }

    /// Answers the handful of server-initiated requests SourceKit-LSP issues
    /// during startup. Everything else is rejected with `-32601` so the server
    /// stops waiting for a reply instead of blocking the RPC channel.
    private func respondToServerRequest(id: Any, method: String, params: Any?) throws {
        let result: Any
        switch method {
        case "workspace/configuration":
            let items = (params as? [String: Any])?["items"] as? [[String: Any]] ?? []
            let settings = configuration.settings.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            result = items.map { item -> Any in
                guard let section = item["section"] as? String else { return settings ?? NSNull() }
                var value: Any? = settings
                for key in section.split(separator: ".") { value = (value as? [String: Any])?[String(key)] }
                return value ?? NSNull()
            }
        case "workspace/workspaceFolders":
            result = workspaceFolders
        case "client/registerCapability", "client/unregisterCapability",
             "window/workDoneProgress/create", "workspace/semanticTokens/refresh",
             "workspace/inlayHint/refresh", "workspace/diagnostic/refresh",
             "window/showMessageRequest":
            result = NSNull()
        default:
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32601, "message": "Method not supported by GuavaStudioEditor"],
            ]
            try write(try LSPJSON.data(response))
            return
        }
        try write(try LSPJSON.data(["jsonrpc": "2.0", "id": id, "result": result]))
    }

    // MARK: - Failure paths

    private func expireRequest(_ id: Int, method: String) {
        pending.removeValue(forKey: id)?.resume(throwing: LSPClientError.requestTimedOut(method))
    }

    private func receive(_ event: ProcessEvent, connectionID: UUID) {
        guard connection?.id == connectionID else { return }
        switch event {
        case let .stdout(data): consume(data)
        case let .stderr(data): consumeStderr(data)
        case let .exited(status): failConnection(.processTerminated(status))
        case .stdoutClosed:
            failConnection(.connectionClosed)
        case .stderrClosed: break
        }
    }

    private func transportFailed(_ error: Error, connectionID: UUID) {
        guard connection?.id == connectionID else { return }
        failConnection(.protocolViolation(String(describing: error)))
    }

    private func failConnection(_ error: LSPClientError) {
        guard let old = connection else { return }
        let failure = LSPFailure(error: error, stderr: String(decoding: stderrTail, as: UTF8.self))
        let handler = isShuttingDown ? nil : failureHandler
        connection = nil
        old.close()
        failureHandler = nil
        notificationHandler = nil
        failPending(error)
        handler?(failure)
    }

    private func consumeStderr(_ data: Data) {
        if let params = try? LSPJSON.data(["message": String(decoding: data, as: UTF8.self), "type": 4] as [String: Any]) {
            notificationHandler?(LSPNotification(method: "guava/stderr", params: params))
        }
        LogSystem.logger("com.guava.editor.lsp").debug("\(String(decoding: data, as: UTF8.self))", source: "sourcekit.stderr")
        stderrTail.append(data)
        if stderrTail.count > Self.stderrTailCapacity {
            stderrTail.removeSubrange(..<(stderrTail.count - Self.stderrTailCapacity))
        }
    }

    private func failPending(_ error: Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }
}
