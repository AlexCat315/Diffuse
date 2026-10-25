import LanguageServerRuntime
public import GuavaProcess
import GuavaLogging
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
    public typealias DetailsHandler = @Sendable (ScriptLanguageServiceDetails) -> Void

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
    private let connectTransport: (@Sendable (ProcessCommand) throws -> LanguageServerTransport)?
    private let memoryUsage: (@Sendable () -> UInt64?)?

    private var client: LSPClient?
    private struct DocumentSession {
        let document: ScriptLanguageWorkspace.Document
        var current: TextBuffer
        var sent: TextBuffer
        var revision: UInt64 = 0
        var protocolVersion = 1
        var changeTask: Task<Void, Never>?
        var diagnostics: [Data] = []
        var environmentFailure: String?
    }
    private var sessions: [String: DocumentSession] = [:]
    /// The editor's latest text for a script, as the server will see it.
    func currentText(scriptID: String) -> TextBuffer? { sessions[scriptID]?.current }
    private var diagnosticsHandler: DiagnosticsHandler?
    private var lifecycle = ScriptLanguageLifecycle()
    private var stateRevision: UInt64 = 0
    private var details = ScriptLanguageServiceDetails(executablePath: "")
    private var detailsHandler: DetailsHandler?
    private var environmentFailure: String?

    public init(scriptsDirectoryURL: URL,
                engineModulePaths: [String],
                clangModuleMapPaths: [String] = [],
                clangIncludePaths: [String] = [],
                executableURL: URL,
                environment: [String: String] = [:],
                connect: (@Sendable (ProcessCommand) throws -> LanguageServerTransport)? = nil,
                memoryUsage: (@Sendable () -> UInt64?)? = nil) {
        self.workspace = ScriptLanguageWorkspace(scriptsDirectoryURL: scriptsDirectoryURL,
                                                 engineModulePaths: engineModulePaths,
                                                 clangModuleMapPaths: clangModuleMapPaths,
                                                 clangIncludePaths: clangIncludePaths,
                                                 sdkURL: environment["SDKROOT"].map { URL(fileURLWithPath: $0) },
                                                 resourceDirectoryURL: environment["SWIFT_EXEC"].map {
                                                     URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent()
                                                         .appendingPathComponent("lib/swift", isDirectory: true)
                                                 })
        self.executableURL = executableURL
        self.environment = environment
        self.connectTransport = connect
        self.memoryUsage = memoryUsage
    }

    // MARK: - Session lifecycle

    public func start(sources: [ScriptLanguageSource],
                      onDiagnostics: @escaping DiagnosticsHandler,
                      onStateChange: StateHandler? = nil,
                      onDetailsChange: DetailsHandler? = nil) async throws {
        await stop()
        lifecycle = ScriptLanguageLifecycle()
        lifecycle.onStateChange = onStateChange
        diagnosticsHandler = onDiagnostics
        detailsHandler = onDetailsChange
        details = ScriptLanguageServiceDetails(executablePath: executableURL.path)
        environmentFailure = nil
        let generation = lifecycle.generation
        setState(.starting)
        do {
            let scripts = sources.filter { !$0.isProjectSource }.map { ($0.file, $0.text.stringValue) }
            let documents = try workspace.synchronize(scripts, projectSources: sources.filter(\.isProjectSource).map(\.file))
            sessions = Dictionary(uniqueKeysWithValues: sources.compactMap { source in
                documents[source.file.identifier].map { (source.file.identifier, DocumentSession(document: $0, current: source.text, sent: source.text, revision: source.revision)) }
            })
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
        let detailsHandler = detailsHandler
        try await start(sources: sources, onDiagnostics: handler, onStateChange: stateHandler, onDetailsChange: detailsHandler)
    }

    /// Adds a project file to the running session. Scripts change the generated
    /// package and need a restart; a project file is opened where it is.
    public func openProjectSource(_ source: ScriptLanguageSource) async throws {
        let id = source.file.identifier
        guard sessions[id] == nil else { return }
        let document = ScriptLanguageWorkspace.projectDocument(for: source.file)
        sessions[id] = DocumentSession(document: document, current: source.text, sent: source.text, revision: source.revision)
        if isReady { try await open(source.text.stringValue, document: document, version: 1) }
    }

    /// The editor wrote the script to disk.
    public func didSave(scriptID: String) async {
        guard let session = sessions[scriptID] else { return }
        await sendChange(scriptID: scriptID, revision: session.revision)
        guard isReady, let client else { return }
        let uri = session.document.analysisURL.standardizedFileURL.absoluteString
        try? await client.notify("textDocument/didSave", params: LSPJSON.data(["textDocument": ["uri": uri]]))
    }

    private func notifyWatchedFiles(_ changes: [ScriptWatchedFiles.Change], connectionID: UUID) async {
        guard isReady, lifecycle.connectionID == connectionID, let client else { return }
        let entries = changes.prefix(1_000).map { ["uri": $0.url.absoluteString, "type": $0.type.rawValue] as [String: Any] }
        try? await client.notify("workspace/didChangeWatchedFiles", params: LSPJSON.data(["changes": entries]))
    }

    public func closeProjectSource(scriptID: String) async {
        guard let session = sessions.removeValue(forKey: scriptID) else { return }
        session.changeTask?.cancel()
        guard isReady, let client,
              let params = try? ScriptLanguageQueries.didClose(uri: session.document.analysisURL.standardizedFileURL.absoluteString)
        else { return }
        try? await client.notify("textDocument/didClose", params: params)
    }

    public func stop() async {
        lifecycle.metricsTask?.cancel()
        lifecycle.metricsTask = nil
        lifecycle.watchTask?.cancel()
        lifecycle.watchTask = nil
        details.residentMemoryBytes = nil
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
        environmentFailure = nil
        details.health = .checking
        details.indexing = nil
        details.residentMemoryBytes = nil
        for identifier in sessions.keys {
            sessions[identifier]?.environmentFailure = nil
            sessions[identifier]?.diagnostics = []
        }
        setState(.starting)
        _ = try workspace.prepareScratch(executableURL: executableURL, environment: environment)
        var command = ProcessCommand(executable: executableURL, directory: workspace.rootURL)
        command.arguments = SourceKitLSPCommandLine.arguments(for: workspace.rootURL,
            capabilities: SourceKitLSPExecutableLocator.probeCapabilities(executableURL: executableURL))
        command.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        command.environment["GUAVA_LOG_RUN_ID"] = LogSystem.launch.runID
        var configuration = LanguageServerConfiguration(command: command, workspace: workspace.rootURL)
        // The project folder is a second root: its own Swift files and package are
        // analyzed in place, and its package keeps a background index under
        // `.build/index-build`, so the next session starts from what was indexed.
        configuration.additionalWorkspaces = [workspace.projectRootURL]
        configuration.connect = connectTransport
        var fallback: [String: Any] = ["swiftCompilerFlags": workspace.includeFlags]
        if let sdk = workspace.sdkURL { fallback["sdk"] = sdk.path }
        // The plugin's options, plus the host's module search paths for files no
        // package describes.
        let server = LanguageCatalog.served?.server?.contribution
        var options = server?.initializationOptions?.foundationValue as? [String: Any] ?? [:]
        options["fallbackBuildSystem"] = fallback
        configuration.initializationOptions = try LSPJSON.data(options)
        configuration.settings = try server?.settings.map { try LSPJSON.data($0.foundationValue) }
        let client = LSPClient(configuration: configuration)
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
              await client.isRunning else { throw LSPClientError.notRunning }
        lifecycle.readySince = ContinuousClock.now
        setState(.ready)
        lifecycle.metricsTask?.cancel()
        lifecycle.metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                await self.refreshMemoryUsage()
            }
        }
        lifecycle.watchTask?.cancel()
        let root = workspace.projectRootURL
        lifecycle.watchTask = Task { [weak self] in
            let served = LanguageCatalog.served
            let extensions = Set(served?.language.extensions ?? []), names = Set(served?.server?.contribution.watchedFiles ?? [])
            var previous = await Task.detached(priority: .utility) { ScriptWatchedFiles.scan(root, extensions: extensions, names: names) }.value
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                let next = await Task.detached(priority: .utility) { ScriptWatchedFiles.scan(root, extensions: extensions, names: names) }.value
                let changes = previous.changes(to: next)
                previous = next
                guard !changes.isEmpty, let self else { continue }
                await self.notifyWatchedFiles(changes, connectionID: connectionID)
            }
        }
        for (id, session) in sessions where session.current != session.sent {
            await sendChange(scriptID: id, revision: session.revision)
        }
    }

    private func setState(_ state: ScriptLanguageServiceState) {
        guard lifecycle.state != state else { return }
        lifecycle.state = state
        let logger = LogSystem.logger("com.guava.editor.lsp")
        switch state {
        case .inactive: logger.info("Swift language server stopped")
        case .starting: logger.info("Swift language server starting")
        case .ready: logger.info("Swift language server ready")
        case let .unavailable(message): logger.warning("Swift language server unavailable: \(message)")
        }
        if case let .unavailable(message) = state {
            details.health = .degraded(message)
            recordLanguageLog(message, level: .error)
        } else {
            if state != .ready { details.health = .checking; details.indexing = nil }
            recordLanguageLog(String(describing: state))
        }
        stateRevision &+= 1
        lifecycle.onStateChange?(ScriptLanguageServiceUpdate(revision: stateRevision, state: state))
    }

    private func handleFailure(_ failure: LSPFailure, connectionID: UUID) {
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
        session.diagnostics = []
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

    /// Fills in documentation the list left out to stay small.
    public func resolveCompletion(_ item: ScriptCompletionItem) async throws -> ScriptCompletionItem {
        guard let resolution = item.resolution, isReady, let client else { return item }
        let connectionID = lifecycle.connectionID
        let payload = try await client.request("completionItem/resolve", params: resolution, timeout: Self.queryTimeout)
        guard connectionID == lifecycle.connectionID, let payload,
              let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let resolved = ScriptLanguageReplies.parseCompletionItem(object) else { return item }
        var next = item
        next.documentation = resolved.documentation
        next.detail = resolved.detail ?? item.detail
        next.resolution = nil
        return next
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

    public func languageServiceDetails() -> ScriptLanguageServiceDetails { details }

    public func referenceDocument(documentURI: String) async throws -> String? {
        guard URL(string: documentURI)?.scheme == "sourcekit-lsp", isReady, let client else { return nil }
        let connectionID = lifecycle.connectionID
        let payload = try await client.request("workspace/getReferenceDocument", params: LSPJSON.data(["uri": documentURI]),
                                               timeout: Self.queryTimeout)
        guard connectionID == lifecycle.connectionID, let payload,
              let object = try JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]) as? [String: Any],
              let content = object["content"] as? String else { return nil }
        guard content.utf8.count <= 16_777_216 else {
            throw ScriptLanguageSupportError.unavailable("The generated reference document is too large to open.")
        }
        return content
    }

    /// Test identifiers the server found in the workspace's index, leaves only:
    /// `Group/test`, the form test runners filter by.
    public func workspaceTests() async throws -> [String] {
        guard isReady, let client else { throw LSPClientError.notRunning }
        let connectionID = lifecycle.connectionID
        let payload = try await client.request("workspace/tests", params: LSPJSON.data([String: Any]()), timeout: .seconds(30))
        guard connectionID == lifecycle.connectionID, let payload,
              let items = try JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]) as? [[String: Any]] else { return [] }
        var identifiers: [String] = []
        func visit(_ item: [String: Any]) {
            let children = item["children"] as? [[String: Any]] ?? []
            if children.isEmpty, let id = item["id"] as? String, item["disabled"] as? Bool != true { identifiers.append(id) }
            children.forEach(visit)
        }
        items.forEach(visit)
        return identifiers
    }

    /// Declarations across the indexed workspace whose names match `query`.
    /// Shadow copies the editor does not show are left out.
    public func workspaceSymbols(matching query: String) async throws -> [ScriptWorkspaceSymbol] {
        guard isReady, let client else { throw LSPClientError.notRunning }
        let connectionID = lifecycle.connectionID
        let payload = try await client.request("workspace/symbol", params: LSPJSON.data(["query": query]), timeout: Self.queryTimeout)
        guard connectionID == lifecycle.connectionID else { throw LSPClientError.notRunning }
        return ScriptAssistanceReplies.workspaceSymbols(payload, limit: 200).compactMap { symbol in
            let scriptID = scriptIdentifier(forDocumentURI: symbol.uri)
            if scriptID == nil, symbol.uri.contains("/.guava/") { return nil }
            return ScriptWorkspaceSymbol(name: symbol.name, kind: symbol.kind, containerName: symbol.container,
                                         location: ScriptDefinitionLocation(documentURI: symbol.uri, scriptID: scriptID, span: symbol.span))
        }
    }

    func diagnosticPayloads(scriptID: String) -> [Data] { sessions[scriptID]?.diagnostics ?? [] }

    func semanticRequest(_ method: String, scriptID: String,
                         parameters: (String) throws -> Data) async throws -> ScriptSemanticResponse {
        guard isReady, let client, let session = sessions[scriptID] else { throw LSPClientError.notRunning }
        for (identifier, document) in sessions { await sendChange(scriptID: identifier, revision: document.revision) }
        let context = semanticContext()
        let connectionID = lifecycle.connectionID
        let payload = try await client.request(method, params: parameters(session.document.analysisURL.standardizedFileURL.absoluteString),
                                               timeout: Self.queryTimeout)
        guard connectionID == lifecycle.connectionID else { throw LSPClientError.notRunning }
        try validateContext(context)
        markSemanticResponse(payload, method: method)
        return ScriptSemanticResponse(payload: payload, context: context)
    }

    func resolveSemanticRequest(_ method: String, params: Data, context: ScriptSemanticContext) async throws -> Data? {
        guard isReady, let client else { throw LSPClientError.notRunning }
        try validateContext(context)
        let connectionID = lifecycle.connectionID
        let payload = try await client.request(method, params: params, timeout: Self.queryTimeout)
        guard connectionID == lifecycle.connectionID else { throw LSPClientError.notRunning }
        try validateContext(context)
        return payload
    }

    private func semanticContext() -> ScriptSemanticContext {
        var documents: [String: ScriptSemanticContext.Document] = [:]
        for (identifier, session) in sessions {
            let document = ScriptSemanticContext.Document(scriptID: identifier, revision: session.revision, version: session.protocolVersion)
            documents[ScriptSemanticContext.documentKey(session.document.analysisURL.absoluteString)] = document
            documents[ScriptSemanticContext.documentKey(session.document.sourceURL.absoluteString)] = document
        }
        return ScriptSemanticContext(documents: documents, generation: lifecycle.generation)
    }

    private func validateContext(_ context: ScriptSemanticContext) throws {
        guard context.generation == lifecycle.generation else { throw LSPClientError.notRunning }
        for document in context.documents.values {
            guard let session = sessions[document.scriptID], session.revision == document.revision else {
                throw ScriptLanguageEditError.staleDocument(document.scriptID)
            }
        }
    }

    private enum Query {
        case hover
        case definition
        case completion(triggerCharacter: String?)
    }

    private func query(_ query: Query,
                       scriptID: String,
                       position: ScriptLanguagePosition) async throws -> Data? {
        guard isReady, let client else { throw LSPClientError.notRunning }
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
            let connectionID = lifecycle.connectionID
            let payload = try await client.request(method, params: params, timeout: Self.queryTimeout)
            guard connectionID == lifecycle.connectionID else { throw LSPClientError.notRunning }
            markSemanticResponse(payload, method: method)
            return payload
        } catch LSPClientError.requestTimedOut {
            // A competing index build made the answer late, not wrong. Let the
            // popup dismiss itself; the next hover will likely succeed.
            return nil
        }
    }

    private func open(_ text: String,
                      document: ScriptLanguageWorkspace.Document,
                      version: Int) async throws {
        guard let client else { throw LSPClientError.notRunning }
        try await client.notify(
            "textDocument/didOpen",
            params: try ScriptLanguageQueries.didOpen(
                uri: document.analysisURL.standardizedFileURL.absoluteString,
                text: text,
                version: version,
                languageID: LanguageCatalog.served?.language.id ?? "plaintext"
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
                handleFailure(LSPFailure(error: error as? LSPClientError ?? .protocolViolation(error.localizedDescription)),
                              connectionID: connectionID)
            }
        }
    }

    private func handle(_ notification: LSPNotification, connectionID: UUID) {
        guard lifecycle.connectionID == connectionID else { return }
        handleServiceNotification(notification)
        guard let published = ScriptLanguageReplies.parseDiagnostics(notification),
              let entry = sessions.first(where: {
                  ScriptSemanticContext.documentKey($0.value.document.analysisURL.absoluteString) == ScriptSemanticContext.documentKey(published.uri)
              }) else { return }

        // Diagnostics are computed against a snapshot; results older than the
        // newest edit would otherwise undo a fix the user just typed.
        if entry.value.current != entry.value.sent { return }
        if let publishedVersion = published.version,
           publishedVersion < entry.value.protocolVersion {
            return
        }
        if let object = try? JSONSerialization.jsonObject(with: notification.params) as? [String: Any],
           let diagnostics = object["diagnostics"] as? [[String: Any]] {
            sessions[entry.key]?.diagnostics = diagnostics.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
        }
        let failure = published.diagnostics.first(where: { Self.isEnvironmentFailure($0.message) })?.message
        sessions[entry.key]?.environmentFailure = failure
        if let reason = environmentFailure ?? sessions.values.compactMap(\.environmentFailure).sorted().first {
            details.health = .degraded(reason)
            recordLanguageLog(reason, level: .error)
        } else {
            if case .degraded = details.health { details.health = .checking }
            publishDetails()
        }
        let diagnostics = published.diagnostics.map { diagnostic in
            var diagnostic = diagnostic
            for index in diagnostic.related.indices {
                diagnostic.related[index].location.scriptID = scriptIdentifier(forDocumentURI: diagnostic.related[index].location.documentURI)
            }
            return diagnostic
        }
        diagnosticsHandler?(ScriptLanguageDiagnosticUpdate(scriptID: entry.key,
                                                           sourceRevision: entry.value.revision,
                                                           version: published.version,
                                                           diagnostics: diagnostics))
    }

    private func scriptIdentifier(forDocumentURI uri: String) -> String? {
        let key = ScriptSemanticContext.documentKey(uri)
        return sessions.first {
            ScriptSemanticContext.documentKey($0.value.document.analysisURL.absoluteString) == key
                || ScriptSemanticContext.documentKey($0.value.document.sourceURL.absoluteString) == key
        }?.key
    }

    private func handleServiceNotification(_ notification: LSPNotification) {
        guard let object = try? JSONSerialization.jsonObject(with: notification.params) as? [String: Any] else { return }
        switch notification.method {
        case "window/logMessage", "window/showMessage", "guava/stderr":
            guard let message = object["message"] as? String, !message.isEmpty else { return }
            let level: ScriptLanguageLogEntry.Level
            switch object["type"] as? Int {
            case 1: level = .error
            case 2: level = .warning
            case 4: level = .debug
            default: level = .info
            }
            if Self.isEnvironmentFailure(message) { environmentFailure = message; details.health = .degraded(message) }
            recordLanguageLog(message, level: level)
        case "$/progress":
            guard let value = object["value"] as? [String: Any], let kind = value["kind"] as? String else { return }
            if kind == "end" { details.indexing = nil }
            else {
                details.indexing = ScriptIndexProgress(title: value["title"] as? String ?? details.indexing?.title ?? "Indexing",
                                                       message: value["message"] as? String,
                                                       percentage: (value["percentage"] as? Int).map { max(0, min(100, $0)) })
            }
            publishDetails()
        default: break
        }
    }

    private static func isEnvironmentFailure(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["loading the standard library failed", "unable to load standard library", "could not find module",
                "internal sourcekit error", "failed to load module", "sdk not found"].contains { text.contains($0) }
    }

    private func recordLanguageLog(_ message: String, level: ScriptLanguageLogEntry.Level = .info) {
        details.record(message, level: level)
        detailsHandler?(details)
    }

    private func publishDetails() {
        details.revision &+= 1
        detailsHandler?(details)
    }

    private func refreshMemoryUsage() {
        guard isReady else { return }
        let bytes = memoryUsage?()
        guard details.residentMemoryBytes != bytes else { return }
        details.residentMemoryBytes = bytes
        publishDetails()
    }

    private func markSemanticResponse(_ payload: Data?, method: String) {
        guard details.health == .checking, environmentFailure == nil,
              !sessions.values.contains(where: { $0.environmentFailure != nil }),
              ScriptLanguageSemanticEvidence.confirmsAnalysis(method: method, payload: payload) else { return }
        details.health = .healthy
        publishDetails()
    }
}
