import EditorCore
import EngineKernel
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
            let _: Void = {
                EditorLocalizationPreferences.language = store.state.language
                EditorRootViewFactory.localizeDockTitles(in: controller)
            }()
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
                                                     preset: nextPreset,
                                                     themeMode: store.state.themeMode,
                                                     language: store.state.language,
                                                     vsyncMode: store.state.vsyncMode)
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
                                                     preset: nextPreset,
                                                     themeMode: store.state.themeMode,
                                                     language: store.state.language,
                                                     vsyncMode: store.state.vsyncMode)
            }

            let resetLayout: () -> Void = {
                let mode = store.state.workspaceMode
                let preset = store.state.activeLayoutPreset
                EditorRootViewFactory.resetLayout(into: controller,
                                                  for: mode,
                                                  preset: preset)
                EditorRootViewFactory.saveDockLayout(controller,
                                                     for: mode,
                                                     preset: preset)
                EditorRootViewFactory.saveShellState(mode: mode,
                                                     preset: preset,
                                                     themeMode: store.state.themeMode,
                                                     language: store.state.language,
                                                     vsyncMode: store.state.vsyncMode)
            }

            let handleShortcut: (KeyEvent) -> Bool = { key in
                Self.handleEditorShortcut(key,
                                          playbackState: store.state.playbackState,
                                          setPlaybackState: setPlaybackState,
                                          setWorkspaceMode: setWorkspaceMode,
                                          resetLayout: resetLayout,
                                          openSettings: {
                                              app.openSettingsWindow()
                                          })
            }

            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                ShortcutHost(onKeyDown: handleShortcut)

                EditorMainToolbar(playbackState: store.state.playbackState,
                                  workspaceMode: store.state.workspaceMode,
                                  activeLayoutPreset: store.state.activeLayoutPreset,
                                  onSetPlaybackState: setPlaybackState,
                                  onSetWorkspaceMode: setWorkspaceMode,
                                  onSetLayoutPreset: setLayoutPreset,
                                  onResetLayout: resetLayout,
                                  onOpenSettings: {
                                      app.openSettingsWindow()
                                  })
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
            .appearance(store.state.themeMode == .dark ? .dark : .light)
            .background(.background)
            .flex()
        }
    }

    private static func handleEditorShortcut(_ key: KeyEvent,
                                             playbackState: PlaybackState,
                                             setPlaybackState: (PlaybackState) -> Void,
                                             setWorkspaceMode: (EditorWorkspaceMode) -> Void,
                                             resetLayout: () -> Void,
                                             openSettings: () -> Void) -> Bool {
        guard !key.isRepeat else { return false }

        let commandLike = key.modifiers.contains(.gui) || key.modifiers.contains(.ctrl)
        guard commandLike else { return false }

        switch key.keycode {
        case 0x2C:
            openSettings()
            return true
        case 0x30:
            resetLayout()
            return true
        case 0x31:
            setWorkspaceMode(.level)
            return true
        case 0x32:
            setWorkspaceMode(.modeling)
            return true
        case 0x33:
            setWorkspaceMode(.animation)
            return true
        default:
            break
        }

        if key.scancode == 40 || key.scancode == 88 {
            switch playbackState {
            case .playing:
                setPlaybackState(.paused)
            case .paused, .stopped:
                setPlaybackState(.playing)
            }
            return true
        }

        return false
    }
}

struct EditorSettingsWindowRoot: View {
    let app: EditorApplication

    var body: some View {
        StoreScope(app.store) { store in
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                SettingsPanel(app: app)
                    .flex()
            }
            .appearance(store.state.themeMode == .dark ? .dark : .light)
            .background(.background)
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

            EditorMenuItem(title: L("File"),
                           menuWidth: 220,
                           entries: fileEntries,
                           onCommand: onCommand)
                .id("editor-menu-file")
            EditorMenuItem(title: L("Edit"),
                           menuWidth: 200,
                           entries: editEntries,
                           onCommand: onCommand)
                .id("editor-menu-edit")
            EditorMenuItem(title: L("Window"),
                           menuWidth: 240,
                           entries: windowEntries,
                           onCommand: onCommand)
                .id("editor-menu-window")
            EditorMenuItem(title: L("Tools"),
                           menuWidth: 200,
                           entries: toolsEntries,
                           onCommand: onCommand)
                .id("editor-menu-tools")
            EditorMenuItem(title: L("Build"),
                           menuWidth: 200,
                           entries: buildEntries,
                           onCommand: onCommand)
                .id("editor-menu-build")
            EditorMenuItem(title: L("Help"),
                           menuWidth: 220,
                           entries: helpEntries,
                           onCommand: onCommand)
                .id("editor-menu-help")

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
            .item("new-scene", L("New Scene"), "⌘N", .newScene),
            .item("open-scene", L("Open Scene..."), "⌘O", .openScene),
            .item("save-scene", L("Save Scene"), "⌘S", .saveScene),
            .separator("file-sep-1"),
            .item("import-assets", L("Import Assets..."), nil, .importAssets),
        ]
    }

    private var editEntries: [EditorMenuEntry] {
        [
            .item("undo", L("Undo"), "⌘Z", .undo),
            .item("redo", L("Redo"), "⇧⌘Z", .redo),
            .separator("edit-sep-1"),
            .item("settings", L("Settings"), "⌘,", .openSettings),
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
            .item("reset-layout", L("Reset Layout"), nil, .resetLayout),
        ]
    }

    private var toolsEntries: [EditorMenuEntry] {
        [
            .item("play", playbackTitle(for: .playing), nil, .setPlaybackState(.playing)),
            .item("pause", playbackTitle(for: .paused), nil, .setPlaybackState(.paused)),
            .item("stop", playbackTitle(for: .stopped), nil, .setPlaybackState(.stopped)),
            .separator("tools-sep-1"),
            .item("toggle-theme", L("Toggle Theme"), nil, .toggleTheme),
        ]
    }

    private var buildEntries: [EditorMenuEntry] {
        [
            .item("build-project", L("Build Editor"), nil, .buildProject),
            .item("build-run", L("Build and Run"), nil, .buildAndRun),
        ]
    }

    private var helpEntries: [EditorMenuEntry] {
        [
            .item("open-docs", L("Documentation"), nil, .openDocumentation),
            .separator("help-sep-1"),
            .item("about", L("About Guava"), nil, .about),
        ]
    }

    private func workspaceTitle(for mode: EditorWorkspaceMode) -> String {
        let marker = workspaceMode == mode ? "✓" : "  "
        switch mode {
        case .level:
            return "\(marker) \(L("Workspace: Level"))"
        case .modeling:
            return "\(marker) \(L("Workspace: Modeling"))"
        case .animation:
            return "\(marker) \(L("Workspace: Animation"))"
        }
    }

    private func presetTitle(_ preset: EditorLayoutPreset) -> String {
        let marker = activeLayoutPreset == preset ? "✓" : "  "
        return "\(marker) \(localizedPresetTitle(preset))"
    }

    private func localizedPresetTitle(_ preset: EditorLayoutPreset) -> String {
        switch preset {
        case .levelDefault:
            return L("Level: Default")
        case .levelCinematics:
            return L("Level: Cinematics")
        case .modelingDefault:
            return L("Modeling: Default")
        case .modelingSculpt:
            return L("Modeling: Sculpt")
        case .animationDefault:
            return L("Animation: Default")
        case .animationSequencer:
            return L("Animation: Sequencer")
        }
    }

    private func playbackTitle(for state: PlaybackState) -> String {
        switch state {
        case .playing:
            return L("Play")
        case .paused:
            return L("Pause")
        case .stopped:
            return L("Stop")
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
    let onOpenSettings: () -> Void

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            IconButton(resource: EditorToolbarIcon.plus.resource,
                       size: 15,
                       tooltip: L("New Scene")) {}
                .buttonStyle(EditorIconButtonStyle(size: 34))
            IconButton(resource: EditorToolbarIcon.folderOpen.resource,
                       size: 15,
                       tooltip: L("Open Scene...")) {}
                .buttonStyle(EditorIconButtonStyle(size: 34))
            IconButton(resource: EditorToolbarIcon.save.resource,
                       size: 15,
                       tooltip: L("Save Scene")) {}
                .buttonStyle(EditorIconButtonStyle(size: 34))
            IconButton(resource: EditorToolbarIcon.folder.resource,
                       size: 15,
                       tooltip: L("Import Assets...")) {}
                .buttonStyle(EditorIconButtonStyle(size: 34))

            Divider()
                .frame(width: 1, height: 20)

            IconButton(resource: EditorToolbarIcon.play.resource,
                       size: 15,
                       tooltip: L("Play")) {
                onSetPlaybackState(.playing)
            }
            .buttonStyle(EditorIconButtonStyle(isActive: playbackState == .playing,
                                               size: 34))
            IconButton(resource: EditorToolbarIcon.pause.resource,
                       size: 15,
                       tooltip: L("Pause")) {
                onSetPlaybackState(.paused)
            }
            .buttonStyle(EditorIconButtonStyle(isActive: playbackState == .paused,
                                               size: 34))
            IconButton(resource: EditorToolbarIcon.stop.resource,
                       size: 15,
                       tooltip: L("Stop")) {
                onSetPlaybackState(.stopped)
            }
            .buttonStyle(EditorIconButtonStyle(isActive: playbackState == .stopped,
                                               size: 34))

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

            IconButton(resource: EditorToolbarIcon.layoutGrid.resource,
                       size: 15,
                       tooltip: L("Reset Layout"),
                       action: onResetLayout)
                .buttonStyle(EditorIconButtonStyle(size: 34))

            Spacer(minLength: 0)
            IconButton(resource: EditorToolbarIcon.settings.resource,
                       size: 15,
                       tooltip: L("Settings"),
                       action: onOpenSettings)
                .buttonStyle(EditorIconButtonStyle(size: 34))
            IconButton(resource: EditorToolbarIcon.package.resource,
                       size: 15,
                       tooltip: L("Platforms")) {}
                .buttonStyle(EditorIconButtonStyle(size: 34))
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
                               title: L("Default"),
                               action: { onSelectPreset(.levelDefault) })),
                .item(MenuItem(id: "level-cine",
                               title: L("Cine"),
                               action: { onSelectPreset(.levelCinematics) })),
            ]
        case .modeling:
            return [
                .item(MenuItem(id: "modeling-default",
                               title: L("Default"),
                               action: { onSelectPreset(.modelingDefault) })),
                .item(MenuItem(id: "modeling-sculpt",
                               title: L("Sculpt"),
                               action: { onSelectPreset(.modelingSculpt) })),
            ]
        case .animation:
            return [
                .item(MenuItem(id: "animation-default",
                               title: L("Default"),
                               action: { onSelectPreset(.animationDefault) })),
                .item(MenuItem(id: "animation-seq",
                               title: L("Seq"),
                               action: { onSelectPreset(.animationSequencer) })),
            ]
        }
    }

    private func shortLabel(for preset: EditorLayoutPreset) -> String {
        switch preset {
        case .levelDefault, .modelingDefault, .animationDefault:
            return L("Default")
        case .levelCinematics:
            return L("Cine")
        case .modelingSculpt:
            return L("Sculpt")
        case .animationSequencer:
            return L("Seq")
        }
    }
}

private struct ToolbarTextButton: View {
    let title: String

    var body: some View {
        ToolbarButtonChrome(title: title)
    }
}

private enum EditorToolbarIcon: String {
    case plus = "plus"
    case folderOpen = "folder-f"
    case folder = "folder"
    case save = "save"
    case play = "play"
    case pause = "pause"
    case stop = "stop"
    case package = "package"
    case settings = "cog-6-tooth"
    case layoutGrid = "toolbar-squares-2x2"
    case cursor = "cursor-arrow-rays"
    case translate = "direction-arrows"
    case rotate = "toolbar-arrow-path"
    case scale = "arrows-pointing-out"
    case globe = "globe"
    case eye = "toolbar-eye"
    case wireframe = "grid-pattern"

    var resource: BundleImageResource {
        .svg(named: rawValue,
             in: .module,
             subdirectory: "ToolbarIcons")
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
        var themeMode: EditorThemeMode
        var language: EditorLanguage
        var vsyncMode: EditorVSyncMode
        var schemaVersion: Int

        static let currentSchemaVersion = 4

        init(workspaceMode: EditorWorkspaceMode,
             activeLayoutPreset: EditorLayoutPreset,
             themeMode: EditorThemeMode = .dark,
             language: EditorLanguage = .system,
             vsyncMode: EditorVSyncMode = .enabled,
             schemaVersion: Int = currentSchemaVersion) {
            self.workspaceMode = workspaceMode
            self.activeLayoutPreset = activeLayoutPreset
            self.themeMode = themeMode
            self.language = language
            self.vsyncMode = vsyncMode
            self.schemaVersion = schemaVersion
        }

        enum CodingKeys: String, CodingKey {
            case workspaceMode
            case activeLayoutPreset
            case themeMode
            case language
            case vsyncMode
            case schemaVersion
        }

        enum LegacyCodingKeys: String, CodingKey {
            case frameRateLimit
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(workspaceMode, forKey: .workspaceMode)
            try values.encode(activeLayoutPreset, forKey: .activeLayoutPreset)
            try values.encode(themeMode, forKey: .themeMode)
            try values.encode(language, forKey: .language)
            try values.encode(vsyncMode, forKey: .vsyncMode)
            try values.encode(schemaVersion, forKey: .schemaVersion)
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            workspaceMode = try values.decodeIfPresent(EditorWorkspaceMode.self, forKey: .workspaceMode) ?? .level
            activeLayoutPreset = try values.decodeIfPresent(EditorLayoutPreset.self, forKey: .activeLayoutPreset)
                ?? .default(for: workspaceMode)
            themeMode = try values.decodeIfPresent(EditorThemeMode.self, forKey: .themeMode) ?? .dark
            language = try values.decodeIfPresent(EditorLanguage.self, forKey: .language) ?? .system
            let legacyValues = try decoder.container(keyedBy: LegacyCodingKeys.self)
            if let decodedVSync = try values.decodeIfPresent(EditorVSyncMode.self, forKey: .vsyncMode) {
                vsyncMode = decodedVSync
            } else if let legacyLimit = try legacyValues.decodeIfPresent(String.self, forKey: .frameRateLimit) {
                vsyncMode = EditorVSyncMode(legacyFrameRateLimitRawValue: legacyLimit)
            } else {
                vsyncMode = .enabled
            }
            schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
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
        let hierarchyTab = DockTab(userKey: "hierarchy", title: localizedPanelTitle(for: "hierarchy"))
        let inspectorTab = DockTab(userKey: "inspector", title: localizedPanelTitle(for: "inspector"))
        let viewportTab = DockTab(userKey: "viewport",
                                  title: localizedPanelTitle(for: "viewport"),
                                  isClosable: false)
        let consoleTab = DockTab(userKey: "console", title: localizedPanelTitle(for: "console"))
        let assetsTab = DockTab(userKey: "assets", title: localizedPanelTitle(for: "assets"))
        let intentTab = DockTab(userKey: "intent-input", title: localizedPanelTitle(for: "intent-input"))
        let confirmationTab = DockTab(userKey: "confirmation-host", title: localizedPanelTitle(for: "confirmation-host"))

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
                            for mode: EditorWorkspaceMode,
                            preset: EditorLayoutPreset) {
        let fallback = makeDefaultController(for: mode, preset: preset)
        controller.load(fallback.snapshot())
    }

    static func resetLayout(into controller: DockController,
                            for mode: EditorWorkspaceMode) {
        resetLayout(into: controller,
                    for: mode,
                    preset: .default(for: mode))
    }

    static func activateTab(_ userKey: String, in controller: DockController) {
        if let target = findTab(userKey, in: controller.root) {
            controller.apply(.setActive(node: target.leafID, tab: target.tabID))
            return
        }

        let tab = DockTab(userKey: userKey, title: localizedPanelTitle(for: userKey))
        let leafID = findBottomLeaf(in: controller.root) ?? firstTabsLeaf(in: controller.root)
        if let leafID {
            controller.apply(.insertTab(tab, into: leafID, at: Int.max))
            controller.apply(.setActive(node: leafID, tab: tab.id))
        }
    }

    static func openSettingsSatellite(in controller: DockController) {
        let settingsKey = "settings"

        // Settings is already detached; keep the existing satellite.
        if findTabInSatellites(settingsKey, in: controller.satellites) != nil {
            return
        }

        if let location = findTabLocation(settingsKey, in: controller.root) {
            if location.tabCount > 1 {
                controller.apply(.move(tabID: location.tabID,
                                       to: .splitEdge(target: location.leafID,
                                                      edge: .right)))
            }
            if let detached = findTab(settingsKey, in: controller.root) {
                controller.apply(.detach(leafID: detached.leafID))
            }
            return
        }

        activateTab(settingsKey, in: controller)
        if let inserted = findTabLocation(settingsKey, in: controller.root) {
            if inserted.tabCount > 1 {
                controller.apply(.move(tabID: inserted.tabID,
                                       to: .splitEdge(target: inserted.leafID,
                                                      edge: .right)))
            }
            if let detached = findTab(settingsKey, in: controller.root) {
                controller.apply(.detach(leafID: detached.leafID))
            }
        }
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

    private static func findTab(_ userKey: String,
                                in node: DockLayoutNode) -> (leafID: DockNodeID, tabID: DockTabID)? {
        switch node {
        case .empty:
            return nil
        case .tabs(let id, let tabs, _):
            guard let tab = tabs.first(where: { $0.userKey == userKey }) else { return nil }
            return (id, tab.id)
        case .split(_, _, _, let first, let second):
            return findTab(userKey, in: first) ?? findTab(userKey, in: second)
        }
    }

    private static func findTabLocation(_ userKey: String,
                                        in node: DockLayoutNode) -> (leafID: DockNodeID, tabID: DockTabID, tabCount: Int)? {
        switch node {
        case .empty:
            return nil
        case .tabs(let id, let tabs, _):
            guard let tab = tabs.first(where: { $0.userKey == userKey }) else { return nil }
            return (leafID: id, tabID: tab.id, tabCount: tabs.count)
        case .split(_, _, _, let first, let second):
            return findTabLocation(userKey, in: first) ?? findTabLocation(userKey, in: second)
        }
    }

    private static func findTabInSatellites(_ userKey: String,
                                            in satellites: [DockNodeID: DockLayoutNode]) -> (leafID: DockNodeID, tabID: DockTabID)? {
        for (leafID, node) in satellites {
            guard case .tabs(_, let tabs, _) = node,
                  let tab = tabs.first(where: { $0.userKey == userKey }) else {
                continue
            }
            return (leafID: leafID, tabID: tab.id)
        }
        return nil
    }

    private static func findBottomLeaf(in node: DockLayoutNode) -> DockNodeID? {
        switch node {
        case .empty:
            return nil
        case .tabs(let id, let tabs, _):
            let bottomKeys: Set<String> = ["assets", "console", "intent-input", "confirmation-host"]
            return tabs.contains(where: { bottomKeys.contains($0.userKey) }) ? id : nil
        case .split(_, _, _, let first, let second):
            return findBottomLeaf(in: second) ?? findBottomLeaf(in: first)
        }
    }

    private static func firstTabsLeaf(in node: DockLayoutNode) -> DockNodeID? {
        switch node {
        case .empty:
            return nil
        case .tabs(let id, _, _):
            return id
        case .split(_, _, _, let first, let second):
            return firstTabsLeaf(in: first) ?? firstTabsLeaf(in: second)
        }
    }

    static func localizeDockTitles(in controller: DockController) {
        let root = localizeDockTitles(in: controller.root)
        let satellites = controller.satellites.mapValues(localizeDockTitles(in:))
        let minimizedLeaves = controller.minimizedLeaves.mapValues { leaf in
            DockMinimizedLeaf(node: localizeDockTitles(in: leaf.node),
                              edge: leaf.edge)
        }
        controller.replace(root: root,
                           satellites: satellites,
                           satelliteOrder: controller.satelliteOrder,
                           minimizedLeaves: minimizedLeaves,
                           minimizedOrder: controller.minimizedOrder)
    }

    private static func localizeDockTitles(in node: DockLayoutNode) -> DockLayoutNode {
        switch node {
        case .empty:
            return node
        case .tabs(let id, let tabs, let active):
            let localizedTabs = tabs.map { tab -> DockTab in
                var next = tab
                next.title = localizedPanelTitle(for: tab.userKey)
                return next
            }
            return .tabs(id: id, tabs: localizedTabs, activeTabID: active)
        case .split(let id, let axis, let fraction, let first, let second):
            return .split(id: id,
                          axis: axis,
                          fraction: fraction,
                          first: localizeDockTitles(in: first),
                          second: localizeDockTitles(in: second))
        }
    }

    private static func localizedPanelTitle(for userKey: String) -> String {
        switch userKey {
        case "hierarchy": return L("Hierarchy")
        case "inspector": return L("Inspector")
        case "viewport": return L("Viewport")
        case "console": return L("Console")
        case "assets": return L("Assets")
        case "intent-input": return L("AI Intent")
        case "confirmation-host": return L("Confirm")
        case "settings": return L("Settings")
        default: return userKey
        }
    }

    static func makeRegistry(app: EditorApplication) -> PanelRegistry {
        PanelRegistry([
            PanelDescriptor(id: "hierarchy",
                            title: localizedPanelTitle(for: "hierarchy"),
                            preferredRegion: .leadingSidebar) {
                HierarchyPanel(store: app.store, scene: app.scene)
            },
            PanelDescriptor(id: "inspector",
                            title: localizedPanelTitle(for: "inspector"),
                            preferredRegion: .trailingSidebar) {
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
                            preferredRegion: .bottomPanel) {
                ConsolePanel(store: app.store)
            },
            PanelDescriptor(id: "assets",
                            title: localizedPanelTitle(for: "assets"),
                            preferredRegion: .bottomPanel) {
                AssetBrowserPanel(app: app)
            },
            PanelDescriptor(id: "intent-input",
                            title: localizedPanelTitle(for: "intent-input"),
                            preferredRegion: .bottomPanel) {
                IntentInputPanel(app: app)
            },
            PanelDescriptor(id: "confirmation-host",
                            title: localizedPanelTitle(for: "confirmation-host"),
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
            satelliteOrder: controller.satelliteOrder,
            minimizedLeaves: controller.minimizedLeaves,
            minimizedOrder: controller.minimizedOrder
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
            guard !isEmptyDockLayout(snapshot.root) else { return nil }
            snapshot.satellites = sanitizeSatellites(snapshot.satellites)
            snapshot.satelliteOrder = snapshot.satelliteOrder.filter { snapshot.satellites[$0] != nil }
            snapshot.minimizedLeaves = sanitizeMinimizedLeaves(snapshot.minimizedLeaves)
            snapshot.minimizedOrder = snapshot.minimizedOrder.filter { snapshot.minimizedLeaves[$0] != nil }
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
            guard !isEmptyDockLayout(snapshot.root) else { return nil }
            snapshot.satellites = sanitizeSatellites(snapshot.satellites)
            snapshot.satelliteOrder = snapshot.satelliteOrder.filter { snapshot.satellites[$0] != nil }
            snapshot.minimizedLeaves = sanitizeMinimizedLeaves(snapshot.minimizedLeaves)
            snapshot.minimizedOrder = snapshot.minimizedOrder.filter { snapshot.minimizedLeaves[$0] != nil }
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
        case .empty:
            return node
        case .tabs(let id, let tabs, let active):
            let filtered = tabs.filter { $0.userKey != "settings" }
            guard !filtered.isEmpty else { return .empty(id: id) }
            let nextActive = active.flatMap { activeID in
                filtered.contains(where: { $0.id == activeID }) ? activeID : nil
            } ?? filtered.first?.id
            return .tabs(id: id, tabs: filtered, activeTabID: nextActive)
        case .split(let id, let axis, let fraction, let first, let second):
            let clamped = max(0.05, min(0.95, fraction))
            let sanitizedFirst = sanitizeDockLayout(first)
            let sanitizedSecond = sanitizeDockLayout(second)
            if case .empty = sanitizedFirst { return sanitizedSecond }
            if case .empty = sanitizedSecond { return sanitizedFirst }
            return .split(id: id,
                          axis: axis,
                          fraction: clamped,
                          first: sanitizedFirst,
                          second: sanitizedSecond)
        }
    }

    private static func sanitizeSatellites(_ satellites: [DockNodeID: DockLayoutNode]) -> [DockNodeID: DockLayoutNode] {
        satellites.compactMapValues { node in
            let sanitized = sanitizeDockLayout(node)
            if case .empty = sanitized {
                return nil
            }
            return sanitized
        }
    }

    private static func sanitizeMinimizedLeaves(_ leaves: [DockNodeID: DockMinimizedLeaf]) -> [DockNodeID: DockMinimizedLeaf] {
        leaves.compactMapValues { leaf in
            let sanitized = sanitizeDockLayout(leaf.node)
            guard case .tabs = sanitized else { return nil }
            return DockMinimizedLeaf(node: sanitized, edge: leaf.edge)
        }
    }

    private static func isEmptyDockLayout(_ node: DockLayoutNode) -> Bool {
        if case .empty = node { return true }
        return false
    }

    static func saveShellState(mode: EditorWorkspaceMode,
                               preset: EditorLayoutPreset,
                               themeMode: EditorThemeMode,
                               language: EditorLanguage,
                               vsyncMode: EditorVSyncMode) {
        guard let layoutDir = getLayoutPersistenceDirectory() else { return }
        let shell = EditorShellState(workspaceMode: mode,
                                     activeLayoutPreset: preset,
                                     themeMode: themeMode,
                                     language: language,
                                     vsyncMode: vsyncMode)
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

        for (leafID, minimized) in controller.minimizedLeaves {
            if case .tabs(_, let tabs, _) = minimized.node,
               tabs.contains(where: { $0.userKey == viewportKey }) {
                controller.apply(.restoreMinimizedLeaf(leafID))
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
