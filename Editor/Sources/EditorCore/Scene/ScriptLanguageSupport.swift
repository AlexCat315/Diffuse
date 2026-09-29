import Foundation

public enum ScriptLanguageSupportError: Error, LocalizedError, Sendable, Equatable {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(reason):
            return "Swift language support is unavailable: \(reason)"
        }
    }
}

public struct ScriptLanguageSource: Sendable {
    public let file: DynamicScriptManager.ScriptFile
    public let text: String

    public init(file: DynamicScriptManager.ScriptFile, text: String) {
        self.file = file
        self.text = text
    }
}

public enum ScriptDiagnosticSeverity: Int, Sendable, Equatable {
    case error = 1
    case warning = 2
    case information = 3
    case hint = 4
}

public struct ScriptLanguageDiagnostic: Sendable, Equatable {
    public let severity: ScriptDiagnosticSeverity
    public let startLine: Int
    public let startCharacter: Int
    public let endLine: Int
    public let endCharacter: Int
    public let message: String
    public let code: String?

    public init(severity: ScriptDiagnosticSeverity,
                startLine: Int,
                startCharacter: Int,
                endLine: Int,
                endCharacter: Int,
                message: String,
                code: String? = nil) {
        self.severity = severity
        self.startLine = startLine
        self.startCharacter = startCharacter
        self.endLine = endLine
        self.endCharacter = endCharacter
        self.message = message
        self.code = code
    }
}

public struct ScriptLanguageDiagnosticUpdate: Sendable {
    public let scriptID: String
    public let version: Int?
    public let diagnostics: [ScriptLanguageDiagnostic]

    public init(scriptID: String, version: Int?, diagnostics: [ScriptLanguageDiagnostic]) {
        self.scriptID = scriptID
        self.version = version
        self.diagnostics = diagnostics
    }
}

public actor ScriptLanguageSupport {
    public typealias DiagnosticsHandler = @Sendable (ScriptLanguageDiagnosticUpdate) -> Void

    private let workspace: ScriptLanguageWorkspace
    private let executableURL: URL
    private var client: SourceKitLSPClient?
    private var documents: [String: ScriptLanguageWorkspace.Document] = [:]
    private var versions: [String: Int] = [:]
    private var changeTasks: [String: Task<Void, Never>] = [:]
    private var diagnosticsHandler: DiagnosticsHandler?
    private var didInitialize = false

    public init(scriptsDirectoryURL: URL,
                enginePackageURL: URL,
                executableURL: URL,
                environment: [String: String] = [:]) {
        self.workspace = ScriptLanguageWorkspace(scriptsDirectoryURL: scriptsDirectoryURL,
                                                 enginePackageURL: enginePackageURL)
        self.executableURL = executableURL
        self.environment = environment
    }

    private let environment: [String: String]

    public func start(sources: [ScriptLanguageSource],
                      onDiagnostics: @escaping DiagnosticsHandler) async throws {
        await stop()
        diagnosticsHandler = onDiagnostics
        let sourceTuples = sources.map { ($0.file, $0.text) }
        documents = try workspace.synchronize(sourceTuples)
        versions = Dictionary(uniqueKeysWithValues: sources.map { ($0.file.identifier, 1) })

        guard !sources.isEmpty else { return }
        let client = SourceKitLSPClient(executableURL: executableURL,
                                        workspaceURL: workspace.rootURL,
                                        scratchURL: workspace.rootURL.appendingPathComponent(".build", isDirectory: true),
                                        environment: environment)
        self.client = client
        try await client.start { [weak self] notification in
            Task { await self?.handle(notification) }
        }
        try await client.initialize()
        didInitialize = true

        for source in sources {
            guard let document = documents[source.file.identifier] else { continue }
            try await open(source.text, document: document, version: 1)
        }
    }

    public func update(scriptID: String, text: String) async throws {
        guard didInitialize,
              let client,
              let document = documents[scriptID] else { return }
        try workspace.writeAnalysisSource(text, to: document)
        let version = (versions[scriptID] ?? 0) + 1
        versions[scriptID] = version
        changeTasks[scriptID]?.cancel()
        changeTasks[scriptID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await self?.sendChange(client: client,
                                   document: document,
                                   version: version,
                                   text: text)
        }
    }

    public func restart(sources: [ScriptLanguageSource]) async throws {
        let handler = diagnosticsHandler ?? { _ in }
        try await start(sources: sources, onDiagnostics: handler)
    }

    public func stop() async {
        for task in changeTasks.values { task.cancel() }
        changeTasks.removeAll()
        if let client { await client.shutdown() }
        client = nil
        didInitialize = false
        documents.removeAll()
        versions.removeAll()
    }

    public func request(method: String, params: Data) async throws -> Data? {
        guard didInitialize, let client else { throw SourceKitLSPClientError.notRunning }
        return try await client.request(method, params: params)
    }

    public func shadowURI(for scriptID: String) -> URL? {
        documents[scriptID]?.analysisURL
    }

    private func open(_ text: String,
                      document: ScriptLanguageWorkspace.Document,
                      version: Int) async throws {
        guard let client else { throw SourceKitLSPClientError.notRunning }
        let params: [String: Any] = [
            "textDocument": [
                "uri": document.analysisURL.standardizedFileURL.absoluteString,
                "languageId": "swift",
                "version": version,
                "text": text,
            ],
        ]
        try await client.notify("textDocument/didOpen", params: SourceKitLSPClient.jsonData(params))
    }

    private func sendChange(client: SourceKitLSPClient,
                            document: ScriptLanguageWorkspace.Document,
                            version: Int,
                            text: String) async {
        let params: [String: Any] = [
            "textDocument": [
                "uri": document.analysisURL.standardizedFileURL.absoluteString,
                "version": version,
            ],
            "contentChanges": [["text": text]],
        ]
        try? await client.notify("textDocument/didChange", params: SourceKitLSPClient.jsonData(params))
    }

    private func handle(_ notification: SourceKitLSPNotification) {
        guard notification.method == "textDocument/publishDiagnostics",
              let params = try? JSONSerialization.jsonObject(with: notification.params) as? [String: Any],
              let uri = params["uri"] as? String,
              let diagnostics = params["diagnostics"] as? [[String: Any]],
              let entry = documents.first(where: {
                  $0.value.analysisURL.standardizedFileURL.absoluteString == uri
              }) else { return }

        let publishedVersion = params["version"] as? Int
        if let publishedVersion,
           let currentVersion = versions[entry.key],
           publishedVersion < currentVersion {
            return
        }
        diagnosticsHandler?(ScriptLanguageDiagnosticUpdate(
            scriptID: entry.key,
            version: publishedVersion,
            diagnostics: diagnostics.compactMap(Self.parseDiagnostic)
        ))
    }

    private static func parseDiagnostic(_ object: [String: Any]) -> ScriptLanguageDiagnostic? {
        guard let range = object["range"] as? [String: Any],
              let start = range["start"] as? [String: Any],
              let end = range["end"] as? [String: Any],
              let startLine = start["line"] as? Int,
              let startCharacter = start["character"] as? Int,
              let endLine = end["line"] as? Int,
              let endCharacter = end["character"] as? Int,
              let message = object["message"] as? String else {
            return nil
        }
        let severityValue = object["severity"] as? Int ?? ScriptDiagnosticSeverity.error.rawValue
        guard let severity = ScriptDiagnosticSeverity(rawValue: severityValue) else { return nil }
        let code: String?
        if let stringCode = object["code"] as? String {
            code = stringCode
        } else if let numericCode = object["code"] as? NSNumber {
            code = numericCode.stringValue
        } else {
            code = nil
        }
        return ScriptLanguageDiagnostic(severity: severity,
                                        startLine: startLine,
                                        startCharacter: startCharacter,
                                        endLine: endLine,
                                        endCharacter: endCharacter,
                                        message: message,
                                        code: code)
    }
}