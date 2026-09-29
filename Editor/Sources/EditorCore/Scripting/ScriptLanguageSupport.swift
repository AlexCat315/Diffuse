import Foundation

/// Orchestrates one SourceKit-LSP session for the project's script files.
///
/// This actor owns *document lifecycle*: it mirrors script sources into the
/// shadow SwiftPM workspace (``ScriptLanguageWorkspace``), keeps versions in
/// step with the editor, publishes diagnostics, and forwards semantic queries.
/// Wire format and process management live one layer down.
///
/// Diagnostics are asynchronous and unsolicited, so they arrive through a
/// handler registered at startup rather than awaiting each edit.
public actor ScriptLanguageSupport {
    public typealias DiagnosticsHandler = @Sendable (ScriptLanguageDiagnosticUpdate) -> Void

    /// Grace period before an unsolicited edit is pushed to the server. Typing
    /// produces dozens of changes per second; only settled text is worth
    /// re-indexing.
    private static let changeDebounce: Duration = .milliseconds(180)
    /// Interactive queries must never wedge the editor: a slow index build is
    /// reported as "no result" instead of blocking the popup.
    private static let queryTimeout: Duration = .seconds(6)

    private let workspace: ScriptLanguageWorkspace
    private let executableURL: URL
    private let environment: [String: String]

    private var client: SourceKitLSPClient?
    private var documents: [String: ScriptLanguageWorkspace.Document] = [:]
    private var versions: [String: Int] = [:]
    private var changeTasks: [String: Task<Void, Never>] = [:]
    private var diagnosticsHandler: DiagnosticsHandler?
    private var didInitialize = false

    public init(scriptsDirectoryURL: URL,
                engineModulePaths: [String],
                clangModuleMapPaths: [String] = [],
                clangIncludePaths: [String] = [],
                executableURL: URL,
                environment: [String: String] = [:]) {
        self.workspace = ScriptLanguageWorkspace(scriptsDirectoryURL: scriptsDirectoryURL,
                                                 engineModulePaths: engineModulePaths,
                                                 clangModuleMapPaths: clangModuleMapPaths,
                                                 clangIncludePaths: clangIncludePaths)
        self.executableURL = executableURL
        self.environment = environment
    }

    // MARK: - Session lifecycle

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

    /// Pushes an edit, debounced so bursts of keystrokes collapse into one
    /// `didChange` notification.
    public func update(scriptID: String, text: String) async throws {
        guard didInitialize,
              let client,
              let document = documents[scriptID] else { return }
        try workspace.writeAnalysisSource(text, to: document)
        let version = (versions[scriptID] ?? 0) + 1
        versions[scriptID] = version
        changeTasks[scriptID]?.cancel()
        changeTasks[scriptID] = Task { [weak self] in
            try? await Task.sleep(for: Self.changeDebounce)
            guard !Task.isCancelled else { return }
            await self?.sendChange(client: client,
                                   document: document,
                                   version: version,
                                   text: text)
        }
    }

    /// Location the language server knows this script by — the shadow copy, not
    /// the project file the user sees.
    public func shadowURI(for scriptID: String) -> URL? {
        documents[scriptID]?.analysisURL
    }

    // MARK: - Semantic queries

    public func hover(scriptID: String,
                      at position: ScriptLanguagePosition) async throws -> ScriptHoverResult? {
        let payload = try await query(.hover, scriptID: scriptID, position: position)
        return ScriptLanguageReplies.parseHover(payload)
    }

    public func completion(scriptID: String,
                           at position: ScriptLanguagePosition,
                           triggerCharacter: String? = nil) async throws -> ScriptCompletionResult {
        let payload = try await query(.completion(triggerCharacter: triggerCharacter),
                                      scriptID: scriptID,
                                      position: position)
        return ScriptLanguageReplies.parseCompletion(payload)
    }

    /// Resolves `goto definition`, re-mapping the shadow workspace URIs back
    /// onto project script identifiers so the editor can decide whether the
    /// target is something it can show.
    public func definition(scriptID: String,
                           at position: ScriptLanguagePosition) async throws -> [ScriptDefinitionLocation] {
        let payload = try await query(.definition, scriptID: scriptID, position: position)
        return ScriptLanguageReplies.parseDefinition(payload).map { location in
            ScriptDefinitionLocation(documentURI: location.documentURI,
                                     scriptID: scriptIdentifier(forDocumentURI: location.documentURI),
                                     span: location.span)
        }
    }

    // MARK: - Internals

    private enum Query {
        case hover
        case definition
        case completion(triggerCharacter: String?)
    }

    private func query(_ query: Query,
                       scriptID: String,
                       position: ScriptLanguagePosition) async throws -> Data? {
        guard didInitialize, let client else { throw SourceKitLSPClientError.notRunning }
        guard let document = documents[scriptID] else { return nil }
        let uri = document.analysisURL.standardizedFileURL.absoluteString
        let (method, params): (String, Data)
        switch query {
        case .hover:
            method = ScriptLanguageQueries.methodHover
            params = try ScriptLanguageQueries.hover(uri: uri, at: position)
        case .definition:
            method = ScriptLanguageQueries.methodDefinition
            params = try ScriptLanguageQueries.definition(uri: uri, at: position)
        case let .completion(triggerCharacter):
            method = ScriptLanguageQueries.methodCompletion
            params = try ScriptLanguageQueries.completion(uri: uri,
                                                          at: position,
                                                          triggerCharacter: triggerCharacter)
        }
        do {
            return try await client.request(method, params: params, timeout: Self.queryTimeout)
        } catch SourceKitLSPClientError.requestTimedOut {
            // A competing index build made the answer late, not wrong. Let the
            // popup dismiss itself; the next hover will likely succeed.
            return nil
        }
    }

    private func open(_ text: String,
                      document: ScriptLanguageWorkspace.Document,
                      version: Int) async throws {
        guard let client else { throw SourceKitLSPClientError.notRunning }
        try await client.notify(
            "textDocument/didOpen",
            params: try ScriptLanguageQueries.didOpen(
                uri: document.analysisURL.standardizedFileURL.absoluteString,
                text: text,
                version: version
            )
        )
    }

    private func sendChange(client: SourceKitLSPClient,
                            document: ScriptLanguageWorkspace.Document,
                            version: Int,
                            text: String) async {
        guard let params = try? ScriptLanguageQueries.didChange(
            uri: document.analysisURL.standardizedFileURL.absoluteString,
            text: text,
            version: version
        ) else { return }
        try? await client.notify("textDocument/didChange", params: params)
    }

    private func handle(_ notification: SourceKitLSPNotification) {
        guard let published = ScriptLanguageReplies.parseDiagnostics(notification),
              let entry = documents.first(where: {
                  $0.value.analysisURL.standardizedFileURL.absoluteString == published.uri
              }) else { return }

        // Diagnostics are computed against a snapshot; results older than the
        // newest edit would otherwise undo a fix the user just typed.
        if let publishedVersion = published.version,
           let currentVersion = versions[entry.key],
           publishedVersion < currentVersion {
            return
        }
        diagnosticsHandler?(ScriptLanguageDiagnosticUpdate(scriptID: entry.key,
                                                           version: published.version,
                                                           diagnostics: published.diagnostics))
    }

    private func scriptIdentifier(forDocumentURI uri: String) -> String? {
        documents.first { $0.value.analysisURL.standardizedFileURL.absoluteString == uri }?.key
    }
}
