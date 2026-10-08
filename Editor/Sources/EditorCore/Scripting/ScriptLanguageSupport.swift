import Foundation
import GuavaUICompose

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
    public typealias StateHandler = @Sendable (ScriptLanguageServiceUpdate) -> Void

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
    private struct DocumentSession {
        let document: ScriptLanguageWorkspace.Document
        var current: TextBuffer
        var sent: TextBuffer
        var revision: UInt64 = 0
        var protocolVersion = 1
        var changeTask: Task<Void, Never>?
    }
    private var sessions: [String: DocumentSession] = [:]
    private var diagnosticsHandler: DiagnosticsHandler?
    private var lifecycle = ScriptLanguageLifecycle()
    private var stateRevision: UInt64 = 0

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
                      onDiagnostics: @escaping DiagnosticsHandler,
                      onStateChange: StateHandler? = nil) async throws {
        await stop()
        lifecycle = ScriptLanguageLifecycle()
        lifecycle.onStateChange = onStateChange
        diagnosticsHandler = onDiagnostics
        let generation = lifecycle.generation
        setState(.starting)
        do {
            let sourceTuples = sources.map { ($0.file, $0.text.stringValue) }
            let documents = try workspace.synchronize(sourceTuples)
            sessions = Dictionary(uniqueKeysWithValues: sources.compactMap { source in
                documents[source.file.identifier].map { (source.file.identifier, DocumentSession(document: $0, current: source.text, sent: source.text, revision: source.revision)) }
            })
            guard !sources.isEmpty else { setState(.inactive); return }
            try await connect(generation: generation)
        } catch {
            guard lifecycle.generation == generation else { throw CancellationError() }
            // Startup errors are surfaced to the caller. Only an established
            // session reconnects automatically after an unexpected failure.
            lifecycle.recoveryTask?.cancel()
            setState(.unavailable(message: error.localizedDescription))
            throw error
        }
    }

    public func restart(sources: [ScriptLanguageSource]) async throws {
        let handler = diagnosticsHandler ?? { _ in }
        let stateHandler = lifecycle.onStateChange
        try await start(sources: sources, onDiagnostics: handler, onStateChange: stateHandler)
    }

    public func stop() async {
        let wasReady = isReady
        lifecycle.generation = UUID()
        lifecycle.recoveryTask?.cancel()
        lifecycle.recoveryTask = nil
        lifecycle.connectionID = nil
        setState(.inactive)
        for session in sessions.values { session.changeTask?.cancel() }
        let old = client
        client = nil
        sessions.removeAll()
        if let old {
            if wasReady { await old.shutdown() }
            else { await old.stop() }
        }
    }

    public var isReady: Bool { lifecycle.state == .ready }

    private func connect(generation: UUID) async throws {
        guard lifecycle.generation == generation else { throw CancellationError() }
        setState(.starting)
        let client = SourceKitLSPClient(executableURL: executableURL,
                                       workspaceURL: workspace.rootURL,
                                       scratchURL: workspace.rootURL.appendingPathComponent(".build", isDirectory: true),
                                       environment: environment)
        let connectionID = UUID()
        self.client = client
        lifecycle.connectionID = connectionID
        try await client.start(notificationHandler: { [weak self] notification in
            Task { await self?.handle(notification, connectionID: connectionID) }
        }, onFailure: { [weak self] failure in
            Task { await self?.handleFailure(failure, connectionID: connectionID) }
        })
        try await client.initialize()
        guard lifecycle.generation == generation, lifecycle.connectionID == connectionID else {
            await client.stop()
            throw CancellationError()
        }
        for scriptID in Array(sessions.keys) {
            guard var session = sessions[scriptID] else { continue }
            session.sent = session.current
            session.protocolVersion = 1
            sessions[scriptID] = session
            try await open(session.sent.stringValue, document: session.document, version: 1)
        }
        guard lifecycle.generation == generation, lifecycle.connectionID == connectionID,
              await client.isRunning else { throw SourceKitLSPClientError.notRunning }
        lifecycle.readySince = ContinuousClock.now
        setState(.ready)
        for (id, session) in sessions where session.current != session.sent {
            await sendChange(scriptID: id, revision: session.revision)
        }
    }

    private func setState(_ state: ScriptLanguageServiceState) {
        guard lifecycle.state != state else { return }
        lifecycle.state = state
        stateRevision &+= 1
        lifecycle.onStateChange?(ScriptLanguageServiceUpdate(revision: stateRevision, state: state))
    }

    private func handleFailure(_ failure: SourceKitLSPFailure, connectionID: UUID) {
        guard lifecycle.connectionID == connectionID else { return }
        lifecycle.connectionID = nil
        for session in sessions.values { session.changeTask?.cancel() }
        if let readySince = lifecycle.readySince,
           readySince.duration(to: .now) >= .seconds(30) { lifecycle.recoveryAttempt = 0 }
        lifecycle.readySince = nil
        setState(.unavailable(message: failure.message))
        scheduleRecovery()
    }

    private func scheduleRecovery() {
        let delays: [Duration] = [.milliseconds(500), .seconds(2), .seconds(5)]
        guard lifecycle.recoveryAttempt < delays.count, !sessions.isEmpty else { return }
        let delay = delays[lifecycle.recoveryAttempt]
        lifecycle.recoveryAttempt += 1
        let generation = lifecycle.generation
        lifecycle.recoveryTask?.cancel()
        lifecycle.recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.recover(generation: generation)
        }
    }

    private func recover(generation: UUID) async {
        guard lifecycle.generation == generation else { return }
        lifecycle.recoveryTask = nil
        do {
            try await connect(generation: generation)
        } catch {
            guard lifecycle.generation == generation else { return }
            setState(.unavailable(message: error.localizedDescription))
            // A transport failure has already scheduled its next attempt.
            if lifecycle.recoveryTask == nil { scheduleRecovery() }
        }
    }

    /// Pushes an edit, debounced so bursts of keystrokes collapse into one
    /// `didChange` notification.
    public func update(scriptID: String, text: TextBuffer, revision: UInt64) async throws {
        guard var session = sessions[scriptID], revision > session.revision else { return }
        session.current = text; session.revision = revision
        session.changeTask?.cancel()
        session.changeTask = isReady ? Task { [weak self] in
            try? await Task.sleep(for: Self.changeDebounce)
            guard !Task.isCancelled else { return }
            await self?.sendChange(scriptID: scriptID, revision: revision)
        } : nil
        sessions[scriptID] = session
        // The language server owns the open document overlay. Shadow files are
        // serialized at workspace synchronization, never on each keystroke.
    }

    /// Location the language server knows this script by — the shadow copy, not
    /// the project file the user sees.
    public func shadowURI(for scriptID: String) -> URL? {
        sessions[scriptID]?.document.analysisURL
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
        guard isReady, let client else { throw SourceKitLSPClientError.notRunning }
        guard let session = sessions[scriptID] else { return nil }
        await sendChange(scriptID: scriptID, revision: session.revision)
        let document = session.document
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

    private func sendChange(scriptID: String, revision: UInt64) async {
        guard isReady, let client, var session = sessions[scriptID], session.revision == revision else { return }
        let version = session.protocolVersion + 1
        do {
            let params = try ScriptLanguageQueries.didChange(uri: session.document.analysisURL.standardizedFileURL.absoluteString,
                                                             previous: session.sent, current: session.current, version: version)
            session.sent = session.current
            if params != nil { session.protocolVersion = version }
            sessions[scriptID] = session
            if let params { try await client.notify("textDocument/didChange", params: params) }
        } catch {
            // The session cannot safely guess which revision reached the
            // server after a transport failure. A restart opens fresh roots.
            if let connectionID = lifecycle.connectionID {
                handleFailure(SourceKitLSPFailure(error: error as? SourceKitLSPClientError ?? .protocolViolation(error.localizedDescription)),
                              connectionID: connectionID)
            }
        }
    }

    private func handle(_ notification: SourceKitLSPNotification, connectionID: UUID) {
        guard lifecycle.connectionID == connectionID, let published = ScriptLanguageReplies.parseDiagnostics(notification),
              let entry = sessions.first(where: {
                  $0.value.document.analysisURL.standardizedFileURL.absoluteString == published.uri
              }) else { return }

        // Diagnostics are computed against a snapshot; results older than the
        // newest edit would otherwise undo a fix the user just typed.
        if entry.value.current != entry.value.sent { return }
        if let publishedVersion = published.version,
           publishedVersion < entry.value.protocolVersion {
            return
        }
        diagnosticsHandler?(ScriptLanguageDiagnosticUpdate(scriptID: entry.key,
                                                           sourceRevision: entry.value.revision,
                                                           version: published.version,
                                                           diagnostics: published.diagnostics))
    }

    private func scriptIdentifier(forDocumentURI uri: String) -> String? {
        sessions.first { $0.value.document.analysisURL.standardizedFileURL.absoluteString == uri }?.key
    }
}
