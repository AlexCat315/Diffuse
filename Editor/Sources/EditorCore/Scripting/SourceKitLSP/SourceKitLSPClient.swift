import Foundation

/// Owns one `sourcekit-lsp` child process and speaks JSON-RPC over its pipes.
///
/// Responsibilities are deliberately narrow: process lifecycle, request/response
/// correlation, and turning server requests we do not implement into a clean
/// error reply. What the messages *mean* lives in
/// ``ScriptLanguageRequest``/``ScriptLanguageResponse``.
public actor SourceKitLSPClient {
    public typealias NotificationHandler = @Sendable (SourceKitLSPNotification) -> Void
    public typealias FailureHandler = @Sendable (SourceKitLSPFailure) -> Void

    private static let shutdownTimeout: Duration = .seconds(2)
    /// Tail of stderr retained so it can be attached to a mid-flight failure.
    private static let stderrTailCapacity = 8_192

    private let executableURL: URL
    private let workspaceURL: URL
    private let scratchURL: URL
    private let environmentOverrides: [String: String]

    private var connection: SourceKitLSPConnection?
    private var decoder = LSPMessageFramer.Decoder()
    private var pending: [Int: CheckedContinuation<Data?, Error>] = [:]
    private var nextRequestID = 1
    private var notificationHandler: NotificationHandler?
    private var stderrTail = Data()
    private var failureHandler: FailureHandler?
    private var isShuttingDown = false
    /// Probed once per client so restarting never re-pays the `--help` call.
    private var capabilities: SourceKitLSPCapabilities?

    public init(executableURL: URL,
                workspaceURL: URL,
                scratchURL: URL,
                environment: [String: String] = [:]) {
        self.executableURL = executableURL
        self.workspaceURL = workspaceURL
        self.scratchURL = scratchURL
        self.environmentOverrides = environment
    }

    deinit {
        connection?.close()
    }

    // MARK: - Lifecycle

    public func start(notificationHandler: NotificationHandler? = nil,
                      onFailure: FailureHandler? = nil) throws {
        guard connection?.process.isRunning != true else { return }
        stop()
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw SourceKitLSPClientError.executableNotFound(executableURL.path)
        }
        try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        let connection = SourceKitLSPConnection()
        let process = connection.process
        process.executableURL = executableURL
        let capabilities = self.capabilities
            ?? SourceKitLSPExecutableLocator.probeCapabilities(executableURL: executableURL)
        self.capabilities = capabilities
        process.arguments = SourceKitLSPCommandLine.arguments(for: workspaceURL,
                                                             scratchURL: scratchURL,
                                                             capabilities: capabilities)
        process.currentDirectoryURL = workspaceURL
        process.environment = ProcessInfo.processInfo.environment.merging(environmentOverrides) { _, new in new }
        connection.installPipes()
        do { try process.run() } catch {
            connection.close()
            throw SourceKitLSPClientError.launchFailed(String(describing: error))
        }
        self.connection = connection
        decoder = LSPMessageFramer.Decoder()
        stderrTail = Data()
        self.notificationHandler = notificationHandler
        failureHandler = onFailure
        isShuttingDown = false
        let id = connection.id
        let events = connection.events
        connection.consumer = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.receive(event, connectionID: id)
            }
        }
    }

    public func initialize() async throws {
        guard connection?.process.isRunning == true else { throw SourceKitLSPClientError.notRunning }
        _ = try await request("initialize",
                              params: try LSPJSON.data(Self.initializeParams(workspaceURL: workspaceURL)))
        try notify("initialized", params: try LSPJSON.data([String: String]()))
    }

    // MARK: - Messaging

    public func request(_ method: String,
                        params: Data? = nil,
                        timeout: Duration = .seconds(30)) async throws -> Data? {
        guard connection?.process.isRunning == true else { throw SourceKitLSPClientError.notRunning }
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
        guard connection?.process.isRunning == true else { throw SourceKitLSPClientError.notRunning }
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
        failPending(SourceKitLSPClientError.notRunning)
    }

    public func shutdown() async {
        isShuttingDown = true
        if connection?.process.isRunning == true {
            _ = try? await request("shutdown", timeout: Self.shutdownTimeout)
            try? notify("exit")
        }
        stop()
    }

    public var isRunning: Bool { connection?.process.isRunning == true }

    // MARK: - Client capabilities

    private static func initializeParams(workspaceURL: URL) -> [String: Any] {
        let rootURI = workspaceURL.standardizedFileURL.absoluteString
        return [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "clientInfo": ["name": "GuavaEditor", "version": "0.0.9"],
            "rootUri": rootURI,
            "workspaceFolders": [["uri": rootURI, "name": workspaceURL.lastPathComponent]],
            "capabilities": Self.clientCapabilities,
            "trace": "off",
        ]
    }

    private static var clientCapabilities: [String: Any] {
        [
            "workspace": [
                "applyEdit": true,
                "workspaceFolders": true,
                "configuration": true,
                "didChangeWatchedFiles": ["dynamicRegistration": false],
            ],
            "textDocument": [
                "synchronization": ["dynamicRegistration": false, "willSave": false, "didSave": true],
                "completion": [
                    "completionItem": [
                        "snippetSupport": false,
                        "documentationFormat": ["markdown", "plaintext"],
                    ],
                ],
                "hover": ["contentFormat": ["markdown", "plaintext"]],
                "definition": ["dynamicRegistration": false],
                "publishDiagnostics": ["relatedInformation": true],
                "semanticTokens": [
                    "requests": ["full": true],
                    "tokenTypes": [],
                    "tokenModifiers": [],
                    "formats": ["relative"],
                ],
            ],
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
        guard let inputHandle = connection?.stdin.fileHandleForWriting else { throw SourceKitLSPClientError.notRunning }
        try inputHandle.write(contentsOf: LSPMessageFramer.frame(body))
    }

    // MARK: - Decoding

    private func consume(_ data: Data) {
        do {
            for body in try decoder.append(data) {
                try consumeMessage(body)
            }
        } catch {
            failConnection(error as? SourceKitLSPClientError ?? .protocolViolation(error.localizedDescription))
        }
    }

    private func consumeMessage(_ body: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw SourceKitLSPClientError.protocolViolation("message body is not an object")
        }

        if let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let errorObject = object["error"] as? [String: Any] {
                let code = errorObject["code"] as? Int ?? -32000
                let message = errorObject["message"] as? String ?? "Unknown server error"
                continuation.resume(throwing: SourceKitLSPClientError.serverError(code: code, message: message))
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
        notificationHandler?(SourceKitLSPNotification(method: method, params: params))
    }

    /// Answers the handful of server-initiated requests SourceKit-LSP issues
    /// during startup. Everything else is rejected with `-32601` so the server
    /// stops waiting for a reply instead of blocking the RPC channel.
    private func respondToServerRequest(id: Any, method: String, params: Any?) throws {
        let result: Any
        switch method {
        case "workspace/configuration":
            let items = (params as? [String: Any])?["items"] as? [Any] ?? []
            result = items.map { _ in NSNull() }
        case "workspace/workspaceFolders":
            result = [["uri": workspaceURL.standardizedFileURL.absoluteString,
                       "name": workspaceURL.lastPathComponent]]
        case "client/registerCapability", "client/unregisterCapability",
             "window/workDoneProgress/create", "workspace/semanticTokens/refresh",
             "workspace/inlayHint/refresh", "workspace/diagnostic/refresh",
             "window/showMessageRequest":
            result = NSNull()
        default:
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32601, "message": "Method not supported by GuavaEditor"],
            ]
            try write(try LSPJSON.data(response))
            return
        }
        try write(try LSPJSON.data(["jsonrpc": "2.0", "id": id, "result": result]))
    }

    // MARK: - Failure paths

    private func expireRequest(_ id: Int, method: String) {
        pending.removeValue(forKey: id)?.resume(throwing: SourceKitLSPClientError.requestTimedOut(method))
    }

    private func receive(_ event: SourceKitLSPConnection.Event, connectionID: UUID) {
        guard connection?.id == connectionID else { return }
        switch event {
        case let .stdout(data): consume(data)
        case let .stderr(data): consumeStderr(data)
        case let .terminated(status): failConnection(.processTerminated(status))
        case .stdoutClosed:
            if let process = connection?.process, !process.isRunning {
                failConnection(.processTerminated(process.terminationStatus))
            } else { failConnection(.connectionClosed) }
        }
    }

    private func failConnection(_ error: SourceKitLSPClientError) {
        guard let old = connection else { return }
        let failure = SourceKitLSPFailure(error: error, stderr: String(decoding: stderrTail, as: UTF8.self))
        let handler = isShuttingDown ? nil : failureHandler
        connection = nil
        old.close()
        failureHandler = nil
        notificationHandler = nil
        failPending(error)
        handler?(failure)
    }

    private func consumeStderr(_ data: Data) {
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
