import EditorCore
import GuavaUIApp
import GuavaUIWorkspace

/// Built-in arrangements put the tools named by each preset on screen.
enum EditorWorkspaceDefaults {
    static func makeDocument(mode: EditorWorkspaceMode,
                             preset requestedPreset: EditorLayoutPreset,
                             registry: PanelRegistry) -> WorkspaceDocument {
        let registry = EditorWorkspacePanelPolicy.registry(for: mode, from: registry)
        let preset = requestedPreset.mode == mode ? requestedPreset : .default(for: mode)
        let panels = Dictionary(uniqueKeysWithValues: registry.descriptors.map { descriptor in
            (descriptor.id, WorkspacePanel(id: descriptor.id, title: descriptor.title,
                isClosable: descriptor.closable, isDraggable: true,
                isCollapsible: descriptor.preferredSlot != .center, iconAssetKey: descriptor.iconAssetKey))
        })
        var groups = baseGroups(preset: preset, registry: registry)
        var center: WorkspaceLayoutNode = .group("center")
        var bottom: WorkspaceLayoutNode = .group("bottom")

        if mode == .scripting || mode == .modeling {
            move("assets", to: "leading", groups: &groups, panels: panels)
        }
        if mode == .scripting { move("scripts", to: "center", groups: &groups, panels: panels) }

        switch preset {
        case .levelWorkbench where panels["scripts"] != nil:
            move("scripts", to: "script-editor", groups: &groups, panels: panels)
            center = .split(axis: .horizontal, fraction: 0.54,
                            first: .group("center"), second: .group("script-editor"))
        case .levelCinematics where panels["animation"] != nil && panels["render-pipeline"] != nil:
            move("render-pipeline", to: "render-tools", groups: &groups, panels: panels)
            bottom = .split(axis: .horizontal, fraction: 0.6,
                            first: .group("bottom"), second: .group("render-tools"))
        case .animationSequencer where panels["animation"] != nil:
            move("animation", to: "animation-details", groups: &groups, panels: panels)
            center = .split(axis: .horizontal, fraction: 0.5,
                            first: .group("center"), second: .group("animation-details"))
            if panels["assets"] != nil { groups["bottom"]?.activePanelID = "assets" }
        default: break
        }

        let document = WorkspaceDocument(panels: panels, groups: groups,
            slots: WorkspaceSlot.standardEditorSlots(
                leading: groups["leading"]?.panels.isEmpty == false ? .group("leading") : nil,
                center: center,
                trailing: groups["trailing"]?.panels.isEmpty == false ? .group("trailing") : nil,
                bottom: groups["bottom"]?.panels.isEmpty == false ? bottom : nil),
            layoutTree: center, splitFractions: defaultFractions(for: preset))
        let controller = WorkspaceController(document: document)
        if preset == .levelDefault || preset == .modelingDefault {
            _ = controller.dispatch(.collapse("bottom"))
        } else if preset == .modelingSculpt {
            for group: WorkspaceTabGroupID in ["leading", "trailing", "bottom"] {
                _ = controller.dispatch(.collapse(group))
            }
        } else if preset == .animationSequencer {
            _ = controller.dispatch(.collapse("trailing"))
        }
        return controller.document
    }

    private static func baseGroups(preset: EditorLayoutPreset,
                                   registry: PanelRegistry) -> [WorkspaceTabGroupID: WorkspaceTabGroup] {
        let available = Set(registry.ids)
        var groups: [WorkspaceTabGroupID: WorkspaceTabGroup] = [:]
        let definitions: [(WorkspaceTabGroupID, [WorkspacePanelID], WorkspacePanelID)] = [
            ("leading", ["hierarchy"], "hierarchy"),
            ("center", ["viewport"], "viewport"),
            ("trailing", ["inspector"], "inspector"),
            ("bottom", ["assets", "console", "animation", "render-pipeline", "developer-tools", "confirmation-host", "scripts", "intent-input"],
             defaultBottomPanelID(for: preset)),
        ]
        for (id, panelIDs, active) in definitions {
            let panelIDs = panelIDs.filter { available.contains($0) }
            groups[id] = WorkspaceTabGroup(id: id, panels: panelIDs,
                                           activePanelID: panelIDs.contains(active) ? active : panelIDs.first)
        }
        for descriptor in registry.descriptors where !groups.values.contains(where: { $0.panels.contains(descriptor.id) }) {
            let id: WorkspaceTabGroupID
            switch descriptor.preferredSlot {
            case .leading: id = "leading"
            case .trailing: id = "trailing"
            case .bottom: id = "bottom"
            default: id = "center"
            }
            groups[id]?.panels.append(descriptor.id)
            if groups[id]?.activePanelID == nil { groups[id]?.activePanelID = descriptor.id }
        }
        return groups
    }

    private static func move(_ panel: WorkspacePanelID, to destination: WorkspaceTabGroupID,
                             groups: inout [WorkspaceTabGroupID: WorkspaceTabGroup],
                             panels: [WorkspacePanelID: WorkspacePanel]) {
        guard panels[panel] != nil else { return }
        for id in Array(groups.keys) {
            guard var group = groups[id], group.panels.contains(panel) else { continue }
            group.panels.removeAll { $0 == panel }
            if group.activePanelID == panel { group.activePanelID = group.panels.first }
            groups[id] = group
        }
        var group = groups[destination] ?? WorkspaceTabGroup(id: destination, panels: [])
        group.panels.append(panel)
        group.activePanelID = panel
        groups[destination] = group
    }

    private static func defaultFractions(for preset: EditorLayoutPreset) -> WorkspaceSplitFractions {
        switch preset {
        case .scriptingDefault: return .init(leading: 0.22, centerTrailing: 0.74, topBottom: 0.72)
        case .levelWorkbench: return .init(leading: 0.16, centerTrailing: 0.75, topBottom: 0.68)
        case .levelDefault: return .init(leading: 0.17, centerTrailing: 0.75, topBottom: 0.66)
        case .levelCinematics: return .init(leading: 0.18, centerTrailing: 0.76, topBottom: 0.60)
        case .modelingDefault: return .init(leading: 0.22, centerTrailing: 0.76, topBottom: 0.66)
        case .modelingSculpt: return .init(leading: 0.19, centerTrailing: 0.78, topBottom: 0.72)
        case .animationDefault: return .init(leading: 0.20, centerTrailing: 0.76, topBottom: 0.62)
        case .animationSequencer: return .init(leading: 0.18, centerTrailing: 0.74, topBottom: 0.64)
        }
    }

    private static func defaultBottomPanelID(for preset: EditorLayoutPreset) -> WorkspacePanelID {
        switch preset {
        case .scriptingDefault: return "console"
        case .levelWorkbench: return "developer-tools"
        case .levelDefault: return "assets"
        case .levelCinematics, .animationDefault, .animationSequencer: return "animation"
        case .modelingDefault, .modelingSculpt: return "render-pipeline"
        }
    }
}
