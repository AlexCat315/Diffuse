import Foundation
import StudioDocuments
import GuavaUICompose

public final class EditorDocumentWorkspace: _ObservableObject, @unchecked Sendable {
    private let publisher = _ObservablePublisher<EditorDocumentWorkspace>()
    private let workspace: DocumentWorkspace
    public private(set) var documents: [TextDocument] = []
    public private(set) var selectedPath: String?
    public private(set) var error: String?
    public init(root: URL) { workspace = DocumentWorkspace(root: root) }
    public var hasUnsavedChanges: Bool { documents.contains(where: \.isDirty) }
    /// Everything a view shows about the workspace, compared as one value so a
    /// selection change re-renders views even when the document list is unchanged.
    public var snapshot: EditorDocumentSnapshot {
        EditorDocumentSnapshot(documents: documents, selectedPath: selectedPath, error: error)
    }
    public func files() -> [String] { workspace.files() }
    public func open(_ path: String) {
        perform { _ = try workspace.open(path); selectedPath = path }
    }
    /// Closing the selected document selects its neighbour in tab order, so
    /// the editor never shows an empty pane while other documents stay open.
    public func close(_ path: String, discard: Bool = false) {
        let order = documents.map(\.path)
        perform {
            try workspace.close(path, discard: discard)
            guard selectedPath == path, let index = order.firstIndex(of: path) else { return }
            let remaining = order.filter { $0 != path }
            selectedPath = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
        }
    }
    public func reload(_ path: String, discard: Bool = false) { perform { try workspace.close(path, discard: discard); _ = try workspace.open(path) } }
    public func edit(_ path: String, text: String) { perform { try workspace.edit(path, text: text) } }
    public func save(_ path: String) { perform { try workspace.save(path) } }
    @discardableResult public func saveAll() -> Bool {
        perform { try workspace.saveAll() }
        return error == nil
    }
    public func read(_ path: String) throws -> TextDocument { defer { refresh() }; return try workspace.open(path) }
    public func write(_ path: String, text: String, expected: String?) throws {
        let document = try workspace.open(path)
        guard !document.isDirty || (!document.existsOnDisk && document.text.isEmpty && expected == nil) else { throw DocumentError.unsavedChanges }
        guard expected == nil ? !document.existsOnDisk : expected == document.text else { throw DocumentError.changedOnDisk }
        try workspace.edit(path, text: text)
        try workspace.save(path)
        refresh()
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
        refresh()
    }
    private func refresh() { documents = workspace.documents; publisher.send() }
    public func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    public func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
}

public struct EditorDocumentSnapshot: Equatable, Sendable {
    public let documents: [TextDocument]
    public let selectedPath: String?
    public let error: String?

    public var selected: TextDocument? { documents.first { $0.path == selectedPath } }
}
