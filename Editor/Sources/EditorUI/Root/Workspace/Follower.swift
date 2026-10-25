import EditorCore
import GuavaUIWorkspace

/// Keeps the editor's content on the center tab being worked in, and brings
/// that content's sidebar view forward when it changes.
enum EditorContentFollower {
    static func panel(for content: EditorContent) -> WorkspacePanelID {
        switch content {
        case .scene: "viewport"
        case .files: "documents"
        case .timeline: "media"
        }
    }

    /// The sidebar view each content brings forward. The details pane follows
    /// the content by itself.
    private static func sidebarView(for content: EditorContent) -> WorkspacePanelID {
        content == .scene ? "hierarchy" : "files"
    }

    @MainActor
    static func follow(_ controller: WorkspaceController, app: EditorApplication) -> WorkspaceController.SubscriptionToken {
        update(app: app, controller: controller)
        return controller.subscribe { [weak app] controller in
            Task { @MainActor in
                guard let app else { return }
                update(app: app, controller: controller)
            }
        }
    }

    static func show(_ content: EditorContent, app: EditorApplication, controller: WorkspaceController) {
        EditorRootViewFactory.activatePanel(panel(for: content), in: controller)
        update(app: app, controller: controller, preferring: content)
    }

    private static func update(app: EditorApplication, controller: WorkspaceController,
                               preferring preferred: EditorContent? = nil) {
        let current = app.store.state.content
        let next = content(in: controller, current: preferred ?? current)
        guard next != current else { return }
        app.store.dispatch(.setContent(next))
        // A view the user picked elsewhere in the rail stays.
        let sidebar = EditorSidebar.of(controller)
        if sidebar.selection == sidebarView(for: current) { sidebar.select(sidebarView(for: next)) }
    }

    static func content(in controller: WorkspaceController, current: EditorContent) -> EditorContent {
        let visible = EditorContent.allCases.filter { isFront(panel(for: $0), in: controller) }
        if let focused = controller.focusedPanelID,
           let content = visible.first(where: { panel(for: $0) == focused }) { return content }
        if visible.contains(current) { return current }
        return visible.first ?? current
    }

    private static func isFront(_ id: WorkspacePanelID, in controller: WorkspaceController) -> Bool {
        if let maximized = controller.maximizedPanelID { return maximized == id }
        guard let group = controller.document.groupContaining(panelID: id) else { return false }
        return group.activePanelID == id && !group.isCollapsed
    }
}
