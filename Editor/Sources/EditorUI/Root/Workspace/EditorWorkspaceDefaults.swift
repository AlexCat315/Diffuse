import EditorCore
import GuavaUI
import GuavaUIWorkspace

/// The built-in arrangement: the sidebar, content in the center, its details
/// on the right and output below.
enum EditorWorkspaceDefaults {
    static func makeDocument(registry: WorkspacePanelRegistry) -> WorkspaceDocument {
        let panels = Dictionary(uniqueKeysWithValues: registry.descriptors.filter { !EditorSidebar.isView($0) }.map { descriptor in
            (descriptor.panel.id, descriptor.panel)
        })
        let groups = baseGroups(registry: registry)
        let document = WorkspaceDocument(panels: panels, groups: groups,
            slots: WorkspaceSlot.standardEditorSlots(
                leading: groups["leading"]?.panels.isEmpty == false ? .group("leading") : nil,
                center: .group("center"),
                trailing: groups["trailing"]?.panels.isEmpty == false ? .group("trailing") : nil,
                bottom: groups["bottom"]?.panels.isEmpty == false ? .group("bottom") : nil),
            splitFractions: .init(leading: 0.185, centerTrailing: 0.678, topBottom: 0.74))
        return document
    }

    private static func baseGroups(registry: WorkspacePanelRegistry) -> [WorkspaceTabGroupID: WorkspaceTabGroup] {
        let available = Set(registry.ids)
        var groups: [WorkspaceTabGroupID: WorkspaceTabGroup] = [:]
        let definitions: [(WorkspaceTabGroupID, [WorkspacePanelID], WorkspacePanelID)] = [
            ("leading", [EditorSidebar.panelID], EditorSidebar.panelID),
            ("center", ["viewport", "documents", "media"], "viewport"),
            ("trailing", ["details"], "details"),
            ("bottom", ["console", "terminal", "animation", "render-pipeline", "developer-tools"], "console"),
        ]
        for (id, panelIDs, active) in definitions {
            let panelIDs = panelIDs.filter { available.contains($0) }
            groups[id] = WorkspaceTabGroup(id: id, panels: panelIDs,
                                           activePanelID: panelIDs.contains(active) ? active : panelIDs.first)
        }
        for descriptor in registry.descriptors where !EditorSidebar.isView(descriptor)
            && !groups.values.contains(where: { $0.panels.contains(descriptor.panel.id) }) {
            let id: WorkspaceTabGroupID
            switch descriptor.defaultSlot {
            case .leading: id = "leading"
            case .trailing: id = "trailing"
            case .bottom: id = "bottom"
            default: id = "center"
            }
            groups[id]?.panels.append(descriptor.panel.id)
            if groups[id]?.activePanelID == nil { groups[id]?.activePanelID = descriptor.panel.id }
        }
        return groups
    }
}
