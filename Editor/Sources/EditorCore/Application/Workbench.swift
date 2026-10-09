import Foundation

extension EditorApplication {
    public func setActivatePanelHandler(_ handler: @escaping (String) -> Void) {
        activatePanelHandler = handler
    }

    public func navigateToIssue(_ target: EditorIssueTarget) {
        switch target {
        case let .script(id, line, column):
            guard scriptWorkspace.select(scriptID: id) else {
                logConsole("Script is missing", severity: .warning, detail: id,
                           nextStep: "Restore the script file, then refresh the script catalog.")
                return
            }
            store.dispatch(.navigateToScript(.init(scriptID: id, line: line, column: column)))
            activatePanelHandler?("scripts")
        case let .entity(id):
            guard scene.entitySummary(id: id) != nil else { return }
            store.dispatch(.setSelectedEntity(id))
            store.dispatch(.setInspectorSceneSettingsVisible(false))
            activatePanelHandler?("inspector")
        case let .asset(id):
            store.dispatch(.navigateToAsset(id))
            activatePanelHandler?("assets")
        case let .file(path):
            if let document = scriptWorkspace.snapshot.documents.first(where: {
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
