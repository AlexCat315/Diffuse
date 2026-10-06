import EditorCore
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
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
        var aiSettings: EditorAISettings
        var capabilitySettings: EditorCapabilitySettings

        init(workspaceMode: EditorWorkspaceMode,
             activeLayoutPreset: EditorLayoutPreset,
             themeMode: EditorThemeMode = .dark,
             language: EditorLanguage = .system,
             vsyncMode: EditorVSyncMode = .enabled,
             primarySelectBehavior: SelectionPrimaryModifierBehavior = .subtract,
             aiSettings: EditorAISettings = .default,
             capabilitySettings: EditorCapabilitySettings = .default) {
            self.workspaceMode = workspaceMode
            self.activeLayoutPreset = activeLayoutPreset
            self.themeMode = themeMode
            self.language = language
            self.vsyncMode = vsyncMode
            self.primarySelectBehavior = primarySelectBehavior
            self.aiSettings = aiSettings
            self.capabilitySettings = capabilitySettings
        }

        enum CodingKeys: String, CodingKey {
            case workspaceMode
            case activeLayoutPreset
            case themeMode
            case language
            case vsyncMode
            case primarySelectBehavior
            case aiSettings
            case capabilitySettings
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(workspaceMode, forKey: .workspaceMode)
            try values.encode(activeLayoutPreset, forKey: .activeLayoutPreset)
            try values.encode(themeMode, forKey: .themeMode)
            try values.encode(language, forKey: .language)
            try values.encode(vsyncMode, forKey: .vsyncMode)
            try values.encode(primarySelectBehavior, forKey: .primarySelectBehavior)
            try values.encode(aiSettings, forKey: .aiSettings)
            try values.encode(capabilitySettings, forKey: .capabilitySettings)
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
            aiSettings = try values.decodeIfPresent(EditorAISettings.self, forKey: .aiSettings) ?? .default
            capabilitySettings = try values.decodeIfPresent(
                EditorCapabilitySettings.self,
                forKey: .capabilitySettings
            ) ?? .default
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
        if let maximized = controller.maximizedPanelID, maximized != id {
            _ = controller.dispatch(.restoreMaximized)
        }
        if controller.document.groupContaining(panelID: id) == nil {
            _ = controller.dispatch(.reopenPanel(id))
        }
        guard let group = controller.document.groupContaining(panelID: id) else { return }
        if group.isCollapsed { _ = controller.dispatch(.expand(group.id)) }
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
        registerPanelIcons()
        return PanelRegistry([
            PanelDescriptor(id: "hierarchy",
                            title: localizedPanelTitle(for: "hierarchy"),
                            preferredSlot: .leading,
                            iconAssetKey: "panel.hierarchy") {
                HierarchyPanel(store: app.store, scene: app.scene)
            },
            PanelDescriptor(id: "inspector",
                            title: localizedPanelTitle(for: "inspector"),
                            preferredSlot: .trailing,
                            iconAssetKey: "panel.inspector") {
                InspectorPanel(store: app.store, scene: app.scene, scriptWorkspace: app.scriptWorkspace) { identifier in
                    guard let file = app.scriptWorkspace.snapshot.documents.first(where: {
                        $0.file.identifier == identifier || $0.file.legacyIdentifiers.contains(identifier)
                    })?.file else { return }
                    app.navigateToIssue(.script(id: file.identifier, line: 1, column: 1))
                }
            },
            PanelDescriptor(id: "viewport",
                            title: localizedPanelTitle(for: "viewport"),
                            closable: false,
                            preferredSlot: .center,
                            iconAssetKey: "panel.viewport") {
                EditorViewportWorkspacePanel(app: app)
            },
            PanelDescriptor(id: "console",
                            title: localizedPanelTitle(for: "console"),
                            preferredSlot: .bottom,
                            iconAssetKey: "panel.console") {
                EditorOutputPanel(app: app)
            },
            PanelDescriptor(id: "assets",
                            title: localizedPanelTitle(for: "assets"),
                            preferredSlot: .bottom,
                            iconAssetKey: "panel.assets") {
                AssetBrowserPanel(app: app)
            },
            PanelDescriptor(id: "intent-input",
                            title: localizedPanelTitle(for: "intent-input"),
                            preferredSlot: .trailing,
                            iconAssetKey: "panel.intent-input") {
                IntentInputPanel(app: app)
            },
            PanelDescriptor(id: "confirmation-host",
                            title: localizedPanelTitle(for: "confirmation-host"),
                            preferredSlot: .bottom,
                            iconAssetKey: "panel.confirmation-host") {
                ConfirmationHostPanel(app: app)
            },
            PanelDescriptor(id: "render-pipeline",
                            title: localizedPanelTitle(for: "render-pipeline"),
                            preferredSlot: .bottom,
                            iconAssetKey: "panel.render-pipeline") {
                RenderPipelinePanel(app: app)
            },
            PanelDescriptor(id: "animation", title: L("Animation"), preferredSlot: .bottom,
                            iconAssetKey: "panel.animation") {
                InspectorPanel(store: app.store, scene: app.scene,
                               sectionFilter: ["animation-player", "animation-graph-player"])
            },
            PanelDescriptor(id: "developer-tools",
                            title: localizedPanelTitle(for: "developer-tools"),
                            preferredSlot: .bottom,
                            iconAssetKey: "panel.developer-tools") {
                DeveloperToolsPanel(app: app)
            },
            PanelDescriptor(id: "scripts",
                            title: localizedPanelTitle(for: "scripts"),
                            preferredSlot: .center,
                            iconAssetKey: "panel.scripts") {
                ScriptPanel(app: app)
            },
        ])
    }

    private static func registerPanelIcons() {
        func panelIcon(_ name: String, subdirectory: String = "PanelIcons") -> BundleImageResource {
            .svg(named: name,
                 in: EditorAppResourceBundle.bundle,
                 subdirectory: subdirectory)
        }
        WorkspacePanelIconCatalog.register("panel.hierarchy", panelIcon("hierarchy"))
        WorkspacePanelIconCatalog.register("panel.inspector", panelIcon("inspector"))
        WorkspacePanelIconCatalog.register("panel.viewport", panelIcon("globe", subdirectory: "ToolbarIcons"))
        WorkspacePanelIconCatalog.register("panel.console", panelIcon("console"))
        WorkspacePanelIconCatalog.register("panel.assets", panelIcon("folder", subdirectory: "ToolbarIcons"))
        WorkspacePanelIconCatalog.register("panel.intent-input", panelIcon("ai-intent"))
        WorkspacePanelIconCatalog.register("panel.confirmation-host", panelIcon("confirmations"))
        WorkspacePanelIconCatalog.register("panel.render-pipeline", panelIcon("render"))
        WorkspacePanelIconCatalog.register("panel.animation", panelIcon("render"))
        WorkspacePanelIconCatalog.register("panel.developer-tools", panelIcon("warning"))
        WorkspacePanelIconCatalog.register("panel.profiler", panelIcon("profiler"))
        WorkspacePanelIconCatalog.register("panel.scripts", panelIcon("script"))
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
                               primarySelectBehavior: SelectionPrimaryModifierBehavior = .subtract,
                               aiSettings: EditorAISettings = .default,
                               capabilitySettings: EditorCapabilitySettings = .default) {
        guard let layoutDir = getLayoutPersistenceDirectory() else { return }
        let shell = EditorShellState(workspaceMode: mode,
                                     activeLayoutPreset: preset,
                                     themeMode: themeMode,
                                     language: language,
                                     vsyncMode: vsyncMode,
                                     primarySelectBehavior: primarySelectBehavior,
                                     aiSettings: aiSettings,
                                     capabilitySettings: capabilitySettings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(shell)
            let path = layoutDir.appendingPathComponent(shellStatePersistenceKey + ".json")
            try data.write(to: path, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("[EditorRootViewFactory] failed to save shell state: \(error)\n".utf8))
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
            quarantinePersistenceFile(at: path,
                                      label: "shell state",
                                      reason: String(describing: error))
            FileHandle.standardError.write(Data("[EditorRootViewFactory] failed to load shell state: \(error)\n".utf8))
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
            return L("AI")
        case "confirmation-host":
            return L("Confirmations")
        case "render-pipeline":
            return L("Render Pipeline")
        case "developer-tools":
            return L("Developer Tools")
        case "profiler":
            return L("Profiler")
        case "scripts":
            return L("Scripts")
        case "animation":
            return L("Animation")
        default:
            return id
        }
    }

    static func reconciledWorkspaceDocument(_ document: WorkspaceDocument,
                                            registry: PanelRegistry) -> WorkspaceDocument {
        var next = document
        next.ensureStandardEditorSlotSchema()
        let registeredIDs = Set(registry.ids)

        // Migrate the redundant profiler tab into Developer Tools while
        // preserving the user's active panel in saved layouts.
        if !registeredIDs.contains("profiler"), registeredIDs.contains("developer-tools") {
            let orderedGroups = next.groups.keys.sorted { $0.rawValue < $1.rawValue }
            let preferredGroup = orderedGroups.first { next.groups[$0]?.activePanelID == "profiler" }
                ?? orderedGroups.first { next.groups[$0]?.panels.contains("developer-tools") == true }
                ?? orderedGroups.first { next.groups[$0]?.panels.contains("profiler") == true }
            for groupID in orderedGroups {
                guard var group = next.groups[groupID], group.panels.contains("profiler") else { continue }
                group.panels = group.panels.map { $0 == "profiler" ? "developer-tools" : $0 }
                    .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
                if group.activePanelID == "profiler" { group.activePanelID = "developer-tools" }
                next.groups[groupID] = group
            }
            // A panel can only occupy one group; prioritize the active profiler.
            for groupID in orderedGroups {
                guard var group = next.groups[groupID], group.panels.contains("developer-tools") else { continue }
                if groupID != preferredGroup { group.panels.removeAll { $0 == "developer-tools" } }
                next.groups[groupID] = group
            }
        }

        for staleID in Array(next.panels.keys) where !registeredIDs.contains(staleID) {
            next.panels.removeValue(forKey: staleID)
        }

        for groupID in Array(next.groups.keys) {
            guard var group = next.groups[groupID] else { continue }
            group.panels.removeAll { !registeredIDs.contains($0) }
            if group.panels.isEmpty {
                next.groups.removeValue(forKey: groupID)
                for slotID in Array(next.slots.keys) {
                    next.slots[slotID]?.removeGroup(groupID)
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
            // A panel intentionally closed by the user remains represented in
            // `closedHistory`. Reattaching it here made panel closure appear to
            // work only until the next launch. Descriptors with no history are
            // genuinely new panels and should still be added automatically.
            guard !next.closedHistory.contains(where: { $0.panelID == descriptor.id }) else {
                continue
            }
            let groupID = defaultGroupID(for: descriptor.preferredSlot)
            var group = next.groups[groupID] ?? WorkspaceTabGroup(id: groupID, panels: [])
            if !group.panels.contains(descriptor.id) {
                group.panels.append(descriptor.id)
            }
            group.activePanelID = group.activePanelID ?? descriptor.id
            next.groups[groupID] = group

            var slot = next.slot(descriptor.preferredSlot)
            if !slot.containsGroup(groupID) {
                slot.appendGroup(groupID)
                next.setSlot(slot)
            }
        }

        return WorkspaceDocument(panels: next.panels,
                                 groups: next.groups,
                                 slots: next.slots,
                                 layoutTree: next.layoutTree,
                                 collapsed: next.collapsed,
                                 floatingWindows: next.floatingWindows,
                                 splitFractions: next.splitFractions,
                                 closedHistory: next.closedHistory)
    }

    private static func workspacePanel(for descriptor: PanelDescriptor) -> WorkspacePanel {
        WorkspacePanel(id: descriptor.id,
                       title: descriptor.title,
                       isClosable: descriptor.closable,
                       isDraggable: true,
                       isCollapsible: descriptor.preferredSlot != .center,
                       iconAssetKey: descriptor.iconAssetKey)
    }

    private static func defaultGroupID(for slot: WorkspaceSlotID) -> WorkspaceTabGroupID {
        WorkspaceTabGroupID(rawValue: slot.rawValue)
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
                quarantinePersistenceFile(at: layoutPath,
                                          label: "workspace layout",
                                          reason: "missing layout tree references")
                return nil
            }
            return document
        } catch {
            quarantinePersistenceFile(at: layoutPath,
                                      label: "workspace layout",
                                      reason: String(describing: error))
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
            try data.write(to: path, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("[EditorRootViewFactory] failed to save workspace layout: \(error)\n".utf8))
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
        // Isolate visual QA and automated runs from a developer's saved docks.
        if let override = ProcessInfo.processInfo.environment["GUAVA_EDITOR_STATE_DIRECTORY"],
           !override.isEmpty {
            let directory = URL(fileURLWithPath: override, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return directory
            } catch {
                return nil
            }
        }
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                         in: .userDomainMask).first else {
            return nil
        }
        let guavaDir = appSupport.appendingPathComponent("Guava")
        do {
            try FileManager.default.createDirectory(at: guavaDir, withIntermediateDirectories: true)
            return guavaDir
        } catch {
            FileHandle.standardError.write(Data("[EditorRootViewFactory] failed to create persistence directory: \(error)\n".utf8))
            return nil
        }
    }

    /// Retains invalid user state for diagnostics instead of deleting it. An
    /// absent return means the original file was preserved because quarantine
    /// itself failed.
    @discardableResult
    static func quarantinePersistenceFile(at url: URL,
                                          label: String,
                                          reason: String) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        let quarantineURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(stem).corrupt-\(UUID().uuidString)\(suffix)")
        do {
            try FileManager.default.moveItem(at: url, to: quarantineURL)
            FileHandle.standardError.write(Data("[EditorRootViewFactory] moved invalid \(label) to \(quarantineURL.lastPathComponent): \(reason)\n".utf8))
            return quarantineURL
        } catch {
            FileHandle.standardError.write(Data("[EditorRootViewFactory] invalid \(label) could not be quarantined and was preserved at \(url.path): \(error); original error: \(reason)\n".utf8))
            return nil
        }
    }
}
