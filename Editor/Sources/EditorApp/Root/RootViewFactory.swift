import EditorCore
import GuavaUIApp
import GuavaUICompose
import GuavaUIWorkspace
import Foundation

enum EditorRootViewFactory {
    struct EditorShellState: Codable, Sendable {
        var workspaceMode: EditorWorkspaceMode
        var activeLayoutPreset: EditorLayoutPreset
        var themeMode: EditorThemeMode
        var language: EditorLanguage
        var vsyncMode: EditorVSyncMode
        var primarySelectBehavior: SelectionPrimaryModifierBehavior

        init(workspaceMode: EditorWorkspaceMode,
             activeLayoutPreset: EditorLayoutPreset,
             themeMode: EditorThemeMode = .dark,
             language: EditorLanguage = .system,
             vsyncMode: EditorVSyncMode = .enabled,
             primarySelectBehavior: SelectionPrimaryModifierBehavior = .subtract) {
            self.workspaceMode = workspaceMode
            self.activeLayoutPreset = activeLayoutPreset
            self.themeMode = themeMode
            self.language = language
            self.vsyncMode = vsyncMode
            self.primarySelectBehavior = primarySelectBehavior
        }

        enum CodingKeys: String, CodingKey {
            case workspaceMode
            case activeLayoutPreset
            case themeMode
            case language
            case vsyncMode
            case primarySelectBehavior
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(workspaceMode, forKey: .workspaceMode)
            try values.encode(activeLayoutPreset, forKey: .activeLayoutPreset)
            try values.encode(themeMode, forKey: .themeMode)
            try values.encode(language, forKey: .language)
            try values.encode(vsyncMode, forKey: .vsyncMode)
            try values.encode(primarySelectBehavior, forKey: .primarySelectBehavior)
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            workspaceMode = try values.decodeIfPresent(EditorWorkspaceMode.self, forKey: .workspaceMode) ?? .level
            activeLayoutPreset = try values.decodeIfPresent(EditorLayoutPreset.self, forKey: .activeLayoutPreset)
                ?? .default(for: workspaceMode)
            themeMode = try values.decodeIfPresent(EditorThemeMode.self, forKey: .themeMode) ?? .dark
            language = try values.decodeIfPresent(EditorLanguage.self, forKey: .language) ?? .system
            vsyncMode = try values.decodeIfPresent(EditorVSyncMode.self, forKey: .vsyncMode) ?? .enabled
            primarySelectBehavior = try values.decodeIfPresent(
                SelectionPrimaryModifierBehavior.self,
                forKey: .primarySelectBehavior
            ) ?? .subtract
        }
    }

    static func makeController(for mode: EditorWorkspaceMode,
                               preset: EditorLayoutPreset,
                               registry: PanelRegistry) -> WorkspaceController {
        if let saved = loadSavedWorkspaceDocument(for: mode, preset: preset) {
            let document = reconciledWorkspaceDocument(saved, registry: registry)
            if document != saved {
                saveWorkspaceDocument(document, for: mode, preset: preset)
            }
            return WorkspaceController(document: document)
        }
        let document = EditorWorkspaceDefaults.makeDocument(mode: mode,
                                                            preset: preset,
                                                            registry: registry)
        saveWorkspaceDocument(document, for: mode, preset: preset)
        return WorkspaceController(document: document)
    }

    static func loadLayoutPreset(into controller: WorkspaceController,
                                 for mode: EditorWorkspaceMode,
                                 preset: EditorLayoutPreset,
                                 registry: PanelRegistry) {
        let document: WorkspaceDocument
        if let saved = loadSavedWorkspaceDocument(for: mode, preset: preset) {
            document = reconciledWorkspaceDocument(saved, registry: registry)
        } else {
            document = EditorWorkspaceDefaults.makeDocument(mode: mode, preset: preset, registry: registry)
        }
        controller.replace(document)
        saveWorkspaceDocument(controller.document, for: mode, preset: preset)
    }

    static func resetLayout(into controller: WorkspaceController,
                            for mode: EditorWorkspaceMode,
                            preset: EditorLayoutPreset,
                            registry: PanelRegistry) {
        let document = EditorWorkspaceDefaults.makeDocument(mode: mode, preset: preset, registry: registry)
        controller.replace(document)
        saveWorkspaceDocument(document, for: mode, preset: preset)
    }

    static func activatePanel(_ id: PanelID, in controller: WorkspaceController) {
        guard let group = controller.document.groupContaining(panelID: id) else { return }
        _ = controller.dispatch(.setActivePanel(groupID: group.id, panelID: id))
    }

    static func localizeWorkspaceTitles(in controller: WorkspaceController,
                                        registry: PanelRegistry) {
        var document = controller.document
        for panelID in Array(document.panels.keys) {
            guard var panel = document.panels[panelID] else { continue }
            panel.title = localizedPanelTitle(for: panelID.rawValue)
            document.panels[panelID] = panel
        }
        controller.replace(document)
        localizePanelTitles(in: registry)
    }

    static func localizePanelTitles(in registry: PanelRegistry) {
        for id in registry.ids {
            registry.updateDescriptor(id: id) { descriptor in
                descriptor.title = localizedPanelTitle(for: descriptor.id.rawValue)
            }
        }
    }

    static func makeRegistry(app: EditorApplication) -> PanelRegistry {
        PanelRegistry([
            PanelDescriptor(id: "hierarchy",
                            title: localizedPanelTitle(for: "hierarchy"),
                            preferredRegion: .leading) {
                HierarchyPanel(store: app.store, scene: app.scene)
            },
            PanelDescriptor(id: "inspector",
                            title: localizedPanelTitle(for: "inspector"),
                            preferredRegion: .trailing) {
                InspectorPanel(store: app.store, scene: app.scene)
            },
            PanelDescriptor(id: "viewport",
                            title: localizedPanelTitle(for: "viewport"),
                            closable: false,
                            preferredRegion: .center) {
                ViewportPanel(app: app, scene: app.scene)
            },
            PanelDescriptor(id: "console",
                            title: localizedPanelTitle(for: "console"),
                            preferredRegion: .bottom) {
                ConsolePanel(store: app.store)
            },
            PanelDescriptor(id: "assets",
                            title: localizedPanelTitle(for: "assets"),
                            preferredRegion: .bottom) {
                AssetBrowserPanel(app: app)
            },
            PanelDescriptor(id: "intent-input",
                            title: localizedPanelTitle(for: "intent-input"),
                            preferredRegion: .bottom) {
                IntentInputPanel(app: app)
            },
            PanelDescriptor(id: "confirmation-host",
                            title: localizedPanelTitle(for: "confirmation-host"),
                            preferredRegion: .bottom) {
                ConfirmationHostPanel(app: app)
            },
            PanelDescriptor(id: "render-pipeline",
                            title: localizedPanelTitle(for: "render-pipeline"),
                            preferredRegion: .bottom) {
                RenderPipelinePanel()
            },
        ])
    }

    static func saveWorkspaceLayout(_ controller: WorkspaceController,
                                    for mode: EditorWorkspaceMode,
                                    preset: EditorLayoutPreset) {
        saveWorkspaceDocument(controller.document, for: mode, preset: preset)
    }

    static func saveWorkspaceLayout(_ controller: WorkspaceController) {
        saveWorkspaceLayout(controller,
                            for: .level,
                            preset: .levelDefault)
    }

    static func saveShellState(mode: EditorWorkspaceMode,
                               preset: EditorLayoutPreset,
                               themeMode: EditorThemeMode,
                               language: EditorLanguage,
                               vsyncMode: EditorVSyncMode,
                               primarySelectBehavior: SelectionPrimaryModifierBehavior = .subtract) {
        guard let layoutDir = getLayoutPersistenceDirectory() else { return }
        let shell = EditorShellState(workspaceMode: mode,
                                     activeLayoutPreset: preset,
                                     themeMode: themeMode,
                                     language: language,
                                     vsyncMode: vsyncMode,
                                     primarySelectBehavior: primarySelectBehavior)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(shell)
            let path = layoutDir.appendingPathComponent(shellStatePersistenceKey + ".json")
            try data.write(to: path)
        } catch {
            fputs("[EditorRootViewFactory] failed to save shell state: \(error)\n", stderr)
        }
    }

    static func loadShellState() -> EditorShellState? {
        guard let layoutDir = getLayoutPersistenceDirectory() else { return nil }
        let path = layoutDir.appendingPathComponent(shellStatePersistenceKey + ".json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }

        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            var shell = try decoder.decode(EditorShellState.self, from: data)
            if shell.activeLayoutPreset.mode != shell.workspaceMode {
                shell.activeLayoutPreset = .default(for: shell.workspaceMode)
            }
            return shell
        } catch {
            fputs("[EditorRootViewFactory] failed to load shell state: \(error)\n", stderr)
            return nil
        }
    }

    private static let workspaceLayoutPersistenceKey = "editor_workspace_document"
    private static let obsoleteLayoutPersistencePrefixes = [
        "editor_workspace_layout",
        "editor_dock_layout",
    ]
    private static let shellStatePersistenceKey = "editor_shell_state"

    private static func localizedPanelTitle(for id: String) -> String {
        switch id {
        case "hierarchy":
            return L("Hierarchy")
        case "inspector":
            return L("Inspector")
        case "viewport":
            return L("Viewport")
        case "console":
            return L("Console")
        case "assets":
            return L("Assets")
        case "intent-input":
            return L("AI Intent")
        case "confirmation-host":
            return L("Confirmations")
        case "render-pipeline":
            return L("Render Pipeline")
        default:
            return id
        }
    }

    private static func reconciledWorkspaceDocument(_ document: WorkspaceDocument,
                                                    registry: PanelRegistry) -> WorkspaceDocument {
        var next = document
        let registeredIDs = Set(registry.ids)

        for staleID in next.panels.keys where !registeredIDs.contains(staleID) {
            next.panels.removeValue(forKey: staleID)
        }

        for groupID in Array(next.groups.keys) {
            guard var group = next.groups[groupID] else { continue }
            group.panels.removeAll { !registeredIDs.contains($0) }
            if group.panels.isEmpty {
                next.groups.removeValue(forKey: groupID)
                for index in next.regions.indices {
                    next.regions[index].removeGroup(groupID)
                }
                continue
            }
            if let active = group.activePanelID, group.panels.contains(active) {
                group.activePanelID = active
            } else {
                group.activePanelID = group.panels.first
            }
            next.groups[groupID] = group
        }
        next.floatingWindows.removeAll { window in
            next.groups[window.groupID] == nil
        }
        next.closedHistory.removeAll { closed in
            !registeredIDs.contains(closed.panelID)
        }

        for descriptor in registry.descriptors {
            next.panels[descriptor.id] = workspacePanel(for: descriptor)
            guard next.groupContaining(panelID: descriptor.id) == nil else { continue }
            let groupID = defaultGroupID(for: descriptor.preferredRegion)
            var group = next.groups[groupID] ?? WorkspaceTabGroup(id: groupID, panels: [])
            if !group.panels.contains(descriptor.id) {
                group.panels.append(descriptor.id)
            }
            group.activePanelID = group.activePanelID ?? descriptor.id
            next.groups[groupID] = group

            var region = next.region(descriptor.preferredRegion)
            if !region.containsGroup(groupID) {
                region.appendGroup(groupID)
                next.setRegion(region)
            }
        }

        return WorkspaceDocument(panels: next.panels,
                                 groups: next.groups,
                                 regions: next.regions,
                                 floatingWindows: next.floatingWindows,
                                 splitFractions: next.splitFractions,
                                 closedHistory: next.closedHistory)
    }

    private static func workspacePanel(for descriptor: PanelDescriptor) -> WorkspacePanel {
        WorkspacePanel(id: descriptor.id,
                       title: descriptor.title,
                       isClosable: descriptor.closable,
                       isDraggable: true,
                       isCollapsible: descriptor.preferredRegion != .center,
                       iconAssetKey: descriptor.iconAssetKey)
    }

    private static func defaultGroupID(for region: WorkspaceRegionID) -> WorkspaceTabGroupID {
        WorkspaceTabGroupID(rawValue: region.rawValue)
    }

    private static func layoutPersistenceKey(for mode: EditorWorkspaceMode,
                                             preset: EditorLayoutPreset) -> String {
        "\(workspaceLayoutPersistenceKey)_\(mode.rawValue)_\(preset.rawValue)"
    }

    private static func loadSavedWorkspaceDocument(for mode: EditorWorkspaceMode,
                                                   preset: EditorLayoutPreset) -> WorkspaceDocument? {
        discardLegacyWorkspaceLayoutFiles()
        guard let layoutDir = getLayoutPersistenceDirectory() else { return nil }
        let layoutPath = layoutDir.appendingPathComponent(
            layoutPersistenceKey(for: mode, preset: preset) + ".json"
        )

        guard FileManager.default.fileExists(atPath: layoutPath.path) else { return nil }

        do {
            let data = try Data(contentsOf: layoutPath)
            let document = try JSONDecoder().decode(WorkspaceDocument.self, from: data)
            guard document.hasValidLayoutReferences else {
                try? FileManager.default.removeItem(at: layoutPath)
                fputs("[EditorRootViewFactory] discarded obsolete workspace layout: missing layout tree references\n", stderr)
                return nil
            }
            return document
        } catch {
            try? FileManager.default.removeItem(at: layoutPath)
            fputs("[EditorRootViewFactory] discarded invalid workspace layout: \(error)\n", stderr)
            return nil
        }
    }

    private static func saveWorkspaceDocument(_ document: WorkspaceDocument,
                                              for mode: EditorWorkspaceMode,
                                              preset: EditorLayoutPreset) {
        discardLegacyWorkspaceLayoutFiles()
        guard let layoutDir = getLayoutPersistenceDirectory() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(document)
            let path = layoutDir.appendingPathComponent(
                layoutPersistenceKey(for: mode, preset: preset) + ".json"
            )
            try data.write(to: path)
        } catch {
            fputs("[EditorRootViewFactory] failed to save workspace layout: \(error)\n", stderr)
        }
    }

    private static func discardLegacyWorkspaceLayoutFiles() {
        guard let layoutDir = getLayoutPersistenceDirectory(),
              let contents = try? FileManager.default.contentsOfDirectory(at: layoutDir,
                                                                          includingPropertiesForKeys: nil) else {
            return
        }
        for url in contents {
            guard obsoleteLayoutPersistencePrefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) else {
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func getLayoutPersistenceDirectory() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                         in: .userDomainMask).first else {
            return nil
        }
        let guavaDir = appSupport.appendingPathComponent("Guava")
        try? FileManager.default.createDirectory(at: guavaDir, withIntermediateDirectories: true)
        return guavaDir
    }
}

enum EditorWorkspaceDefaults {
    static func makeDocument(mode: EditorWorkspaceMode,
                             preset: EditorLayoutPreset,
                             registry: PanelRegistry) -> WorkspaceDocument {
        let panels = Dictionary(uniqueKeysWithValues: registry.descriptors.map { descriptor in
            (descriptor.id,
             WorkspacePanel(id: descriptor.id,
                            title: descriptor.title,
                            isClosable: descriptor.closable,
                            isDraggable: true,
                            isCollapsible: descriptor.preferredRegion != .center,
                            iconAssetKey: descriptor.iconAssetKey))
        })
        let fractions = defaultFractions(for: preset)
        let groups: [WorkspaceTabGroupID: WorkspaceTabGroup] = [
            "leading": WorkspaceTabGroup(id: "leading", panels: ["hierarchy"], activePanelID: "hierarchy"),
            "center": WorkspaceTabGroup(id: "center", panels: ["viewport"], activePanelID: "viewport"),
            "trailing": WorkspaceTabGroup(id: "trailing", panels: ["inspector"], activePanelID: "inspector"),
            "bottom": WorkspaceTabGroup(id: "bottom",
                                        panels: ["assets",
                                                 "console",
                                                 "intent-input",
                                                 "confirmation-host",
                                                 "render-pipeline"],
                                        activePanelID: defaultBottomPanelID(for: preset))
        ]
        return WorkspaceDocument(
            panels: panels,
            groups: groups,
            regions: [
                WorkspaceRegion(id: .leading, layout: .group("leading")),
                WorkspaceRegion(id: .center, layout: .group("center")),
                WorkspaceRegion(id: .trailing, layout: .group("trailing")),
                WorkspaceRegion(id: .bottom, layout: .group("bottom")),
            ],
            splitFractions: fractions
        )
    }

    private static func defaultFractions(for preset: EditorLayoutPreset) -> WorkspaceSplitFractions {
        switch preset {
        case .levelDefault:
            return WorkspaceSplitFractions(leading: 0.22, centerTrailing: 0.78, topBottom: 0.74)
        case .levelCinematics:
            return WorkspaceSplitFractions(leading: 0.18, centerTrailing: 0.80, topBottom: 0.68)
        case .modelingDefault:
            return WorkspaceSplitFractions(leading: 0.22, centerTrailing: 0.76, topBottom: 0.72)
        case .modelingSculpt:
            return WorkspaceSplitFractions(leading: 0.19, centerTrailing: 0.78, topBottom: 0.72)
        case .animationDefault:
            return WorkspaceSplitFractions(leading: 0.20, centerTrailing: 0.76, topBottom: 0.66)
        case .animationSequencer:
            return WorkspaceSplitFractions(leading: 0.18, centerTrailing: 0.74, topBottom: 0.58)
        }
    }

    private static func defaultBottomPanelID(for preset: EditorLayoutPreset) -> WorkspacePanelID {
        switch preset {
        case .levelDefault, .levelCinematics:
            return "assets"
        case .modelingDefault, .modelingSculpt:
            return "console"
        case .animationDefault, .animationSequencer:
            return "intent-input"
        }
    }
}
