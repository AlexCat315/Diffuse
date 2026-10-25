internal import EditorCore
internal import GuavaUI
internal import GuavaUICompose
internal import GuavaUIWorkspace

/// What the left side shows. The rail picks a view and the one sidebar pane
/// renders it, so the left dock never needs a tab strip.
final class EditorSidebar: _ObservableObject {
    static let panelID: WorkspacePanelID = "sidebar"

    private(set) var selection: WorkspacePanelID = "hierarchy"
    private let publisher = _ObservablePublisher<EditorSidebar>()

    nonisolated(unsafe) private static var byController: [ObjectIdentifier: EditorSidebar] = [:]

    /// One sidebar per window layout.
    static func of(_ controller: WorkspaceController) -> EditorSidebar {
        let key = ObjectIdentifier(controller)
        if let existing = byController[key] { return existing }
        let created = EditorSidebar()
        byController[key] = created
        return created
    }

    /// A leading panel is a sidebar view: it is shown through the sidebar pane,
    /// never docked as a tab of its own.
    static func isView(_ descriptor: WorkspacePanelDescriptor) -> Bool {
        descriptor.defaultSlot == .leading && descriptor.panel.id != panelID
    }

    func select(_ id: WorkspacePanelID) {
        guard id != selection else { return }
        selection = id
        publisher.send()
    }

    func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
}

struct EditorSidebarPane: View {
    let registry: WorkspacePanelRegistry
    private var selection: Observed<EditorSidebar, WorkspacePanelID>

    init(sidebar: EditorSidebar, registry: WorkspacePanelRegistry) {
        self.registry = registry
        selection = Observed(\.selection, on: sidebar)
    }

    var body: some View {
        let id = selection.wrappedValue
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if registry.descriptor(for: id) != nil {
                registry.make(id).flex().frame(minWidth: 0, minHeight: 0)
            }
        }.flex().frame(minWidth: 0, minHeight: 0)
            .debugName("editor-sidebar-" + id.rawValue)
    }
}
