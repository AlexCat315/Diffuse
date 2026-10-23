import Foundation
import StudioDocuments

/// Workstation documents have independent persistence and execution lifecycles.
public final class EditorWorkstation: @unchecked Sendable {
    public let scripts: ScriptWorkspaceModel
    public let documents: EditorDocumentWorkspace
    public let media: EditorMediaWorkspace
    public let versionControl: EditorVersionControl
    public let tasks: EditorTasks
    private let root: URL
    init(root: URL, scripts: ScriptWorkspaceModel, plugins: PluginRuntimeAccess) throws {
        self.root = root.standardizedFileURL
        self.scripts = scripts
        documents = EditorDocumentWorkspace(root: root)
        media = try EditorMediaWorkspace(root: root)
        // Every domain requests its binding from the same lifecycle owner.
        let stepPlugins = StepPlugins(runtime: plugins)
        versionControl = EditorVersionControl(projectRoot: root, plugins: stepPlugins)
        tasks = EditorTasks(root: root, plugins: stepPlugins)
        // Every tab in the served language gets the language service: scripts as
        // part of the game, other project files analyzed in place.
        documents.didSelect = { [weak self] path in
            guard let self, let path else { return }
            let id = self.scriptID(forDocument: path) ?? (LanguageCatalog.served?.matches(path: path) == true
                ? self.scripts.openProjectSource(self.root.appendingPathComponent(path)) : nil)
            if let id { self.scripts.select(scriptID: id) }
        }
        // A pull, discard or branch switch rewrote files: show what is on disk
        // wherever no unsaved edit would be lost.
        versionControl.didChangeFiles = { [weak self] in
            self?.documents.reloadUnmodified()
            self?.scripts.refreshFromDisk()
        }
    }
    public var hasUnsavedChanges: Bool {
        scripts.snapshot.documents.contains(where: \.isDirty) || documents.hasUnsavedChanges || media.isDirty
    }
    public func saveAll() -> Bool { scripts.persistAll() && documents.saveAll() && (!media.isDirty || media.save()) }
}

/// Project scripts open as document tabs, but their text belongs to the script
/// workspace, so builds and the Swift language service see every keystroke.
/// These entry points pick the owner for a tab; callers never need to know.
extension EditorWorkstation {
    public func scriptID(forDocument path: String) -> String? {
        let url = root.appendingPathComponent(path).standardizedFileURL
        return scripts.snapshot.documents.first { $0.file.url.standardizedFileURL == url }?.file.identifier
    }

    /// The project-relative tab path for a script, if it lives in the project.
    public func documentPath(forScript id: String) -> String? {
        scripts.snapshot.documents.first { $0.file.identifier == id }.flatMap { documentPath(for: $0.file.url) }
    }

    /// The project-relative path of a file or folder inside the project.
    public func documentPath(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard path.hasPrefix(base) else { return nil }
        return String(path.dropFirst(base.count))
    }

    /// Adds `NewScript.swift` (numbered when taken) and opens it in a tab.
    @discardableResult
    public func createScript(source: String) -> String? {
        let taken = Set(scripts.snapshot.documents.map { $0.file.displayName.lowercased() })
        var name = "NewScript", suffix = 2
        while taken.contains(name.lowercased()) { name = "NewScript\(suffix)"; suffix += 1 }
        guard scripts.createScript(name: name, source: source), let id = scripts.snapshot.selectedScriptID,
              let path = documentPath(forScript: id) else { return nil }
        documents.open(path)
        return path
    }

    /// Deletes a project script with its tab; unsaved edits go with it.
    @discardableResult
    public func deleteScript(atDocument path: String) -> Bool {
        guard let id = scriptID(forDocument: path) else { return false }
        scripts.revert(scriptID: id)
        if documents.documents.contains(where: { $0.path == path }) { documents.close(path, discard: true) }
        guard scripts.select(scriptID: id), scripts.deleteSelectedScript() else { return false }
        // Deleting moved the script selection; give it back to the front tab.
        if let front = documents.selectedPath { documents.open(front) }
        return true
    }

    public func isDocumentDirty(_ document: TextDocument) -> Bool {
        guard let id = scriptID(forDocument: document.path) else { return document.isDirty }
        return scripts.snapshot.documents.first { $0.file.identifier == id }?.isDirty ?? false
    }

    @discardableResult
    public func saveDocument(_ path: String) -> Bool {
        if let id = scriptID(forDocument: path) { return scripts.persist(scriptID: id) }
        documents.save(path)
        return documents.error == nil
    }

    public func revertDocument(_ path: String) {
        if let id = scriptID(forDocument: path) { scripts.revert(scriptID: id) } else { documents.reload(path, discard: true) }
    }

    /// Closing a modified script without `discard` is refused like any other
    /// modified document; discarding drops its edits first.
    public func closeDocument(_ path: String, discard: Bool = false) {
        if let id = scriptID(forDocument: path),
           scripts.snapshot.documents.first(where: { $0.file.identifier == id })?.isDirty == true {
            guard discard else { documents.report(DocumentError.unsavedChanges); return }
            scripts.revert(scriptID: id)
        }
        documents.close(path, discard: discard)
        if let id = scriptID(forDocument: path), !documents.documents.contains(where: { $0.path == path }) {
            scripts.closeProjectSource(scriptID: id)
        }
    }
}
