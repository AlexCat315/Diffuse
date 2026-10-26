internal import EditorCore
internal import CoveUIWorkspace

/// Lets a panel change the window's arrangement (focus mode, revealing a
/// sibling panel) without the registry having to own the controller.
final class EditorWorkbenchLink {
    weak var controller: WorkspaceController?

    nonisolated(unsafe) private static var byApplication: [ObjectIdentifier: EditorWorkbenchLink] = [:]

    /// One link per project window.
    static func of(_ app: EditorApplication) -> EditorWorkbenchLink {
        let key = ObjectIdentifier(app)
        if let existing = byApplication[key] { return existing }
        let created = EditorWorkbenchLink()
        byApplication[key] = created
        return created
    }

    /// A closed project's object identifier can be reused by the next project.
    static func release(_ app: EditorApplication) { byApplication[ObjectIdentifier(app)] = nil }

    var maximizedPanelID: WorkspacePanelID? { controller?.maximizedPanelID }

    /// Writing focus: the panel fills the window; again restores the layout.
    func toggleMaximize(_ id: WorkspacePanelID) {
        guard let controller else { return }
        EditorRootViewFactory.activatePanel(id, in: controller)
        _ = controller.dispatch(.toggleMaximize(id))
    }

    func show(_ id: WorkspacePanelID) {
        guard let controller else { return }
        EditorRootViewFactory.activatePanel(id, in: controller)
    }
}
