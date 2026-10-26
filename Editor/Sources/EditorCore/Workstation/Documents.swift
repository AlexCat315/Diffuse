import Foundation
public import StudioDocuments
import CoveUICompose

public final class EditorDocumentWorkspace: _ObservableObject, @unchecked Sendable {
    private let publisher = _ObservablePublisher<EditorDocumentWorkspace>()
    private let workspace: DocumentWorkspace
    public private(set) var documents: [TextDocument] = []
    public private(set) var selectedPath: String?
    public private(set) var error: String?
    /// The latest request to put the caret somewhere, e.g. from the outline.
    public private(set) var reveal: EditorDocumentReveal?
    /// Whether the diff tab is open. It sits after the document tabs and is
    /// reused, so stepping through changes never piles up tabs; what it
    /// compares is `EditorVersionControl.snapshot.comparison`.
    public private(set) var hasComparison = false
    /// Whether the diff tab is in front of `selectedPath`.
    public private(set) var showsComparison = false
    /// Tells the workstation which tab is in front; script tabs bring their
    /// language session along.
    var didSelect: ((String?) -> Void)?
    public init(root: URL) { workspace = DocumentWorkspace(root: root) }
    public var hasUnsavedChanges: Bool { documents.contains(where: \.isDirty) }
    /// Everything a view shows about the workspace, compared as one value so a
    /// selection change re-renders views even when the document list is unchanged.
    public var snapshot: EditorDocumentSnapshot {
        EditorDocumentSnapshot(documents: documents, selectedPath: selectedPath, error: error, reveal: reveal,
                               hasComparison: hasComparison, showsComparison: showsComparison)
    }
    public func files() -> [String] { workspace.files() }
    public func open(_ path: String) {
        showsComparison = false
        perform { _ = try workspace.open(path); selectedPath = path }
        // Re-announce even when unchanged: another view may have moved the
        // script selection while this tab stayed in front.
        if error == nil { didSelect?(path) }
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
    /// Re-reads every open document without unsaved edits, e.g. after a pull.
    /// Files that no longer exist close.
    public func reloadUnmodified() {
        let clean = documents.filter { !$0.isDirty && $0.existsOnDisk }.map(\.path)
        for path in clean {
            perform {
                try workspace.close(path)
                let reopened = try? workspace.open(path)
                if reopened?.existsOnDisk != true {
                    try? workspace.close(path, discard: true)
                    if selectedPath == path { selectedPath = workspace.documents.first?.path }
                }
            }
        }
    }
    /// Creates a file and opens it in a tab.
    @discardableResult
    public func create(_ path: String, text: String = "") -> Bool {
        perform { try workspace.create(path, text: text) }
        guard error == nil else { return false }
        open(path)
        return error == nil
    }
    /// Renames a file or folder; its open tabs follow it.
    @discardableResult
    public func move(_ path: String, to destination: String) -> Bool {
        perform {
            try workspace.move(path, to: destination)
            if let selected = selectedPath, selected == path || selected.hasPrefix(path + "/") {
                selectedPath = destination + selected.dropFirst(path.count)
            }
        }
        return error == nil
    }
    /// Moves a file or folder to the Trash, closing its tabs.
    @discardableResult
    public func remove(_ path: String) -> Bool {
        let order = documents.map(\.path)
        perform {
            try workspace.remove(path)
            guard let selected = selectedPath, selected == path || selected.hasPrefix(path + "/") else { return }
            let remaining = workspace.documents.map(\.path)
            let index = order.firstIndex(of: selected) ?? 0
            selectedPath = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
        }
        return error == nil
    }
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
        let previous = selectedPath
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
        refresh()
        if selectedPath != previous { didSelect?(selectedPath) }
    }
    func report(_ failure: Error) { error = failure.localizedDescription; refresh() }
    private func refresh() { documents = workspace.documents; publisher.send() }
    fileprivate func refreshSnapshot() { publisher.send() }
    public func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    public func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
}

public struct EditorDocumentSnapshot: Equatable, Sendable {
    public let documents: [TextDocument]
    public let selectedPath: String?
    public let error: String?
    public var reveal: EditorDocumentReveal? = nil
    public var hasComparison = false
    public var showsComparison = false

    /// The document in front; nil while the diff tab is.
    public var selected: TextDocument? { showsComparison ? nil : documents.first { $0.path == selectedPath } }
}

/// Moves the caret of an open document; `id` makes repeated requests distinct.
public struct EditorDocumentReveal: Equatable, Sendable {
    public let path: String
    public let characterIndex: Int
    public let id: Int
}

extension EditorDocumentWorkspace {
    /// Opens `path` and places the caret at a character index.
    public func reveal(_ path: String, characterIndex: Int) {
        open(path)
        guard error == nil else { return }
        reveal = EditorDocumentReveal(path: path, characterIndex: characterIndex, id: (reveal?.id ?? 0) + 1)
        refreshSnapshot()
    }
}

extension EditorDocumentWorkspace {
    /// Opens the diff tab, or brings it back, in front of the documents.
    public func showComparison() {
        hasComparison = true
        showsComparison = true
        refreshSnapshot()
    }

    public func closeComparison() {
        hasComparison = false
        showsComparison = false
        refreshSnapshot()
    }
}
