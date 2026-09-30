import Foundation
import GuavaUIRuntime

public enum ScriptDocumentBuildState: Sendable, Equatable {
    case idle
    case building(revision: UInt64)
    case succeeded(revision: UInt64)
    case cancelled(revision: UInt64)
    case blocked(revision: UInt64, message: String)
    case failed(revision: UInt64, message: String)

    public var isBuilding: Bool {
        if case .building = self { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

public enum ScriptExternalChangeState: Sendable, Equatable {
    case none
    case modifiedOnDisk(source: String)
    case deletedOnDisk

    public var requiresResolution: Bool { self != .none }
}

public enum ScriptLanguageServiceState: Sendable, Equatable {
    case inactive
    case starting
    case ready
    case unavailable(message: String)
}

public struct ScriptWorkspaceDocument: Sendable, Equatable {
    public var file: DynamicScriptManager.ScriptFile
    public var source: String
    public var savedSource: String
    public var editRevision: UInt64
    public var savedRevision: UInt64
    public var buildState: ScriptDocumentBuildState
    public var loadedRevision: UInt64?
    public var output: String
    public var diagnostics: [ScriptLanguageDiagnostic]
    public var externalChange: ScriptExternalChangeState

    public var isDirty: Bool { source != savedSource }
}

public struct ScriptWorkspaceSnapshot: Sendable, Equatable {
    public var documents: [ScriptWorkspaceDocument]
    public var selectedScriptID: String?
    public var languageServiceState: ScriptLanguageServiceState
    public var trustState: ScriptProjectTrustState
    public var trustWarning: String?

    public var selectedDocument: ScriptWorkspaceDocument? {
        guard let selectedScriptID else { return nil }
        return documents.first { $0.file.identifier == selectedScriptID }
    }
}

/// Single source of truth for script documents, diagnostics, build revisions,
/// and the runtime generation visible to the editor.
///
/// All mutations are made from the editor's main thread. Background compiler
/// and language-service callbacks are delivered back on the main actor before
/// touching the snapshot.
public final class ScriptWorkspaceModel: _ObservableObject, @unchecked Sendable {
    public typealias ScriptLoadedHandler = @Sendable (DynamicScriptManager.ScriptFile) -> Void
    public typealias ScriptDeletedHandler = @Sendable (DynamicScriptManager.ScriptFile) -> Void
    public typealias BuildFailedHandler = @Sendable (DynamicScriptManager.ScriptFile, String) -> Void

    private let publisher = _ObservablePublisher<ScriptWorkspaceModel>()
    private let manager: DynamicScriptManager
    private let onScriptLoaded: ScriptLoadedHandler?
    private let onScriptDeleted: ScriptDeletedHandler?
    private let onBuildFailed: BuildFailedHandler?
    private let directoryMonitor: ScriptDirectoryMonitor
    private var didStartLanguageService = false
    private var languageServiceTask: Task<Void, Never>?

    public private(set) var snapshot: ScriptWorkspaceSnapshot

    public init(manager: DynamicScriptManager,
                onScriptLoaded: ScriptLoadedHandler? = nil,
                onScriptDeleted: ScriptDeletedHandler? = nil,
                onBuildFailed: BuildFailedHandler? = nil) throws {
        self.manager = manager
        self.onScriptLoaded = onScriptLoaded
        self.onScriptDeleted = onScriptDeleted
        self.onBuildFailed = onBuildFailed
        self.directoryMonitor = ScriptDirectoryMonitor(directoryURL: manager.scriptsDirectoryURL)
        let documents = try manager.scanScriptFiles().map { file in
            let source = try manager.readSource(at: file.url)
            return ScriptWorkspaceDocument(file: file,
                                           source: source,
                                           savedSource: source,
                                           editRevision: 0,
                                           savedRevision: 0,
                                           buildState: .idle,
                                           loadedRevision: nil,
                                           output: "",
                                           diagnostics: [],
                                           externalChange: .none)
        }
        self.snapshot = ScriptWorkspaceSnapshot(
            documents: documents,
            selectedScriptID: documents.first?.file.identifier,
            languageServiceState: documents.isEmpty ? .inactive : .starting,
            trustState: manager.projectTrustState,
            trustWarning: manager.trustStoreWarning
        )
        let weakModel = WeakScriptWorkspaceModel(self)
        directoryMonitor.start {
            Task { @MainActor in weakModel.value?.refreshFromDisk() }
        }
    }

    deinit { directoryMonitor.stop() }

    public func startLanguageService() {
        guard !didStartLanguageService, !snapshot.documents.isEmpty else { return }
        didStartLanguageService = true
        snapshot.languageServiceState = .starting
        publish()
        let model = self
        let previousTask = languageServiceTask
        languageServiceTask = Task { [manager, model, previousTask] in
            await previousTask?.value
            do {
                try await manager.startLanguageService { update in
                    Task { @MainActor in model.applyDiagnostics(update) }
                }
                await MainActor.run {
                    model.snapshot.languageServiceState = .ready
                    model.publish()
                }
            } catch {
                await MainActor.run {
                    model.didStartLanguageService = false
                    model.snapshot.languageServiceState = .unavailable(
                        message: error.localizedDescription
                    )
                    model.publish()
                }
            }
        }
    }

    @discardableResult
    public func select(scriptID: String) -> Bool {
        guard scriptID != snapshot.selectedScriptID else { return true }
        guard persistSelected() else { return false }
        guard snapshot.documents.contains(where: { $0.file.identifier == scriptID }) else {
            return false
        }
        snapshot.selectedScriptID = scriptID
        publish()
        return true
    }

    public func updateSelectedSource(_ source: String) {
        guard let index = selectedDocumentIndex,
              snapshot.documents[index].source != source else { return }
        snapshot.documents[index].source = source
        snapshot.documents[index].editRevision &+= 1
        let scriptID = snapshot.documents[index].file.identifier
        publish()
        Task { [manager] in
            try? await manager.updateLanguageSource(scriptID: scriptID, text: source)
        }
    }

    @discardableResult
    public func persistSelected(reportSuccess: Bool = false) -> Bool {
        guard let index = selectedDocumentIndex else { return true }
        guard snapshot.documents[index].isDirty else { return true }
        do {
            let document = snapshot.documents[index]
            try manager.writeSource(document.source, at: document.file.url)
            snapshot.documents[index].savedSource = document.source
            snapshot.documents[index].savedRevision = document.editRevision
            if reportSuccess {
                snapshot.documents[index].output = "Saved \(document.file.displayName).swift"
            }
            publish()
            return true
        } catch {
            recordFailure(error.localizedDescription, at: index)
            return false
        }
    }

    @discardableResult
    public func createScript(name: String, source: String) -> Bool {
        guard persistSelected() else { return false }
        do {
            let url = try manager.createScript(name: name, source: source)
            guard let file = try manager.scriptFile(at: url) else {
                throw ScriptWorkspaceError.createdScriptMissing(url.path)
            }
            let document = ScriptWorkspaceDocument(file: file,
                                                   source: source,
                                                   savedSource: source,
                                                   editRevision: 0,
                                                   savedRevision: 0,
                                                   buildState: .idle,
                                                   loadedRevision: nil,
                                                   output: "",
                                                   diagnostics: [],
                                                   externalChange: .none)
            snapshot.documents.append(document)
            sortDocuments()
            snapshot.selectedScriptID = file.identifier
            publish()
            synchronizeLanguageService()
            return true
        } catch {
            recordWorkspaceFailure(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    public func deleteSelectedScript() -> Bool {
        guard let index = selectedDocumentIndex else { return false }
        let document = snapshot.documents[index]
        do {
            try manager.deleteScript(document.file)
            snapshot.documents.remove(at: index)
            snapshot.selectedScriptID = snapshot.documents.first?.file.identifier
            onScriptDeleted?(document.file)
            publish()
            synchronizeLanguageService()
            return true
        } catch {
            recordFailure(error.localizedDescription, at: index)
            return false
        }
    }

    public func compileSelected() {
        guard let scriptID = snapshot.selectedScriptID else { return }
        compile(scriptID: scriptID)
    }

    public func cancelSelectedBuild() {
        guard let index = selectedDocumentIndex,
              snapshot.documents[index].buildState.isBuilding else { return }
        manager.cancelBuild(scriptID: snapshot.documents[index].file.identifier)
        snapshot.documents[index].output = "Cancelling \(snapshot.documents[index].file.displayName).swift…"
        publish()
    }

    public func setProjectTrusted(_ trusted: Bool) {
        do {
            try manager.setProjectTrusted(trusted)
            snapshot.trustState = manager.projectTrustState
            snapshot.trustWarning = nil
            if !trusted {
                for index in snapshot.documents.indices {
                    let revision = snapshot.documents[index].editRevision
                    snapshot.documents[index].buildState = .blocked(
                        revision: revision,
                        message: ScriptProjectTrustError.executionBlocked.localizedDescription
                    )
                }
            }
            publish()
        } catch {
            snapshot.trustWarning = error.localizedDescription
            publish()
        }
    }

    public func compile(scriptID: String) {
        guard let index = documentIndex(scriptID: scriptID), persist(scriptAt: index) else { return }
        let document = snapshot.documents[index]
        let revision = document.editRevision
        snapshot.documents[index].buildState = .building(revision: revision)
        snapshot.documents[index].output = "Compiling \(document.file.displayName).swift…"
        publish()

        manager.compileAndLoad(scriptID: scriptID, sourceURL: document.file.url) { [weak self] status in
            guard let self, let currentIndex = self.documentIndex(scriptID: scriptID) else { return }
            switch status {
            case .succeeded:
                self.snapshot.documents[currentIndex].buildState = .succeeded(revision: revision)
                self.snapshot.documents[currentIndex].loadedRevision = revision
                self.snapshot.documents[currentIndex].output =
                    "Compiled and reloaded \(document.file.displayName).swift"
                self.onScriptLoaded?(document.file)
            case .cancelled:
                self.snapshot.documents[currentIndex].buildState = .cancelled(revision: revision)
                self.snapshot.documents[currentIndex].output = "Build cancelled."
            case .blocked(let message):
                self.snapshot.documents[currentIndex].buildState = .blocked(revision: revision,
                                                                            message: message)
                self.snapshot.documents[currentIndex].output = message
            case .failed(let message):
                self.snapshot.documents[currentIndex].buildState = .failed(
                    revision: revision,
                    message: message
                )
                self.snapshot.documents[currentIndex].output = message
                self.onBuildFailed?(document.file, message)
            case .compiling, .idle:
                break
            }
            self.publish()
        }
    }

    public func markAllBuildsStarted() {
        for index in snapshot.documents.indices {
            let revision = snapshot.documents[index].savedRevision
            if snapshot.trustState.allowsExecution {
                snapshot.documents[index].buildState = .building(revision: revision)
            } else {
                snapshot.documents[index].buildState = .blocked(
                    revision: revision,
                    message: ScriptProjectTrustError.executionBlocked.localizedDescription
                )
            }
        }
        publish()
    }

    public func recordBuildResult(scriptID: String,
                                  status: DynamicScriptManager.CompilationStatus) {
        guard let index = documentIndex(scriptID: scriptID) else { return }
        let revision: UInt64
        if case let .building(requestedRevision) = snapshot.documents[index].buildState {
            revision = requestedRevision
        } else {
            revision = snapshot.documents[index].savedRevision
        }
        switch status {
        case .succeeded:
            snapshot.documents[index].buildState = .succeeded(revision: revision)
            snapshot.documents[index].loadedRevision = revision
            snapshot.documents[index].output =
                "Compiled and reloaded \(snapshot.documents[index].file.displayName).swift"
        case .cancelled:
            snapshot.documents[index].buildState = .cancelled(revision: revision)
            snapshot.documents[index].output = "Build cancelled."
        case .blocked(let message):
            snapshot.documents[index].buildState = .blocked(revision: revision, message: message)
            snapshot.documents[index].output = message
        case .failed(let message):
            snapshot.documents[index].buildState = .failed(revision: revision, message: message)
            snapshot.documents[index].output = message
        case .compiling:
            snapshot.documents[index].buildState = .building(revision: revision)
        case .idle:
            snapshot.documents[index].buildState = .idle
        }
        publish()
    }

    public func clearSelectedOutput() {
        guard let index = selectedDocumentIndex else { return }
        snapshot.documents[index].output = ""
        publish()
    }

    public func setSelectedOutput(_ message: String, marksBuildFailed: Bool = false) {
        guard let index = selectedDocumentIndex else { return }
        snapshot.documents[index].output = message
        if marksBuildFailed {
            let revision = snapshot.documents[index].editRevision
            snapshot.documents[index].buildState = .failed(revision: revision, message: message)
        }
        publish()
    }

    public func dismissLanguageServiceMessage() {
        guard case .unavailable = snapshot.languageServiceState else { return }
        snapshot.languageServiceState = .inactive
        publish()
    }

    public func resolveSelectedExternalChange(useDiskVersion: Bool) {
        guard let index = selectedDocumentIndex else { return }
        let document = snapshot.documents[index]
        do {
            switch document.externalChange {
            case .none:
                return
            case .modifiedOnDisk(let diskSource):
                if useDiskVersion {
                    adoptDiskSource(diskSource, at: index)
                } else {
                    try manager.writeSource(document.source, at: document.file.url)
                    snapshot.documents[index].savedSource = document.source
                    snapshot.documents[index].savedRevision = document.editRevision
                    snapshot.documents[index].externalChange = .none
                }
            case .deletedOnDisk:
                if useDiskVersion {
                    manager.unload(scriptID: document.file.identifier)
                    snapshot.documents.remove(at: index)
                    snapshot.selectedScriptID = snapshot.documents.first?.file.identifier
                    onScriptDeleted?(document.file)
                } else {
                    try FileManager.default.createDirectory(
                        at: document.file.url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try manager.writeSource(document.source, at: document.file.url)
                    snapshot.documents[index].savedSource = document.source
                    snapshot.documents[index].savedRevision = document.editRevision
                    snapshot.documents[index].externalChange = .none
                }
            }
            publish()
            synchronizeLanguageService()
        } catch {
            recordFailure(error.localizedDescription, at: index)
        }
    }

    private var selectedDocumentIndex: Int? {
        guard let selectedScriptID = snapshot.selectedScriptID else { return nil }
        return documentIndex(scriptID: selectedScriptID)
    }

    private func documentIndex(scriptID: String) -> Int? {
        snapshot.documents.firstIndex { $0.file.identifier == scriptID }
    }

    private func persist(scriptAt index: Int) -> Bool {
        guard snapshot.documents.indices.contains(index) else { return false }
        guard snapshot.documents[index].isDirty else { return true }
        do {
            let document = snapshot.documents[index]
            try manager.writeSource(document.source, at: document.file.url)
            snapshot.documents[index].savedSource = document.source
            snapshot.documents[index].savedRevision = document.editRevision
            publish()
            return true
        } catch {
            recordFailure(error.localizedDescription, at: index)
            return false
        }
    }

    func refreshFromDisk() {
        do {
            let diskFiles = try manager.scanScriptFiles()
            let filesByID = Dictionary(uniqueKeysWithValues: diskFiles.map { ($0.identifier, $0) })
            let existingIDs = Set(snapshot.documents.map { $0.file.identifier })
            var didChange = false
            var needsLanguageRefresh = false

            for index in snapshot.documents.indices.reversed() {
                let document = snapshot.documents[index]
                guard let diskFile = filesByID[document.file.identifier] else {
                    if document.isDirty {
                        if snapshot.documents[index].externalChange != .deletedOnDisk {
                            snapshot.documents[index].externalChange = .deletedOnDisk
                            didChange = true
                        }
                    } else {
                        manager.unload(scriptID: document.file.identifier)
                        snapshot.documents.remove(at: index)
                        onScriptDeleted?(document.file)
                        didChange = true
                        needsLanguageRefresh = true
                    }
                    continue
                }

                if diskFile != document.file {
                    snapshot.documents[index].file = diskFile
                    didChange = true
                    needsLanguageRefresh = true
                }
                let diskSource = try manager.readSource(at: diskFile.url)
                if diskSource != document.savedSource {
                    if document.isDirty {
                        let change = ScriptExternalChangeState.modifiedOnDisk(source: diskSource)
                        if snapshot.documents[index].externalChange != change {
                            snapshot.documents[index].externalChange = change
                            didChange = true
                        }
                    } else {
                        adoptDiskSource(diskSource, at: index)
                        didChange = true
                        needsLanguageRefresh = true
                    }
                } else if snapshot.documents[index].externalChange != .none {
                    snapshot.documents[index].externalChange = .none
                    didChange = true
                }
            }

            for file in diskFiles where !existingIDs.contains(file.identifier) {
                let source = try manager.readSource(at: file.url)
                snapshot.documents.append(
                    ScriptWorkspaceDocument(file: file,
                                            source: source,
                                            savedSource: source,
                                            editRevision: 0,
                                            savedRevision: 0,
                                            buildState: .idle,
                                            loadedRevision: nil,
                                            output: "Discovered external script \(file.displayName).swift",
                                            diagnostics: [],
                                            externalChange: .none)
                )
                didChange = true
                needsLanguageRefresh = true
            }

            guard didChange else { return }
            sortDocuments()
            if snapshot.selectedScriptID.flatMap({ id in
                snapshot.documents.first(where: { $0.file.identifier == id })
            }) == nil {
                snapshot.selectedScriptID = snapshot.documents.first?.file.identifier
            }
            publish()
            if needsLanguageRefresh { synchronizeLanguageService() }
        } catch {
            snapshot.trustWarning = "Could not refresh external script changes: \(error.localizedDescription)"
            publish()
        }
    }

    private func adoptDiskSource(_ source: String, at index: Int) {
        guard snapshot.documents.indices.contains(index) else { return }
        snapshot.documents[index].source = source
        snapshot.documents[index].savedSource = source
        snapshot.documents[index].editRevision &+= 1
        snapshot.documents[index].savedRevision = snapshot.documents[index].editRevision
        snapshot.documents[index].buildState = .idle
        snapshot.documents[index].externalChange = .none
        snapshot.documents[index].output =
            "Reloaded external changes in \(snapshot.documents[index].file.displayName).swift"
    }

    private func synchronizeLanguageService() {
        if snapshot.documents.isEmpty {
            snapshot.languageServiceState = .inactive
            publish()
            let model = self
            let previousTask = languageServiceTask
            languageServiceTask = Task { [manager, model, previousTask] in
                await previousTask?.value
                await manager.stopLanguageService()
                await MainActor.run {
                    guard model.snapshot.documents.isEmpty else { return }
                    model.didStartLanguageService = false
                    model.snapshot.languageServiceState = .inactive
                    model.publish()
                }
            }
            return
        }
        if !didStartLanguageService, !snapshot.documents.isEmpty {
            startLanguageService()
            return
        }
        guard didStartLanguageService else { return }
        snapshot.languageServiceState = .starting
        publish()
        let model = self
        let previousTask = languageServiceTask
        languageServiceTask = Task { [manager, model, previousTask] in
            await previousTask?.value
            do {
                try await manager.refreshLanguageWorkspace()
                await MainActor.run {
                    let hasDocuments = !model.snapshot.documents.isEmpty
                    model.didStartLanguageService = hasDocuments
                    model.snapshot.languageServiceState = hasDocuments ? .ready : .inactive
                    model.publish()
                }
            } catch {
                await MainActor.run {
                    model.snapshot.languageServiceState = .unavailable(
                        message: error.localizedDescription
                    )
                    model.publish()
                }
            }
        }
    }

    private func applyDiagnostics(_ update: ScriptLanguageDiagnosticUpdate) {
        guard let index = documentIndex(scriptID: update.scriptID) else { return }
        snapshot.documents[index].diagnostics = update.diagnostics
        publish()
    }

    private func recordFailure(_ message: String, at index: Int) {
        guard snapshot.documents.indices.contains(index) else { return }
        let revision = snapshot.documents[index].editRevision
        snapshot.documents[index].buildState = .failed(revision: revision, message: message)
        snapshot.documents[index].output = message
        publish()
    }

    private func recordWorkspaceFailure(_ message: String) {
        guard let index = selectedDocumentIndex else { return }
        recordFailure(message, at: index)
    }

    private func sortDocuments() {
        snapshot.documents.sort {
            $0.file.displayName.localizedCaseInsensitiveCompare($1.file.displayName) == .orderedAscending
        }
    }

    private func publish() {
        publisher.send()
    }

    public func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable {
        publisher.register(on: self, handler: handler)
    }

    public func _unregisterObserver(_ token: AnyHashable) {
        publisher.unregister(token)
    }
}

private final class WeakScriptWorkspaceModel: @unchecked Sendable {
    weak var value: ScriptWorkspaceModel?

    init(_ value: ScriptWorkspaceModel) {
        self.value = value
    }
}

private enum ScriptWorkspaceError: Error, LocalizedError {
    case createdScriptMissing(String)

    var errorDescription: String? {
        switch self {
        case .createdScriptMissing(let path):
            return "The created script could not be registered as an asset: \(path)"
        }
    }
}
