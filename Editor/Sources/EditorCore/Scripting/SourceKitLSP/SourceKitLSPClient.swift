import Foundation

/// Owns one `sourcekit-lsp` child process and speaks JSON-RPC over its pipes.
///
/// Responsibilities are deliberately narrow: process lifecycle, request/response
/// correlation, and turning server requests we do not implement into a clean
/// error reply. What the messages *mean* lives in
/// ``ScriptLanguageRequest``/``ScriptLanguageResponse``.
public actor SourceKitLSPClient {
    public typealias NotificationHandler = @Sendable (SourceKitLSPNotification) -> Void

    private static let shutdownTimeout: Duration = .seconds(2)
    /// Tail of stderr retained so it can be attached to a mid-flight failure.
    private static let stderrTailCapacity = 8_192

    private let executableURL: URL
    private let workspaceURL: URL
    private let scratchURL: URL
    private let environmentOverrides: [String: String]

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var decoder = LSPMessageFramer.Decoder()
    private var pending: [Int: CheckedContinuation<Data?, Error>] = [:]
    private var nextRequestID = 1
    private var notificationHandler: NotificationHandler?
    private var stderrTail = Data()
    private var isStopping = false
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
        process?.terminate()
    }

    // MARK: - Lifecycle

    public func start(notificationHandler: NotificationHandler? = nil) throws {
        guard process?.isRunning != true else { return }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw SourceKitLSPClientError.executableNotFound(executableURL.path)
        }
        try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        let capabilities = self.capabilities
            ?? SourceKitLSPExecutableLocator.probeCapabilities(executableURL: executableURL)
        self.capabilities = capabilities
        process.arguments = SourceKitLSPCommandLine.arguments(for: workspaceURL,
                                                             scratchURL: scratchURL,
                                                             capabilities: capabilities)
        process.currentDirectoryURL = workspaceURL
        process.environment = ProcessInfo.processInfo.environment.merging(environmentOverrides) { _, new in new }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] process in
            Task { await self?.processDidTerminate(status: process.terminationStatus) }
        }

        do { try process.run() } catch {
            throw SourceKitLSPClientError.launchFailed(String(describing: error))
        }

        self.process = process
        self.inputHandle = stdin.fileHandleForWriting
        self.outputPipe = stdout
        self.errorPipe = stderr
        self.notificationHandler = notificationHandler
        self.isStopping = false

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task {
                if data.isEmpty {
                    await self?.outputDidClose()
                } else {
                    await self?.consume(data)
                }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consumeStderr(data) }
        }
    }

    public func initialize() async throws {
        guard process?.isRunning == true else { throw SourceKitLSPClientError.notRunning }
        _ = try await request("initialize",
                              params: try LSPJSON.data(Self.initializeParams(workspaceURL: workspaceURL)))
        try notify("initialized", params: try LSPJSON.data([String: String]()))
    }

    // MARK: - Messaging

    public func request(_ method: String,
                        params: Data? = nil,
                        timeout: Duration = .seconds(30)) async throws -> Data? {
        guard process?.isRunning == true else { throw SourceKitLSPClientError.notRunning }
        let requestID = nextRequestID
        nextRequestID += 1
        let body = try Self.requestBody(id: requestID, method: method, params: params)

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            do {
                try write(body)
            } catch {
                pending.removeValue(forKey: requestID)?.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expireRequest(requestID, method: method)
            }
        }
    }

    public func notify(_ method: String, params: Data? = nil) throws {
        guard process?.isRunning == true else { throw SourceKitLSPClientError.notRunning }
        try write(try Self.notificationBody(method: method, params: params))
    }

    public func stop() {
        guard !isStopping else { return }
        isStopping = true
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputHandle?.close()
        try? outputPipe?.fileHandleForReading.close()
        try? errorPipe?.fileHandleForReading.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        inputHandle = nil
        outputPipe = nil
        errorPipe = nil
        failPending(SourceKitLSPClientError.notRunning)
    }

    public func shutdown() async {
        if process?.isRunning == true {
            _ = try? await request("shutdown", timeout: Self.shutdownTimeout)
            try? notify("exit")
        }
        stop()
    }

    // MARK: - Client capabilities

    private static func initializeParams(workspaceURL: URL) -> [String: Any] {
        let rootURI = workspaceURL.standardizedFileURL.absoluteString
        return [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "clientInfo": ["name": "GuavaEditor", "version": "0.0.1"],
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
                        "snippetSupport": true,
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
        guard let inputHandle else { throw SourceKitLSPClientError.notRunning }
        try inputHandle.write(contentsOf: LSPMessageFramer.frame(body))
    }

    // MARK: - Decoding

    private func consume(_ data: Data) {
        do {
            for body in try decoder.append(data) {
                try consumeMessage(body)
            }
        } catch {
            failPending(error)
            stop()
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

    private func processDidTerminate(status: Int32) {
        guard !isStopping else { return }
        failPending(SourceKitLSPClientError.processTerminated(status))
        process = nil
        inputHandle = nil
    }

    private func outputDidClose() {
        guard !isStopping else { return }
        let detail = stderrTail.isEmpty ? "" : ": " + (String(data: stderrTail, encoding: .utf8) ?? "")
        failPending(SourceKitLSPClientError.protocolViolation("server closed stdout\(detail)"))
        process = nil
        inputHandle = nil
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
