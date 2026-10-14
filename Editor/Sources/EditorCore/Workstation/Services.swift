import Foundation

/// Workstation documents have independent persistence and execution lifecycles.
public final class EditorWorkstation: @unchecked Sendable {
    public let scripts: ScriptWorkspaceModel
    public let documents: EditorDocumentWorkspace
    public let media: EditorMediaWorkspace
    init(root: URL, scripts: ScriptWorkspaceModel) throws {
        self.scripts = scripts
        documents = EditorDocumentWorkspace(root: root)
        media = try EditorMediaWorkspace(root: root)
    }
    public var hasUnsavedChanges: Bool {
        scripts.snapshot.documents.contains(where: \.isDirty) || documents.hasUnsavedChanges || media.isDirty
    }
    public func saveAll() -> Bool { scripts.persistAll() && documents.saveAll() && (!media.isDirty || media.save()) }
}
