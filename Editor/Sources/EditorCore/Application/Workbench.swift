import Foundation

extension EditorApplication {
    public func setActivatePanelHandler(_ handler: @escaping (String) -> Void) {
        activatePanelHandler = handler
    }

    /// Opens a project-relative file in a tab and brings the editor forward.
    public func openDocument(_ path: String) {
        workstation.documents.open(path)
        activatePanelHandler?("documents")
    }

    /// Shows a change's diff in the editor's diff tab.
    public func compareChange(_ change: VersionControlChange) {
        workstation.documents.showComparison()
        activatePanelHandler?("documents")
        Task { @MainActor in await workstation.versionControl.compare(change) }
    }

    /// Saves a tab. A Swift file is formatted first when the Swift settings ask
    /// for it; a formatting failure still saves the text as typed.
    @MainActor
    public func saveDocumentFormatting(_ path: String) async -> Bool {
        if SwiftEditingPreferences.load().formatsOnSave, let id = workstation.scriptID(forDocument: path),
           workstation.scripts.snapshot.languageServiceState == .ready,
           let edit = try? await dynamicScriptManager.formatting(scriptID: id), !edit.documents.isEmpty {
            try? workstation.scripts.applyLanguageEdit(edit)
        }
        return workstation.saveDocument(path)
    }

    /// Opens a language-service location: a script, or any Swift file in the project.
    @discardableResult
    public func openSwiftLocation(_ location: ScriptDefinitionLocation) -> Bool {
        var id = location.scriptID
        if id == nil, let url = URL(string: location.documentURI), url.isFileURL,
           let path = workstation.documentPath(for: url) {
            workstation.documents.open(path)
            id = workstation.scriptID(forDocument: path)
        }
        guard let id else { return false }
        navigateToIssue(.script(id: id, line: location.span.start.line, column: location.span.start.character))
        return true
    }

    public func closeComparison() {
        workstation.documents.closeComparison()
        workstation.versionControl.endComparison()
    }

    public func navigateToIssue(_ target: EditorIssueTarget) {
        switch target {
        case let .script(id, line, column):
            guard workstation.scripts.select(scriptID: id) else {
                logConsole("Script is missing", severity: .warning, detail: id,
                           nextStep: "Restore the script file, then refresh the script catalog.")
                return
            }
            store.dispatch(.navigateToScript(.init(scriptID: id, line: line, column: column)))
            // Scripts open where every other file does; the tab follows the caret.
            if let path = workstation.documentPath(forScript: id) { workstation.documents.open(path) }
            activatePanelHandler?("documents")
        case let .entity(id):
            guard scene.entitySummary(id: id) != nil else { return }
            store.dispatch(.setSelectedEntity(id))
            store.dispatch(.setInspectorSceneSettingsVisible(false))
            activatePanelHandler?("inspector")
        case let .asset(id):
            store.dispatch(.navigateToAsset(id))
            activatePanelHandler?("assets")
        case let .file(path):
            if let document = workstation.scripts.snapshot.documents.first(where: {
                $0.file.url.path == path || $0.file.url.lastPathComponent == path
            }) {
                navigateToIssue(.script(id: document.file.identifier, line: 0, column: 0))
            } else {
                store.dispatch(.navigateToAsset(path))
                activatePanelHandler?("assets")
            }
        }
    }

    @discardableResult
    public func beginOperation(_ kind: EditorOperationKind, message: String, total: Int = 0) -> String {
        let operation = EditorOperation(kind: kind, message: message, total: total)
        store.dispatch(.setOperation(operation))
        requestDisplayRefresh()
        return operation.id
    }

    public func finishOperation(_ id: String, succeeded: Bool, message: String,
                                nextStep: String? = nil, target: EditorIssueTarget? = nil, detail: String? = nil) {
        guard var operation = store.operations.first(where: { $0.id == id }) else { return }
        operation.status = succeeded ? .succeeded : .failed
        operation.message = message
        operation.completed = succeeded ? operation.total : operation.completed
        operation.nextStep = nextStep; operation.target = target
        store.dispatch(.setOperation(operation))
        if !succeeded {
            logConsole(message, severity: .error, detail: detail, target: target, nextStep: nextStep)
        }
    }
}
