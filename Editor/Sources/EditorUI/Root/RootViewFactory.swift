import GuavaLogging
import EditorCore
import GuavaUI
import GuavaUIRuntime
import GuavaUIWorkspace
import Foundation

enum EditorRootViewFactory {
    struct EditorShellState: Codable, Sendable {
        var themeID = EditorThemeCatalog.defaultThemeID
        var themeMode: EditorThemeMode
        var language: EditorLanguage
        var vsyncMode: EditorVSyncMode
        var primarySelectBehavior: SelectionPrimaryModifierBehavior
        var aiSettings: EditorAISettings
        var capabilitySettings: EditorCapabilitySettings

        init(themeMode: EditorThemeMode = .dark,
             themeID: String = EditorThemeCatalog.defaultThemeID,
             language: EditorLanguage = .system,
             vsyncMode: EditorVSyncMode = .enabled,
             primarySelectBehavior: SelectionPrimaryModifierBehavior = .subtract,
             aiSettings: EditorAISettings = .default,
             capabilitySettings: EditorCapabilitySettings = .default) {
            self.themeMode = themeMode
            self.themeID = themeID
            self.language = language
            self.vsyncMode = vsyncMode
            self.primarySelectBehavior = primarySelectBehavior
            self.aiSettings = aiSettings
            self.capabilitySettings = capabilitySettings
        }

        enum CodingKeys: String, CodingKey {
            case themeMode, themeID
            case language
            case vsyncMode
            case primarySelectBehavior
            case aiSettings
            case capabilitySettings
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(themeMode, forKey: .themeMode)
            try values.encode(themeID, forKey: .themeID)
            try values.encode(language, forKey: .language)
            try values.encode(vsyncMode, forKey: .vsyncMode)
            try values.encode(primarySelectBehavior, forKey: .primarySelectBehavior)
            try values.encode(aiSettings, forKey: .aiSettings)
            try values.encode(capabilitySettings, forKey: .capabilitySettings)
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            themeMode = try values.decodeIfPresent(EditorThemeMode.self, forKey: .themeMode) ?? .dark
            themeID = try values.decodeIfPresent(String.self, forKey: .themeID) ?? themeID
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

    static func makeController(registry: WorkspacePanelRegistry, content: EditorContent = .scene) -> WorkspaceController {
        if let saved = loadSavedWorkspaceDocument() {
            let document = reconciledWorkspaceDocument(saved, registry: registry)
            if document != saved { saveWorkspaceDocument(document) }
            return WorkspaceController(document: document)
        }
        let document = EditorWorkspaceDefaults.makeDocument(registry: registry, content: content)
        saveWorkspaceDocument(document)
        return WorkspaceController(document: document)
    }

    static func resetLayout(into controller: WorkspaceController, registry: WorkspacePanelRegistry) {
        let document = EditorWorkspaceDefaults.makeDocument(registry: registry)
        controller.replace(document)
        saveWorkspaceDocument(document)
    }

    /// A sidebar view opens in the sidebar pane; the inspector and the outline
    /// live in the details pane.
    static func activatePanel(_ requested: WorkspacePanelID, in controller: WorkspaceController) {
        let id = dockedPanel(for: requested, in: controller)
        if EditorContentFollower.isContentPanel(id) { EditorContentFollower.swap(to: id, in: controller) }
        if id == EditorSidebar.panelID, requested != id { EditorSidebar.of(controller).select(requested) }
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

    /// The docked panel that shows `id`: itself, the details pane for the
    /// inspector and outline, or the sidebar pane for a sidebar view.
    static func dockedPanel(for id: WorkspacePanelID, in controller: WorkspaceController) -> WorkspacePanelID {
        let panels = controller.document.panels
        guard panels[id] == nil else { return id }
        if id == "inspector" || id == "outline", panels["details"] != nil { return "details" }
        return panels[EditorSidebar.panelID] != nil ? EditorSidebar.panelID : id
    }

    /// What the window shows for a docked panel. The sidebar pane renders the
    /// view the rail picked.
    static func content(for id: WorkspacePanelID, controller: WorkspaceController,
                        registry: WorkspacePanelRegistry) -> AnyView {
        guard id == EditorSidebar.panelID else { return registry.make(id) }
        return AnyView(EditorSidebarPane(sidebar: .of(controller), registry: registry))
    }

    static func localizeWorkspaceTitles(in controller: WorkspaceController,
                                        registry: WorkspacePanelRegistry) {
        var document = controller.document
        // A package names its own panels; only the host's are translated here.
        for panelID in Array(document.panels.keys) where EditorWorkspaceProfile.builtInPanelIDs.contains(panelID.rawValue) {
            guard var panel = document.panels[panelID] else { continue }
            panel.title = localizedPanelTitle(for: panelID.rawValue)
            document.panels[panelID] = panel
        }
        controller.replace(document)
        localizePanelTitles(in: registry)
    }

    static func localizePanelTitles(in registry: WorkspacePanelRegistry) {
        for id in registry.ids where EditorWorkspaceProfile.builtInPanelIDs.contains(id.rawValue) {
            registry.updateDescriptor(id: id) { descriptor in
                descriptor.panel.title = localizedPanelTitle(for: descriptor.panel.id.rawValue)
            }
        }
    }

    static func makeRegistry(app: EditorApplication) -> WorkspacePanelRegistry {
        registerPanelIcons()
        let terminal = EditorTerminal(projectDirectory: app.projectDirectory)
        terminal.follow(app.workstation.tasks) { app.showPanel("terminal") }
        let registry = WorkspacePanelRegistry([
            WorkspacePanelDescriptor(id: "hierarchy", title: localizedPanelTitle(for: "hierarchy"), defaultSlot: .leading, configure: { $0.isCollapsible = true; $0.iconAssetKey = "panel.hierarchy" }) {
                HierarchyPanel(store: app.store, scene: app.scene)
            },
            WorkspacePanelDescriptor(id: EditorSidebar.panelID, title: localizedPanelTitle(for: "sidebar"), defaultSlot: .leading,
                                     configure: { $0.isCollapsible = true; $0.isClosable = false; $0.hidesTabBarWhenAlone = true }) {
                // The window renders the sidebar itself; see `EditorRootViewFactory.content`.
                EmptyView()
            },
            WorkspacePanelDescriptor(id: "details", title: localizedPanelTitle(for: "details"), defaultSlot: .trailing,
                                     configure: { $0.isCollapsible = true; $0.isClosable = false; $0.hidesTabBarWhenAlone = true; $0.iconAssetKey = "panel.inspector" }) {
                EditorDetailsPanel(app: app) {
                    AnyView(InspectorPanel(store: app.store, scene: app.scene, scriptWorkspace: app.workstation.scripts) { identifier in
                        guard let file = app.workstation.scripts.snapshot.documents.first(where: {
                            $0.file.identifier == identifier || $0.file.legacyIdentifiers.contains(identifier)
                        })?.file else { return }
                        app.navigateToIssue(.script(id: file.identifier, line: 1, column: 1))
                    })
                }
            },
            WorkspacePanelDescriptor(id: "viewport", title: localizedPanelTitle(for: "viewport"), defaultSlot: .center, configure: { $0.isCollapsible = false; $0.isClosable = false; $0.hidesTabBarWhenAlone = true; $0.iconAssetKey = "panel.viewport" }) {
                EditorViewportWorkspacePanel(app: app)
            },
            WorkspacePanelDescriptor(id: "console", title: localizedPanelTitle(for: "console"), defaultSlot: .bottom, configure: { $0.isCollapsible = true; $0.iconAssetKey = "panel.console" }) {
                EditorOutputPanel(app: app)
            },
            WorkspacePanelDescriptor(id: "terminal", title: localizedPanelTitle(for: "terminal"), defaultSlot: .bottom, configure: { $0.isCollapsible = true; $0.iconAssetKey = "panel.terminal" }) {
                EditorTerminalPanel(terminal: terminal)
            },
            WorkspacePanelDescriptor(id: "assets", title: localizedPanelTitle(for: "assets"), defaultSlot: .leading, configure: { $0.isCollapsible = true; $0.iconAssetKey = "panel.assets" }) {
                AssetBrowserPanel(app: app)
            },
            WorkspacePanelDescriptor(id: "render-pipeline", title: localizedPanelTitle(for: "render-pipeline"), defaultSlot: .bottom, configure: { $0.isCollapsible = true; $0.iconAssetKey = "panel.render-pipeline" }) {
                RenderPipelinePanel(app: app)
            },
            WorkspacePanelDescriptor(id: "animation", title: localizedPanelTitle(for: "animation"), defaultSlot: .bottom, configure: { $0.isCollapsible = true; $0.iconAssetKey = "panel.animation" }) {
                InspectorPanel(store: app.store, scene: app.scene,
                               sectionFilter: ["animation-player", "animation-graph-player"])
            },
            WorkspacePanelDescriptor(id: "developer-tools", title: localizedPanelTitle(for: "developer-tools"), defaultSlot: .bottom, configure: { $0.isCollapsible = true; $0.iconAssetKey = "panel.developer-tools" }) {
                DeveloperToolsPanel(app: app)
            },
            WorkspacePanelDescriptor(id: "files", title: localizedPanelTitle(for: "files"), defaultSlot: .leading, configure: { $0.isCollapsible = true; $0.iconAssetKey = "panel.files" }) {
                DocumentFilesPanel(model: app.workstation.documents, app: app)
            },
            WorkspacePanelDescriptor(id: "source-control", title: localizedPanelTitle(for: "source-control"), defaultSlot: .leading, configure: { $0.isCollapsible = true; $0.iconAssetKey = "panel.source-control" }) {
                SourceControlPanel(app: app)
            },
            WorkspacePanelDescriptor(id: "tasks", title: localizedPanelTitle(for: "tasks"), defaultSlot: .leading, configure: { $0.isCollapsible = true; $0.iconAssetKey = "panel.tasks" }) {
                TasksPanel(app: app)
            },
            WorkspacePanelDescriptor(id: "documents", title: localizedPanelTitle(for: "documents"), defaultSlot: .center, configure: { $0.iconAssetKey = "panel.documents"; $0.hidesTabBarWhenAlone = true }) {
                DocumentsPanel(model: app.workstation.documents, app: app, onOpenFile: {
                    app.store.dispatch(.setCommandPaletteQuery(TextBuffer(EditorPaletteScope.resources.prefix)))
                    app.store.dispatch(.setCommandPaletteVisible(true))
                })
            },
            WorkspacePanelDescriptor(id: "media", title: localizedPanelTitle(for: "media"), defaultSlot: .center,
                                     configure: { $0.hidesTabBarWhenAlone = true }) {
                MediaTimelinePanel(model: app.workstation.media, projectRoot: URL(fileURLWithPath: app.projectDirectory))
            },
        ])
        syncContributedPanels(app: app, registry: registry)
        return registry
    }

    /// Registers the panels enabled packages contribute and drops the ones that
    /// left. A panel whose tab is unchanged keeps its descriptor, so its view
    /// keeps its state; the view itself follows the package's current content.
    static func syncContributedPanels(app: EditorApplication, registry: WorkspacePanelRegistry) {
        // The agent view is the window's session column, never a docked panel.
        let panels = app.workbenchCatalog.panels.filter { $0.content == .model }
        for id in registry.ids where !EditorWorkspaceProfile.builtInPanelIDs.contains(id.rawValue)
            && !panels.contains(where: { $0.id == id.rawValue }) {
            registry.unregister(id: id)
        }
        for panel in panels {
            let id = WorkspacePanelID(rawValue: panel.id)
            let iconKey = panel.icon.map { "panel." + $0 }
            if let iconKey, let icon = panel.icon {
                WorkspacePanelIconCatalog.register(iconKey, .svg(named: icon, in: EditorAppResourceBundle.bundle, subdirectory: "PanelIcons"))
            }
            let slot = WorkspaceSlotID(rawValue: panel.slot)
            // A host view's title is the host's, so it reads in the UI language; a package's own stays as written.
            let title = panel.content == .model ? panel.title : L(panel.title)
            if let existing = registry.descriptor(for: id), existing.panel.title == title,
               existing.panel.iconAssetKey == iconKey, existing.defaultSlot == slot {
                continue
            }
            registry.register(WorkspacePanelDescriptor(id: id, title: title, defaultSlot: slot,
                                                       configure: { $0.isCollapsible = true; $0.iconAssetKey = iconKey }) {
                if let current = app.workbenchCatalog.panel(id: panel.id) {
                    PluginView(session: MainActor.assumeIsolated { app.viewSession(for: current) })
                }
            })
        }
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
        WorkspacePanelIconCatalog.register("panel.assets", panelIcon("package", subdirectory: "ToolbarIcons"))
        WorkspacePanelIconCatalog.register("panel.render-pipeline", panelIcon("render"))
        WorkspacePanelIconCatalog.register("panel.animation", panelIcon("render"))
        WorkspacePanelIconCatalog.register("panel.developer-tools", panelIcon("warning"))
        WorkspacePanelIconCatalog.register("panel.profiler", panelIcon("profiler"))
        WorkspacePanelIconCatalog.register("panel.files", UIIcons.File.folder)
        WorkspacePanelIconCatalog.register("panel.terminal", UIIcons.Editor.terminal)
        WorkspacePanelIconCatalog.register("panel.documents", UIIcons.File.fileCode)
        WorkspacePanelIconCatalog.register("panel.source-control", UIIcons.Editor.gitBranch)
        WorkspacePanelIconCatalog.register("panel.outline", UIIcons.Text.heading)
        WorkspacePanelIconCatalog.register("panel.tasks", UIIcons.Editor.box)
    }

    static func saveWorkspaceLayout(_ controller: WorkspaceController) {
        saveWorkspaceDocument(controller.document)
    }

    static func saveShellState(themeMode: EditorThemeMode,
                               themeID: String = EditorThemeCatalog.defaultThemeID,
                               language: EditorLanguage,
                               vsyncMode: EditorVSyncMode,
                               primarySelectBehavior: SelectionPrimaryModifierBehavior = .subtract,
                               aiSettings: EditorAISettings = .default,
                               capabilitySettings: EditorCapabilitySettings = .default) {
        guard let layoutDir = getLayoutPersistenceDirectory() else { return }
        let shell = EditorShellState(themeMode: themeMode,
                                     themeID: themeID,
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
            LogSystem.logger("com.guava.editor.persistence").error("[EditorRootViewFactory] failed to save shell state: \(error)")
        }
    }

    static func loadShellState() -> EditorShellState? {
        guard let layoutDir = getLayoutPersistenceDirectory() else { return nil }
        let path = layoutDir.appendingPathComponent(shellStatePersistenceKey + ".json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }

        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            return try decoder.decode(EditorShellState.self, from: data)
        } catch {
            quarantinePersistenceFile(at: path,
                                      label: "shell state",
                                      reason: String(describing: error))
            LogSystem.logger("com.guava.editor.persistence").error("[EditorRootViewFactory] failed to load shell state: \(error)")
            return nil
        }
    }

    private static let workspaceLayoutPersistenceKey = "editor_workspace_document"
    private static let obsoleteLayoutPersistencePrefixes = [
        "editor_workspace_layout",
        "editor_dock_layout",
    ]
    private static let shellStatePersistenceKey = "editor_shell_state"

    static func localizedPanelTitle(for id: String) -> String {
        switch id {
        case "hierarchy":
            return L("Outline")
        case "details":
            return L("Properties")
        case "viewport":
            return L("Scene")
        case "console":
            return L("Console")
        case "terminal":
            return L("Terminal")
        case "assets":
            return L("Assets")
        case "render-pipeline":
            return L("Render Pipeline")
        case "developer-tools":
            return L("Developer Tools")
        case "profiler":
            return L("Profiler")
        case "animation":
            return L("Animation")
        case "files":
            return L("Files")
        case "documents":
            return L("Editor")
        case "media":
            return L("Video Editing")
        case "source-control":
            return L("Source Control")
        case "sidebar":
            return L("Sidebar")
        case "tasks":
            return L("Tasks")
        default:
            return id
        }
    }

    static func reconciledWorkspaceDocument(_ document: WorkspaceDocument,
                                            registry: WorkspacePanelRegistry) -> WorkspaceDocument {
        var next = document
        next.ensureStandardEditorSlotSchema()
        // Sidebar views show through the sidebar pane, never as docked tabs.
        let docked = registry.descriptors.filter { !EditorSidebar.isView($0) }
        let registeredIDs = Set(docked.map(\.panel.id))

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

        // The center shows one kind of content at a time: scene, code or timeline.
        for groupID in Array(next.groups.keys) {
            guard var group = next.groups[groupID] else { continue }
            let contents = group.panels.filter(EditorContentFollower.isContentPanel)
            guard contents.count > 1 else { continue }
            let kept = group.activePanelID.flatMap { contents.contains($0) ? $0 : nil } ?? contents[0]
            group.panels.removeAll { EditorContentFollower.isContentPanel($0) && $0 != kept }
            next.groups[groupID] = group
        }

        for descriptor in docked {
            next.panels[descriptor.panel.id] = workspacePanel(for: descriptor)
            guard next.groupContaining(panelID: descriptor.panel.id) == nil,
                  !EditorContentFollower.isPlacedByContent(descriptor.panel.id) else { continue }
            // A panel intentionally closed by the user remains represented in
            // `closedHistory`. Reattaching it here made panel closure appear to
            // work only until the next launch. Descriptors with no history are
            // genuinely new panels and should still be added automatically.
            guard !next.closedHistory.contains(where: { $0.panelID == descriptor.panel.id }) else {
                continue
            }
            let groupID = defaultGroupID(for: descriptor.defaultSlot)
            var group = next.groups[groupID] ?? WorkspaceTabGroup(id: groupID, panels: [])
            if !group.panels.contains(descriptor.panel.id) {
                group.panels.append(descriptor.panel.id)
            }
            group.activePanelID = group.activePanelID ?? descriptor.panel.id
            next.groups[groupID] = group

            var slot = next.slot(descriptor.defaultSlot)
            if !slot.containsGroup(groupID) {
                slot.appendGroup(groupID)
                next.setSlot(slot)
            }
        }
        if !next.groups.values.contains(where: { $0.panels.contains(where: EditorContentFollower.isContentPanel) }),
           let first = docked.first(where: { EditorContentFollower.isContentPanel($0.panel.id) })?.panel.id {
            var group = next.groups["center"] ?? WorkspaceTabGroup(id: "center", panels: [])
            group.panels.insert(first, at: 0)
            group.activePanelID = first
            next.groups["center"] = group
            var slot = next.slot(.center)
            if !slot.containsGroup("center") {
                slot.appendGroup("center")
                next.setSlot(slot)
            }
        }

        return WorkspaceDocument(panels: next.panels,
                                 groups: next.groups,
                                 slots: next.slots,
                                 collapsed: next.collapsed,
                                 floatingWindows: next.floatingWindows,
                                 splitFractions: next.splitFractions,
                                 closedHistory: next.closedHistory)
    }

    private static func workspacePanel(for descriptor: WorkspacePanelDescriptor) -> WorkspacePanel {
        descriptor.panel
    }

    private static func defaultGroupID(for slot: WorkspaceSlotID) -> WorkspaceTabGroupID {
        WorkspaceTabGroupID(rawValue: slot.rawValue)
    }

    private static func loadSavedWorkspaceDocument() -> WorkspaceDocument? {
        discardLegacyWorkspaceLayoutFiles()
        guard let layoutDir = getLayoutPersistenceDirectory() else { return nil }
        let layoutPath = layoutDir.appendingPathComponent(
            workspaceLayoutPersistenceKey + ".json"
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

    private static func saveWorkspaceDocument(_ document: WorkspaceDocument) {
        discardLegacyWorkspaceLayoutFiles()
        guard let layoutDir = getLayoutPersistenceDirectory() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(document)
            let path = layoutDir.appendingPathComponent(
                workspaceLayoutPersistenceKey + ".json"
            )
            try data.write(to: path, options: .atomic)
        } catch {
            LogSystem.logger("com.guava.editor.persistence").error("[EditorRootViewFactory] failed to save workspace layout: \(error)")
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
            LogSystem.logger("com.guava.editor.persistence").error("[EditorRootViewFactory] failed to create persistence directory: \(error)")
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
            LogSystem.logger("com.guava.editor.persistence").error("[EditorRootViewFactory] moved invalid \(label) to \(quarantineURL.lastPathComponent): \(reason)")
            return quarantineURL
        } catch {
            LogSystem.logger("com.guava.editor.persistence").error("[EditorRootViewFactory] invalid \(label) could not be quarantined and was preserved at \(url.path): \(error); original error: \(reason)")
            return nil
        }
    }
}
