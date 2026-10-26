import EditorCore
import CoveUIWorkspace

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

    /// Output tools that only mean something for a scene; they sit beside the
    /// console while the scene is the content and leave with it.
    static let sceneTools: [WorkspacePanelID] = ["animation", "render-pipeline"]

    /// Panels this file places itself, so layout repair leaves them where they are.
    static func isPlacedByContent(_ id: WorkspacePanelID) -> Bool {
        isContentPanel(id) || sceneTools.contains(id)
    }

    static func isContentPanel(_ id: WorkspacePanelID) -> Bool {
        EditorContent.allCases.contains { panel(for: $0) == id }
    }

    /// Puts `id` where the current content shows, so the center holds one
    /// kind of content at a time. Returns false when nothing shows content yet.
    @discardableResult
    static func swap(to id: WorkspacePanelID, in controller: WorkspaceController) -> Bool {
        var document = controller.document
        guard document.groupContaining(panelID: id) == nil, document.panels[id] != nil,
              let group = document.groups.values.first(where: { $0.panels.contains(where: isContentPanel) }) else {
            return false
        }
        var next = group
        next.panels = next.panels.map { isContentPanel($0) ? id : $0 }
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        next.activePanelID = id
        document.groups[group.id] = next
        controller.replace(document)
        return true
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
        placeSceneTools(for: next, in: controller)
        // A view the user picked elsewhere in the rail stays.
        let sidebar = EditorSidebar.of(controller)
        if sidebar.selection == sidebarView(for: current) { sidebar.select(sidebarView(for: next)) }
    }

    private static func placeSceneTools(for content: EditorContent, in controller: WorkspaceController) {
        var document = controller.document
        if content == .scene {
            guard let console = document.groupContaining(panelID: "console"),
                  var group = document.groups[console.id] else { return }
            for id in sceneTools where document.panels[id] != nil && document.groupContaining(panelID: id) == nil {
                group.panels.append(id)
            }
            document.groups[console.id] = group
        } else {
            for groupID in Array(document.groups.keys) {
                guard var group = document.groups[groupID] else { continue }
                group.panels.removeAll { sceneTools.contains($0) }
                if let active = group.activePanelID, sceneTools.contains(active) { group.activePanelID = group.panels.first }
                document.groups[groupID] = group
            }
        }
        if document != controller.document { controller.replace(document) }
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
