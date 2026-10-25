import EditorCore
import GuavaUI
import GuavaUIWorkspace

/// The built-in arrangement: the sidebar, content in the center, its details
/// on the right and output below.
enum EditorWorkspaceDefaults {
    /// The center starts on `content`; the other kinds of content wait off screen until picked.
    static func makeDocument(registry: WorkspacePanelRegistry, content: EditorContent = .scene) -> WorkspaceDocument {
        let panels = Dictionary(uniqueKeysWithValues: registry.descriptors.filter { !EditorSidebar.isView($0) }.map { descriptor in
            (descriptor.panel.id, descriptor.panel)
        })
        let groups = baseGroups(registry: registry, content: content)
        let document = WorkspaceDocument(panels: panels, groups: groups,
            slots: WorkspaceSlot.standardEditorSlots(
                leading: groups["leading"]?.panels.isEmpty == false ? .group("leading") : nil,
                center: .group("center"),
                trailing: groups["trailing"]?.panels.isEmpty == false ? .group("trailing") : nil,
                bottom: groups["bottom"]?.panels.isEmpty == false ? .group("bottom") : nil),
            splitFractions: .init(leading: 0.185, centerTrailing: 0.678, topBottom: 0.74))
        return document
    }

    private static func baseGroups(registry: WorkspacePanelRegistry,
                                   content: EditorContent) -> [WorkspaceTabGroupID: WorkspaceTabGroup] {
        let available = Set(registry.ids)
        let center = EditorContentFollower.panel(for: content)
        var groups: [WorkspaceTabGroupID: WorkspaceTabGroup] = [:]
        let definitions: [(WorkspaceTabGroupID, [WorkspacePanelID], WorkspacePanelID)] = [
            ("leading", [EditorSidebar.panelID], EditorSidebar.panelID),
            ("center", [available.contains(center) ? center : EditorContentFollower.panel(for: .scene)], center),
            ("trailing", ["details"], "details"),
            ("bottom", ["console", "terminal"] + (content == .scene ? EditorContentFollower.sceneTools : []) + ["developer-tools"], "console"),
        ]
        for (id, panelIDs, active) in definitions {
            let panelIDs = panelIDs.filter { available.contains($0) }
            groups[id] = WorkspaceTabGroup(id: id, panels: panelIDs,
                                           activePanelID: panelIDs.contains(active) ? active : panelIDs.first)
        }
        for descriptor in registry.descriptors where !EditorSidebar.isView(descriptor)
            && !EditorContentFollower.isPlacedByContent(descriptor.panel.id)
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
