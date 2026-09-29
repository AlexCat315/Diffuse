import Foundation

public enum SourceKitLSPClientError: Error, LocalizedError, Sendable, Equatable {
    case executableNotFound(String)
    case launchFailed(String)
    case protocolViolation(String)
    case serverError(code: Int, message: String)
    case requestTimedOut(String)
    case processTerminated(Int32)
    case notRunning

    public var errorDescription: String? {
        switch self {
        case let .executableNotFound(path):
            return "Could not locate sourcekit-lsp at '\(path)'. Set GUAVA_SOURCEKIT_LSP_PATH to the toolchain executable."
        case let .launchFailed(message):
            return "Could not start sourcekit-lsp: \(message)"
        case let .protocolViolation(message):
            return "Invalid SourceKit-LSP message: \(message)"
        case let .serverError(code, message):
            return "SourceKit-LSP request failed (\(code)): \(message)"
        case let .requestTimedOut(method):
            return "SourceKit-LSP request '\(method)' timed out."
        case let .processTerminated(status):
            return "sourcekit-lsp exited with status \(status)."
        case .notRunning:
            return "SourceKit-LSP is not running."
        }
    }
}

public struct SourceKitLSPNotification: Sendable {
    public let method: String
    public let params: Data

    public init(method: String, params: Data) {
        self.method = method
        self.params = params
    }
}

struct LSPContentLengthDecoder {
    static let maximumHeaderBytes = 16 * 1_024
    static let maximumBodyBytes = 32 * 1_024 * 1_024
    private static let headerTerminator = Data([13, 10, 13, 10])
    private(set) var buffer = Data()

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var messages: [Data] = []

        while true {
            guard let separator = buffer.range(of: Self.headerTerminator) else {
                guard buffer.count <= Self.maximumHeaderBytes else {
                    throw SourceKitLSPClientError.protocolViolation("header exceeds size limit")
                }
                break
            }

            let headerData = buffer[..<separator.lowerBound]
            guard headerData.count <= Self.maximumHeaderBytes,
                  let header = String(data: headerData, encoding: .ascii) else {
                throw SourceKitLSPClientError.protocolViolation("invalid header encoding")
            }
            guard let contentLength = Self.contentLength(in: header) else {
                throw SourceKitLSPClientError.protocolViolation("missing Content-Length header")
            }
            guard contentLength <= Self.maximumBodyBytes else {
                throw SourceKitLSPClientError.protocolViolation("message exceeds size limit")
            }

            let bodyStart = separator.upperBound
            guard buffer.count - bodyStart >= contentLength else { break }
            let bodyEnd = bodyStart + contentLength
            messages.append(Data(buffer[bodyStart..<bodyEnd]))
            buffer.removeSubrange(..<bodyEnd)
        }

        return messages
    }

    static func frame(_ body: Data) -> Data {
        var result = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        result.append(body)
        return result
    }

    private static func contentLength(in header: String) -> Int? {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Content-Length") == .orderedSame,
                  let length = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                  length >= 0 else {
                continue
            }
            return length
        }
        return nil
    }
}

public actor SourceKitLSPClient {
    public typealias NotificationHandler = @Sendable (SourceKitLSPNotification) -> Void

    private let executableURL: URL
    private let workspaceURL: URL
    private let scratchURL: URL
    private let environmentOverrides: [String: String]
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var decoder = LSPContentLengthDecoder()
    private var pending: [Int: CheckedContinuation<Data?, Error>] = [:]
    private var nextRequestID = 1
    private var notificationHandler: NotificationHandler?
    private var stderrTail = Data()
    private var isStopping = false

    public init(executableURL: URL,
                workspaceURL: URL,
                scratchURL: URL,
                environment: [String: String] = [:]) {
        self.executableURL = executableURL
        self.workspaceURL = workspaceURL
        self.scratchURL = scratchURL
        self.environmentOverrides = environment
    }

    public static func resolveExecutableURL(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        if let override = environment["GUAVA_SOURCEKIT_LSP_PATH"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw SourceKitLSPClientError.executableNotFound(override)
            }
            return url
        }

        if let pathURL = executable(named: "sourcekit-lsp", path: environment["PATH"] ?? "") {
            return pathURL
        }

        if let xcrunURL = executable(named: "xcrun", path: environment["PATH"] ?? "") {
            let process = Process()
            let output = Pipe()
            process.executableURL = xcrunURL
            process.arguments = ["--find", "sourcekit-lsp"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch {
                throw SourceKitLSPClientError.executableNotFound("sourcekit-lsp")
            }
            process.waitUntilExit()
            let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus == 0, !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            }
        }

        throw SourceKitLSPClientError.executableNotFound("sourcekit-lsp")
    }

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
        process.arguments = [
            "--default-workspace-type", "swiftPM",
            "--scratch-path", scratchURL.path,
            "--bypass-workspace-trust",
        ]
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
        let rootURI = workspaceURL.standardizedFileURL.absoluteString
        let params: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "clientInfo": ["name": "GuavaEditor", "version": "0.0.1"],
            "rootUri": rootURI,
            "workspaceFolders": [["uri": rootURI, "name": workspaceURL.lastPathComponent]],
            "capabilities": Self.clientCapabilities,
            "trace": "off",
        ]
        _ = try await request("initialize", params: Self.jsonData(params))
        try notify("initialized", params: Self.jsonData([String: String]()))
    }

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
        try write(Self.notificationBody(method: method, params: params))
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
            _ = try? await request("shutdown", timeout: .seconds(2))
            try? notify("exit")
        }
        stop()
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
                "completion": ["completionItem": ["snippetSupport": true, "documentationFormat": ["markdown", "plaintext"]]],
                "hover": ["contentFormat": ["markdown", "plaintext"]],
                "definition": ["dynamicRegistration": false],
                "publishDiagnostics": ["relatedInformation": true],
                "semanticTokens": ["requests": ["full": true], "tokenTypes": [], "tokenModifiers": [], "formats": ["relative"]],
            ],
        ]
    }

    private static func requestBody(id: Int, method: String, params: Data?) throws -> Data {
        var body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { body["params"] = try JSONSerialization.jsonObject(with: params, options: [.fragmentsAllowed]) }
        return try jsonData(body)
    }

    private static func notificationBody(method: String, params: Data?) throws -> Data {
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { body["params"] = try JSONSerialization.jsonObject(with: params, options: [.fragmentsAllowed]) }
        return try jsonData(body)
    }

    static func jsonData(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }

    private func write(_ body: Data) throws {
        guard let inputHandle else { throw SourceKitLSPClientError.notRunning }
        try inputHandle.write(contentsOf: LSPContentLengthDecoder.frame(body))
    }

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
                continuation.resume(returning: try Self.jsonData(result))
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
        let params = try object["params"].map { try Self.jsonData($0) } ?? Data("null".utf8)
        notificationHandler?(SourceKitLSPNotification(method: method, params: params))
    }

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
            try write(Self.jsonData(response))
            return
        }
        try write(Self.jsonData(["jsonrpc": "2.0", "id": id, "result": result]))
    }

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
        if stderrTail.count > 8_192 {
            stderrTail.removeSubrange(..<(stderrTail.count - 8_192))
        }
    }

    private func failPending(_ error: Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private static func executable(named name: String, path: String) -> URL? {
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let base = directory.isEmpty ? "/usr/bin" : String(directory)
            let candidate = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}