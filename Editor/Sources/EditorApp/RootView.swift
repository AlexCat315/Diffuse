import EditorCore
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import Foundation

/// 编辑器根视图。装配 `DockController` + `PanelRegistry` + 一个三列 `PanelWorkspace`。
struct EditorRootView: View {
    let app: EditorApplication
    let controller: DockController
    let registry: PanelRegistry

    var body: some View {
        StoreScope(app.store) { store in
            let setPlaybackState: (PlaybackState) -> Void = { next in
                if store.state.playbackState != next {
                    store.dispatch(.setPlaybackState(next))
                }
            }

            let setWorkspaceMode: (EditorWorkspaceMode) -> Void = { next in
                guard store.state.workspaceMode != next else { return }
                let previous = store.state.workspaceMode
                let previousPreset = store.state.activeLayoutPreset
                EditorRootViewFactory.saveDockLayout(controller,
                                                     for: previous,
                                                     preset: previousPreset)
                store.dispatch(.setWorkspaceMode(next))
                let nextPreset = store.state.activeLayoutPreset
                EditorRootViewFactory.loadLayoutPreset(into: controller,
                                                      for: next,
                                                      preset: nextPreset)
                EditorRootViewFactory.saveShellState(mode: next,
                                                     preset: nextPreset)
            }

            let setLayoutPreset: (EditorLayoutPreset) -> Void = { nextPreset in
                guard nextPreset != store.state.activeLayoutPreset else { return }
                let mode = store.state.workspaceMode
                let previousPreset = store.state.activeLayoutPreset
                EditorRootViewFactory.saveDockLayout(controller,
                                                     for: mode,
                                                     preset: previousPreset)
                store.dispatch(.setActiveLayoutPreset(nextPreset))
                EditorRootViewFactory.loadLayoutPreset(into: controller,
                                                      for: mode,
                                                      preset: nextPreset)
                EditorRootViewFactory.saveShellState(mode: mode,
                                                     preset: nextPreset)
            }

            let resetLayout: () -> Void = {
                let mode = store.state.workspaceMode
                let defaultPreset = EditorLayoutPreset.default(for: mode)
                store.dispatch(.setActiveLayoutPreset(defaultPreset))
                EditorRootViewFactory.resetLayout(into: controller, for: mode)
                EditorRootViewFactory.saveShellState(mode: mode,
                                                     preset: defaultPreset)
            }

            let dispatchMenuCommand: (EditorMenuCommand) -> Void = { command in
                switch command {
                case .newScene:
                    store.dispatch(.setAIStatusMessage("New Scene command is not wired yet."))
                case .openScene:
                    store.dispatch(.setAIStatusMessage("Open Scene command is not wired yet."))
                case .saveScene:
                    store.dispatch(.setAIStatusMessage("Save Scene command is not wired yet."))
                case .importAssets:
                    store.dispatch(.setAIStatusMessage("Import Assets command is not wired yet."))
                case .undo:
                    store.dispatch(.setAIStatusMessage("Undo command is not wired yet."))
                case .redo:
                    store.dispatch(.setAIStatusMessage("Redo command is not wired yet."))
                case .setWorkspaceMode(let mode):
                    setWorkspaceMode(mode)
                case .setLayoutPreset(let preset):
                    setLayoutPreset(preset)
                case .resetLayout:
                    resetLayout()
                case .setPlaybackState(let state):
                    setPlaybackState(state)
                case .openSettings:
                    store.dispatch(.setAIStatusMessage("Settings panel is not wired yet."))
                case .toggleTheme:
                    store.dispatch(.setAIStatusMessage("Theme switching is not wired yet."))
                case .buildProject:
                    store.dispatch(.setAIStatusMessage("Build command is not wired yet."))
                case .buildAndRun:
                    store.dispatch(.setAIStatusMessage("Build and Run command is not wired yet."))
                case .openDocumentation:
                    store.dispatch(.setAIStatusMessage("Documentation link is not wired yet."))
                case .about:
                    store.dispatch(.setAIStatusMessage("Guava Editor (GuavaUI shell prototype)."))
                }
            }

            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                EditorMenuBar(workspaceMode: store.state.workspaceMode,
                              activeLayoutPreset: store.state.activeLayoutPreset,
                              onCommand: dispatchMenuCommand)
                Divider()

                EditorMainToolbar(playbackState: store.state.playbackState,
                                  workspaceMode: store.state.workspaceMode,
                                  activeLayoutPreset: store.state.activeLayoutPreset,
                                  onSetPlaybackState: setPlaybackState,
                                  onSetWorkspaceMode: setWorkspaceMode,
                                  onSetLayoutPreset: setLayoutPreset,
                                  onResetLayout: resetLayout)
                Divider()

                PanelWorkspace(controller: controller,
                               registry: registry,
                               semantics: .ide)
                    .flex()

                Divider()
                EditorStatusBar(isConnected: store.state.connected,
                                sceneRevision: store.state.sceneRevision,
                                selectedCount: store.state.selectedEntityIDs.count,
                                aiStatusMessage: store.state.aiStatusMessage)
            }
            .appearance(.dark)
            .flex()
        }
    }
}

private struct EditorMenuBar: View {
    let workspaceMode: EditorWorkspaceMode
    let activeLayoutPreset: EditorLayoutPreset
    let onCommand: (EditorMenuCommand) -> Void

    var body: some View {
        Row(alignment: .center, spacing: 2) {
            Text(L("Guava Make"))
                .font(.bodyStrong)
                .foregroundColor(.onSurface)
                .padding(horizontal: 10, vertical: 6)

            EditorMenuItem(title: "File",
                           menuWidth: 220,
                           entries: fileEntries,
                           onCommand: onCommand)
            EditorMenuItem(title: "Edit",
                           menuWidth: 200,
                           entries: editEntries,
                           onCommand: onCommand)
            EditorMenuItem(title: "Window",
                           menuWidth: 240,
                           entries: windowEntries,
                           onCommand: onCommand)
            EditorMenuItem(title: "Tools",
                           menuWidth: 200,
                           entries: toolsEntries,
                           onCommand: onCommand)
            EditorMenuItem(title: "Build",
                           menuWidth: 200,
                           entries: buildEntries,
                           onCommand: onCommand)
            EditorMenuItem(title: "Help",
                           menuWidth: 220,
                           entries: helpEntries,
                           onCommand: onCommand)

            Spacer(minLength: 0)

            Text(L("Settings"))
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)
                .padding(horizontal: 10, vertical: 6)
        }
        .padding(horizontal: 8, vertical: 2)
        .background(.surface)
    }

    private var fileEntries: [EditorMenuEntry] {
        [
            .item("new-scene", "New Scene", "⌘N", .newScene),
            .item("open-scene", "Open Scene...", "⌘O", .openScene),
            .item("save-scene", "Save Scene", "⌘S", .saveScene),
            .separator("file-sep-1"),
            .item("import-assets", "Import Assets...", nil, .importAssets),
        ]
    }

    private var editEntries: [EditorMenuEntry] {
        [
            .item("undo", "Undo", "⌘Z", .undo),
            .item("redo", "Redo", "⇧⌘Z", .redo),
            .separator("edit-sep-1"),
            .item("settings", "Settings", "⌘,", .openSettings),
        ]
    }

    private var windowEntries: [EditorMenuEntry] {
        [
            .item("workspace-level", workspaceTitle(for: .level), nil, .setWorkspaceMode(.level)),
            .item("workspace-modeling", workspaceTitle(for: .modeling), nil, .setWorkspaceMode(.modeling)),
            .item("workspace-animation", workspaceTitle(for: .animation), nil, .setWorkspaceMode(.animation)),
            .separator("window-sep-1"),
            .item("preset-level-default", presetTitle(.levelDefault), nil, .setLayoutPreset(.levelDefault)),
            .item("preset-level-cine", presetTitle(.levelCinematics), nil, .setLayoutPreset(.levelCinematics)),
            .item("preset-modeling-default", presetTitle(.modelingDefault), nil, .setLayoutPreset(.modelingDefault)),
            .item("preset-modeling-sculpt", presetTitle(.modelingSculpt), nil, .setLayoutPreset(.modelingSculpt)),
            .item("preset-animation-default", presetTitle(.animationDefault), nil, .setLayoutPreset(.animationDefault)),
            .item("preset-animation-seq", presetTitle(.animationSequencer), nil, .setLayoutPreset(.animationSequencer)),
            .separator("window-sep-2"),
            .item("reset-layout", "Reset Layout", nil, .resetLayout),
        ]
    }

    private var toolsEntries: [EditorMenuEntry] {
        [
            .item("play", playbackTitle(for: .playing), nil, .setPlaybackState(.playing)),
            .item("pause", playbackTitle(for: .paused), nil, .setPlaybackState(.paused)),
            .item("stop", playbackTitle(for: .stopped), nil, .setPlaybackState(.stopped)),
            .separator("tools-sep-1"),
            .item("toggle-theme", "Toggle Theme", nil, .toggleTheme),
        ]
    }

    private var buildEntries: [EditorMenuEntry] {
        [
            .item("build-project", "Build Editor", nil, .buildProject),
            .item("build-run", "Build and Run", nil, .buildAndRun),
        ]
    }

    private var helpEntries: [EditorMenuEntry] {
        [
            .item("open-docs", "Documentation", nil, .openDocumentation),
            .separator("help-sep-1"),
            .item("about", "About Guava", nil, .about),
        ]
    }

    private func workspaceTitle(for mode: EditorWorkspaceMode) -> String {
        let marker = workspaceMode == mode ? "✓" : "  "
        switch mode {
        case .level:
            return "\(marker) Workspace: Level"
        case .modeling:
            return "\(marker) Workspace: Modeling"
        case .animation:
            return "\(marker) Workspace: Animation"
        }
    }

    private func presetTitle(_ preset: EditorLayoutPreset) -> String {
        let marker = activeLayoutPreset == preset ? "✓" : "  "
        return "\(marker) \(preset.title)"
    }

    private func playbackTitle(for state: PlaybackState) -> String {
        switch state {
        case .playing:
            return "Play"
        case .paused:
            return "Pause"
        case .stopped:
            return "Stop"
        }
    }
}

private struct EditorMenuItem: View {
    let title: String
    let menuWidth: Float
    let entries: [EditorMenuEntry]
    let onCommand: (EditorMenuCommand) -> Void
    @State private var isPresented: Bool = false

    init(title: String,
         menuWidth: Float,
         entries: [EditorMenuEntry],
         onCommand: @escaping (EditorMenuCommand) -> Void) {
        self.title = title
        self.menuWidth = menuWidth
        self.entries = entries
        self.onCommand = onCommand
        _isPresented = State(wrappedValue: false)
    }

    var body: some View {
        Popover(isPresented: $isPresented,
                width: menuWidth) {
            Row(alignment: .center, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(isPresented ? .onSurface : .onSurfaceVariant)
                Text("▾")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .padding(horizontal: 8, vertical: 6)
            .background(isPresented ? .surfaceSunken : .surface)
            .cornerRadius(4)
        } content: {
            Menu(menuEntries,
                 width: menuWidth,
                 maxVisibleRows: 10,
                 onItemActivated: {
                isPresented = false
            })
        }
    }

    private var menuEntries: [MenuEntry] {
        entries.map { entry in
            switch entry {
            case .separator(let id):
                return .separator(id)
            case .item(let id, let label, let shortcut, let command):
                return .item(MenuItem(id: id,
                                      title: label,
                                      shortcut: shortcut,
                                      action: {
                    onCommand(command)
                }))
            }
        }
    }
}

private enum EditorMenuCommand {
    case newScene
    case openScene
    case saveScene
    case importAssets
    case undo
    case redo
    case setWorkspaceMode(EditorWorkspaceMode)
    case setLayoutPreset(EditorLayoutPreset)
    case resetLayout
    case setPlaybackState(PlaybackState)
    case openSettings
    case toggleTheme
    case buildProject
    case buildAndRun
    case openDocumentation
    case about
}

private enum EditorMenuEntry {
    case item(String, String, String?, EditorMenuCommand)
    case separator(String)
}

private struct EditorMainToolbar: View {
    let playbackState: PlaybackState
    let workspaceMode: EditorWorkspaceMode
    let activeLayoutPreset: EditorLayoutPreset
    let onSetPlaybackState: (PlaybackState) -> Void
    let onSetWorkspaceMode: (EditorWorkspaceMode) -> Void
    let onSetLayoutPreset: (EditorLayoutPreset) -> Void
    let onResetLayout: () -> Void

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            ToolbarTextButton(title: "New")
            ToolbarTextButton(title: "Open")
            ToolbarTextButton(title: "Save")
            ToolbarTextButton(title: "Import")

            Divider()
                .frame(width: 1, height: 20)

            ToolbarStateButton(title: "Play",
                               isActive: playbackState == .playing,
                               onClick: { onSetPlaybackState(.playing) })
            ToolbarStateButton(title: "Pause",
                               isActive: playbackState == .paused,
                               onClick: { onSetPlaybackState(.paused) })
            ToolbarStateButton(title: "Stop",
                               isActive: playbackState == .stopped,
                               onClick: { onSetPlaybackState(.stopped) })

            Divider()
                .frame(width: 1, height: 20)

            ToolbarStateButton(title: "Level",
                               isActive: workspaceMode == .level,
                               onClick: { onSetWorkspaceMode(.level) })
            ToolbarStateButton(title: "Modeling",
                               isActive: workspaceMode == .modeling,
                               onClick: { onSetWorkspaceMode(.modeling) })
            ToolbarStateButton(title: "Animation",
                               isActive: workspaceMode == .animation,
                               onClick: { onSetWorkspaceMode(.animation) })

            Divider()
                .frame(width: 1, height: 20)

            LayoutPresetSelector(workspaceMode: workspaceMode,
                                 activePreset: activeLayoutPreset,
                                 onSelectPreset: onSetLayoutPreset)

            ToolbarActionButton(title: "Reset Layout",
                                onClick: onResetLayout)

            Spacer(minLength: 0)

            Text(L("Platforms"))
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)
                .padding(horizontal: 8, vertical: 6)
                .background(.surfaceSunken)
                .cornerRadius(4)
        }
        .padding(horizontal: 8, vertical: 6)
        .background(.surfaceVariant)
    }
}

private struct LayoutPresetSelector: View {
    let workspaceMode: EditorWorkspaceMode
    let activePreset: EditorLayoutPreset
    let onSelectPreset: (EditorLayoutPreset) -> Void
    @State private var isPresented: Bool = false

    init(workspaceMode: EditorWorkspaceMode,
         activePreset: EditorLayoutPreset,
         onSelectPreset: @escaping (EditorLayoutPreset) -> Void) {
        self.workspaceMode = workspaceMode
        self.activePreset = activePreset
        self.onSelectPreset = onSelectPreset
        _isPresented = State(wrappedValue: false)
    }

    var body: some View {
        Popover(isPresented: $isPresented,
                width: 132) {
            Row(alignment: .center, spacing: 6) {
                Text(L("Preset"))
                    .font(.caption)
                    .foregroundColor(.onSurfaceVariant)

                Text(shortLabel(for: activePreset))
                    .font(.caption)
                    .foregroundColor(.onSurface)

                Text("▼")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .padding(horizontal: 8, vertical: 6)
            .background(.surfaceSunken)
            .cornerRadius(4)
        } content: {
            Menu(menuEntries,
                 width: 132,
                 maxVisibleRows: 6,
                 onItemActivated: {
                isPresented = false
            })
        }
    }

    private var menuEntries: [MenuEntry] {
        switch workspaceMode {
        case .level:
            return [
                .item(MenuItem(id: "level-default",
                               title: "Default",
                               action: { onSelectPreset(.levelDefault) })),
                .item(MenuItem(id: "level-cine",
                               title: "Cine",
                               action: { onSelectPreset(.levelCinematics) })),
            ]
        case .modeling:
            return [
                .item(MenuItem(id: "modeling-default",
                               title: "Default",
                               action: { onSelectPreset(.modelingDefault) })),
                .item(MenuItem(id: "modeling-sculpt",
                               title: "Sculpt",
                               action: { onSelectPreset(.modelingSculpt) })),
            ]
        case .animation:
            return [
                .item(MenuItem(id: "animation-default",
                               title: "Default",
                               action: { onSelectPreset(.animationDefault) })),
                .item(MenuItem(id: "animation-seq",
                               title: "Seq",
                               action: { onSelectPreset(.animationSequencer) })),
            ]
        }
    }

    private func shortLabel(for preset: EditorLayoutPreset) -> String {
        switch preset {
        case .levelDefault, .modelingDefault, .animationDefault:
            return "Default"
        case .levelCinematics:
            return "Cine"
        case .modelingSculpt:
            return "Sculpt"
        case .animationSequencer:
            return "Seq"
        }
    }
}

private struct ToolbarTextButton: View {
    let title: String

    var body: some View {
        ToolbarButtonChrome(title: title)
    }
}

private struct ToolbarActionButton: View {
    let title: String
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            ToolbarButtonChrome(title: title,
                                minWidth: title.count > 8 ? 92 : 68)
        }
        .buttonStyle(.plain)
    }
}

private struct ToolbarStateButton: View {
    let title: String
    let isActive: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            ToolbarButtonChrome(title: title,
                                foreground: isActive ? .onAccent : .onSurface,
                                background: isActive ? .accent : .surfaceSunken,
                                minWidth: title.count > 7 ? 88 : 68)
        }
        .buttonStyle(.plain)
    }
}

private struct ToolbarButtonChrome: View {
    let title: String
    var foreground: SemanticColorRef = .onSurface
    var background: SemanticColorRef = .surfaceSunken
    var minWidth: Float = 68

    var body: some View {
        Box(direction: .row, alignItems: .center, justifyContent: .center) {
            Text(title, lineLimit: 1)
                .font(.caption)
                .foregroundColor(foreground)
        }
        .frame(height: 34, minWidth: minWidth)
        .padding(horizontal: 8, vertical: 0)
        .background(background)
        .cornerRadius(4)
        .clipped()
    }
}

private struct EditorStatusBar: View {
    let isConnected: Bool
    let sceneRevision: UInt64
    let selectedCount: Int
    let aiStatusMessage: String?

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            Box { EmptyView() }
                .frame(width: 6, height: 6)
                .background(isConnected ? .success : .warning)
                .cornerRadius(3)

            Text(isConnected ? L("Connected") : L("Offline"))
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)

            Divider()
                .frame(width: 1, height: 14)

            Text("Revision \(sceneRevision)")
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)

            Divider()
                .frame(width: 1, height: 14)

            Text("Selection \(selectedCount)")
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)

            Spacer(minLength: 0)

            Text(aiStatusMessage ?? L("Ready"))
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
        }
        .padding(horizontal: 10, vertical: 5)
        .background(.surfaceVariant)
    }
}

enum EditorRootViewFactory {
    struct EditorShellState: Codable, Sendable {
        var workspaceMode: EditorWorkspaceMode
        var activeLayoutPreset: EditorLayoutPreset
        var schemaVersion: Int

        static let currentSchemaVersion = 1

        init(workspaceMode: EditorWorkspaceMode,
             activeLayoutPreset: EditorLayoutPreset,
             schemaVersion: Int = currentSchemaVersion) {
            self.workspaceMode = workspaceMode
            self.activeLayoutPreset = activeLayoutPreset
            self.schemaVersion = schemaVersion
        }
    }

    static func makeController(for mode: EditorWorkspaceMode,
                               preset: EditorLayoutPreset) -> DockController {
        // Try to restore saved layout, otherwise create default
        if let saved = loadSavedLayout(for: mode, preset: preset) {
            return saved
        }
        if mode == .level,
           preset == .levelDefault,
           let legacy = loadLegacySavedLayout() {
            return legacy
        }
        return makeDefaultController(for: mode, preset: preset)
    }

    static func makeController(for mode: EditorWorkspaceMode) -> DockController {
        makeController(for: mode, preset: .default(for: mode))
    }

    static func makeController() -> DockController {
        makeController(for: .level)
    }

    static func makeDefaultController(for mode: EditorWorkspaceMode,
                                      preset: EditorLayoutPreset) -> DockController {
        let hierarchyTab = DockTab(userKey: "hierarchy", title: "Hierarchy")
        let inspectorTab = DockTab(userKey: "inspector", title: "Inspector")
        let viewportTab = DockTab(userKey: "viewport",
                                  title: "Viewport",
                                  isClosable: false)
        let consoleTab = DockTab(userKey: "console", title: "Console")
        let assetsTab = DockTab(userKey: "assets", title: "Assets")
        let intentTab = DockTab(userKey: "intent-input", title: "AI Intent")
        let confirmationTab = DockTab(userKey: "confirmation-host", title: "Confirm")

        let hierarchyLeaf: DockLayoutNode = .tabs(
            id: DockNodeID(),
            tabs: [hierarchyTab],
            activeTabID: hierarchyTab.id
        )
        let inspectorLeaf: DockLayoutNode = .tabs(
            id: DockNodeID(),
            tabs: [inspectorTab],
            activeTabID: inspectorTab.id
        )
        let viewportLeaf: DockLayoutNode = .tabs(
            id: DockNodeID(),
            tabs: [viewportTab],
            activeTabID: viewportTab.id
        )
        let bottomLeaf: DockLayoutNode = .tabs(
            id: DockNodeID(),
            tabs: [assetsTab, consoleTab, intentTab, confirmationTab],
            activeTabID: defaultBottomTabID(for: preset,
                                            assetsTab: assetsTab,
                                            consoleTab: consoleTab,
                                            intentTab: intentTab,
                                            confirmationTab: confirmationTab)
        )

        let fractions = defaultFractions(for: preset)

        let viewportAndInspector: DockLayoutNode = .split(
            id: DockNodeID(),
            axis: .horizontal,
            fraction: fractions.viewportAndInspector,
            first: viewportLeaf,
            second: inspectorLeaf
        )
        let topRow: DockLayoutNode = .split(
            id: DockNodeID(),
            axis: .horizontal,
            fraction: fractions.hierarchyAndMain,
            first: hierarchyLeaf,
            second: viewportAndInspector
        )
        let root: DockLayoutNode = .split(
            id: DockNodeID(),
            axis: .vertical,
            fraction: fractions.topAndBottom,
            first: topRow,
            second: bottomLeaf
        )
        let controller = DockController(root: root)
        let regionByKey: [String: PanelWorkspaceRegion] = [
            "hierarchy": .leadingSidebar,
            "viewport": .center,
            "inspector": .trailingSidebar,
            "console": .bottomPanel,
            "assets": .bottomPanel,
            "intent-input": .bottomPanel,
            "confirmation-host": .bottomPanel,
        ]
        controller.onAllowDrop = { [regionByKey] request in
            guard case .splitEdge(let targetID, let edge) = request.target else {
                return true
            }
            guard let targetRegion = regionOfLeaf(id: targetID,
                                                  in: controller.root,
                                                  regionByKey: regionByKey) else {
                return true
            }
            return allowsSplitEdge(in: targetRegion, edge: edge)
        }
        return controller
    }

    static func loadLayoutPreset(into controller: DockController,
                                 for mode: EditorWorkspaceMode,
                                 preset: EditorLayoutPreset) {
        if let saved = loadSavedLayout(for: mode, preset: preset) {
            controller.load(saved.snapshot())
            return
        }
        let fallback = makeDefaultController(for: mode, preset: preset)
        controller.load(fallback.snapshot())
    }

    static func resetLayout(into controller: DockController,
                            for mode: EditorWorkspaceMode) {
        let defaultPreset = EditorLayoutPreset.default(for: mode)
        let fallback = makeDefaultController(for: mode, preset: defaultPreset)
        controller.load(fallback.snapshot())
    }

    private static func allowsSplitEdge(in region: PanelWorkspaceRegion,
                                        edge: DockEdge) -> Bool {
        switch region {
        case .center:
            return true
        case .leadingSidebar, .trailingSidebar:
            return edge == .top || edge == .bottom
        case .bottomPanel:
            return edge == .left || edge == .right
        }
    }

    private static func regionOfLeaf(id: DockNodeID,
                                     in node: DockLayoutNode,
                                     regionByKey: [String: PanelWorkspaceRegion]) -> PanelWorkspaceRegion? {
        guard let found = findNode(id, in: node) else { return nil }
        switch found {
        case .empty:
            return .center
        case .tabs(_, let tabs, _):
            guard let first = tabs.first else { return .center }
            return regionByKey[first.userKey] ?? .center
        case .split:
            return nil
        }
    }

    private static func findNode(_ id: DockNodeID,
                                 in node: DockLayoutNode) -> DockLayoutNode? {
        if node.id == id { return node }
        guard case .split(_, _, _, let first, let second) = node else {
            return nil
        }
        return findNode(id, in: first) ?? findNode(id, in: second)
    }

    static func makeRegistry(app: EditorApplication) -> PanelRegistry {
        PanelRegistry([
            PanelDescriptor(id: "hierarchy",
                            title: "Hierarchy",
                            preferredRegion: .leadingSidebar) {
                HierarchyPanel(store: app.store, scene: app.scene)
            },
            PanelDescriptor(id: "inspector",
                            title: "Inspector",
                            preferredRegion: .trailingSidebar) {
                InspectorPanel(store: app.store, scene: app.scene)
            },
            PanelDescriptor(id: "viewport",
                            title: "Viewport",
                            closable: false,
                            preferredRegion: .center) {
                ViewportPanel(app: app, scene: app.scene)
            },
            PanelDescriptor(id: "console",
                            title: "Console",
                            preferredRegion: .bottomPanel) {
                ConsolePanel(store: app.store)
            },
            PanelDescriptor(id: "assets",
                            title: "Assets",
                            preferredRegion: .bottomPanel) {
                AssetBrowserPanel(app: app)
            },
            PanelDescriptor(id: "intent-input",
                            title: "AI Intent",
                            preferredRegion: .bottomPanel) {
                IntentInputPanel(app: app)
            },
            PanelDescriptor(id: "confirmation-host",
                            title: "Confirm",
                            preferredRegion: .bottomPanel) {
                ConfirmationHostPanel(app: app)
            },
        ])
    }

    private static let layoutPersistenceKey = "editor_dock_layout"
    private static let shellStatePersistenceKey = "editor_shell_state"

    private struct LayoutFractions {
        let hierarchyAndMain: Float
        let viewportAndInspector: Float
        let topAndBottom: Float
    }

    private static func defaultFractions(for preset: EditorLayoutPreset) -> LayoutFractions {
        switch preset {
        case .levelDefault:
            return LayoutFractions(hierarchyAndMain: 15.0 / 90.0,
                                   viewportAndInspector: 55.0 / 75.0,
                                   topAndBottom: 0.70)
        case .levelCinematics:
            return LayoutFractions(hierarchyAndMain: 12.0 / 90.0,
                                   viewportAndInspector: 60.0 / 78.0,
                                   topAndBottom: 0.64)
        case .modelingDefault:
            return LayoutFractions(hierarchyAndMain: 18.0 / 90.0,
                                   viewportAndInspector: 52.0 / 72.0,
                                   topAndBottom: 0.66)
        case .modelingSculpt:
            return LayoutFractions(hierarchyAndMain: 14.0 / 90.0,
                                   viewportAndInspector: 54.0 / 76.0,
                                   topAndBottom: 0.68)
        case .animationDefault:
            return LayoutFractions(hierarchyAndMain: 16.0 / 90.0,
                                   viewportAndInspector: 50.0 / 74.0,
                                   topAndBottom: 0.62)
        case .animationSequencer:
            return LayoutFractions(hierarchyAndMain: 14.0 / 90.0,
                                   viewportAndInspector: 49.0 / 76.0,
                                   topAndBottom: 0.56)
        }
    }

    private static func defaultBottomTabID(for preset: EditorLayoutPreset,
                                           assetsTab: DockTab,
                                           consoleTab: DockTab,
                                           intentTab: DockTab,
                                           confirmationTab: DockTab) -> DockTabID {
        switch preset {
        case .levelDefault, .levelCinematics:
            return assetsTab.id
        case .modelingDefault, .modelingSculpt:
            return consoleTab.id
        case .animationDefault, .animationSequencer:
            return intentTab.id
        }
    }

    private static func layoutPersistenceKey(for mode: EditorWorkspaceMode,
                                             preset: EditorLayoutPreset) -> String {
        "\(layoutPersistenceKey)_\(mode.rawValue)_\(preset.rawValue)"
    }

    static func saveDockLayout(_ controller: DockController,
                               for mode: EditorWorkspaceMode,
                               preset: EditorLayoutPreset) {
        // Ensure viewport is not detached; if it is, redock it to center before saving
        if let centerLeaf = findCenterLeaf(controller.root) {
            ensureViewportDocked(in: controller, to: centerLeaf.id)
        }

        // Create a snapshot of the current layout state
        let snapshot = DockLayoutSnapshot(
            root: controller.root,
            satellites: controller.satellites,
            satelliteOrder: controller.satelliteOrder
        )

        // Encode and save to disk
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(snapshot)
            if let layoutDir = getLayoutPersistenceDirectory() {
                let layoutPath = layoutDir.appendingPathComponent(
                    layoutPersistenceKey(for: mode, preset: preset) + ".json"
                )
                try data.write(to: layoutPath)
            }
        } catch {
            fputs("[EditorRootViewFactory] failed to save dock layout: \(error)\n", stderr)
        }
    }

    static func saveDockLayout(_ controller: DockController) {
        saveDockLayout(controller,
                       for: .level,
                       preset: .levelDefault)
    }

    private static func loadSavedLayout(for mode: EditorWorkspaceMode,
                                        preset: EditorLayoutPreset) -> DockController? {
        guard let layoutDir = getLayoutPersistenceDirectory() else { return nil }
        let layoutPath = layoutDir.appendingPathComponent(
            layoutPersistenceKey(for: mode, preset: preset) + ".json"
        )
        
        guard FileManager.default.fileExists(atPath: layoutPath.path) else { return nil }

        do {
            let data = try Data(contentsOf: layoutPath)
            let decoder = JSONDecoder()
            var snapshot = try decoder.decode(DockLayoutSnapshot.self, from: data)
            snapshot.root = sanitizeDockLayout(snapshot.root)
            let controller = DockController(root: snapshot.root)
            controller.load(snapshot)
            return controller
        } catch {
            fputs("[EditorRootViewFactory] failed to load dock layout: \(error)\n", stderr)
            return nil
        }
    }

    private static func loadLegacySavedLayout() -> DockController? {
        guard let layoutDir = getLayoutPersistenceDirectory() else { return nil }
        let layoutPath = layoutDir.appendingPathComponent(layoutPersistenceKey + ".json")
        guard FileManager.default.fileExists(atPath: layoutPath.path) else { return nil }

        do {
            let data = try Data(contentsOf: layoutPath)
            let decoder = JSONDecoder()
            var snapshot = try decoder.decode(DockLayoutSnapshot.self, from: data)
            snapshot.root = sanitizeDockLayout(snapshot.root)
            let controller = DockController(root: snapshot.root)
            controller.load(snapshot)
            return controller
        } catch {
            fputs("[EditorRootViewFactory] failed to load legacy dock layout: \(error)\n", stderr)
            return nil
        }
    }

    private static func sanitizeDockLayout(_ node: DockLayoutNode) -> DockLayoutNode {
        switch node {
        case .empty, .tabs:
            return node
        case .split(let id, let axis, let fraction, let first, let second):
            let clamped = max(0.15, min(0.85, fraction))
            return .split(id: id,
                          axis: axis,
                          fraction: clamped,
                          first: sanitizeDockLayout(first),
                          second: sanitizeDockLayout(second))
        }
    }

    static func saveShellState(mode: EditorWorkspaceMode,
                               preset: EditorLayoutPreset) {
        guard let layoutDir = getLayoutPersistenceDirectory() else { return }
        let shell = EditorShellState(workspaceMode: mode,
                                     activeLayoutPreset: preset)
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

    private static func getLayoutPersistenceDirectory() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                         in: .userDomainMask).first else {
            return nil
        }
        let guavaDir = appSupport.appendingPathComponent("Guava")
        try? FileManager.default.createDirectory(at: guavaDir, withIntermediateDirectories: true)
        return guavaDir
    }

    /// If viewport tab is in satellites, redock it to the center leaf
    private static func ensureViewportDocked(in controller: DockController, to leafID: DockNodeID) {
        let viewportKey = "viewport"
        
        // Check if viewport is in satellites
        for (satelliteID, satellite) in controller.satellites {
            if case .tabs(_, let tabs, _) = satellite,
               tabs.contains(where: { $0.userKey == viewportKey }) {
                // Found viewport in a satellite, redock it
                let viewportTab = tabs.first { $0.userKey == viewportKey }!
                controller.apply(.insertTab(viewportTab, into: leafID, at: 0))
                controller.apply(.closeSatellite(satelliteID))
                return
            }
        }
    }

    private static func findCenterLeaf(_ node: DockLayoutNode) -> DockLayoutNode? {
        switch node {
        case .empty:
            return node
        case .tabs:
            return node
        case .split(_, _, _, let first, let second):
            if let found = findCenterLeaf(first) { return found }
            return findCenterLeaf(second)
        }
    }
}
