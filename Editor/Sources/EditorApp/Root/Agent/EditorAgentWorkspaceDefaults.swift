import GuavaUIWorkspace

/// Agent docking belongs to the task shell, independent of manual tool layouts.
enum EditorAgentWorkspaceDefaults {
    static func makeController() -> WorkspaceController {
        let panels: [WorkspacePanelID: WorkspacePanel] = [
            "agent-tasks": .init(id: "agent-tasks", title: L("Tasks"), isClosable: false, iconAssetKey: "panel.hierarchy"),
            "agent-preview": .init(id: "agent-preview", title: L("Viewport"), isClosable: false,
                                   isCollapsible: false, iconAssetKey: "panel.viewport"),
            "agent-conversation": .init(id: "agent-conversation", title: L("Task Conversation"), isClosable: false,
                                        iconAssetKey: "panel.intent-input"),
        ]
        let groups: [WorkspaceTabGroupID: WorkspaceTabGroup] = [
            "leading": .init(id: "leading", panels: ["agent-tasks"], activePanelID: "agent-tasks"),
            "center": .init(id: "center", panels: ["agent-preview"], activePanelID: "agent-preview"),
            "trailing": .init(id: "trailing", panels: ["agent-conversation"], activePanelID: "agent-conversation"),
        ]
        let controller = WorkspaceController(document: WorkspaceDocument(panels: panels, groups: groups,
            slots: WorkspaceSlot.standardEditorSlots(leading: .group("leading"), center: .group("center"),
                                                     trailing: .group("trailing")),
            layoutTree: .group("center"), splitFractions: .init(leading: 0.17, centerTrailing: 0.74)))
        _ = controller.dispatch(.collapse("leading"))
        return controller
    }
}
