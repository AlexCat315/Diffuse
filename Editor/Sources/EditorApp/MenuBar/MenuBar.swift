import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import Foundation

struct EditorMenuBar: View {
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
                           entries: fileEntries)
                .id("editor-menu-file")
            EditorMenuItem(title: L("Edit"),
                           menuWidth: 200,
                           entries: editEntries)
                .id("editor-menu-edit")
            EditorMenuItem(title: L("Window"),
                           menuWidth: 240,
                           entries: windowEntries)
                .id("editor-menu-window")
            EditorMenuItem(title: L("Tools"),
                           menuWidth: 200,
                           entries: toolsEntries)
                .id("editor-menu-tools")
            EditorMenuItem(title: L("Build"),
                           menuWidth: 200,
                           entries: buildEntries)
                .id("editor-menu-build")
            EditorMenuItem(title: L("Help"),
                           menuWidth: 220,
                           entries: helpEntries)
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

    private var fileEntries: [MenuEntry] {
        [
            .item(MenuItem(id: "new-scene", title: L("New Scene"), shortcut: "⌘N") { onCommand(.newScene) }),
            .item(MenuItem(id: "open-scene", title: L("Open Scene..."), shortcut: "⌘O") { onCommand(.openScene) }),
            .item(MenuItem(id: "save-scene", title: L("Save Scene"), shortcut: "⌘S") { onCommand(.saveScene) }),
            .separator("file-sep-1"),
            .item(MenuItem(id: "import-assets", title: L("Import Assets...")) { onCommand(.importAssets) }),
        ]
    }

    private var editEntries: [MenuEntry] {
        [
            .item(MenuItem(id: "undo", title: L("Undo"), shortcut: "⌘Z") { onCommand(.undo) }),
            .item(MenuItem(id: "redo", title: L("Redo"), shortcut: "⇧⌘Z") { onCommand(.redo) }),
            .separator("edit-sep-1"),
            .item(MenuItem(id: "settings", title: L("Settings"), shortcut: "⌘,") { onCommand(.openSettings) }),
        ]
    }

    private var windowEntries: [MenuEntry] {
        [
            .item(MenuItem(id: "workspace-level", title: workspaceTitle(for: .level)) { onCommand(.setWorkspaceMode(.level)) }),
            .item(MenuItem(id: "workspace-modeling", title: workspaceTitle(for: .modeling)) { onCommand(.setWorkspaceMode(.modeling)) }),
            .item(MenuItem(id: "workspace-animation", title: workspaceTitle(for: .animation)) { onCommand(.setWorkspaceMode(.animation)) }),
            .separator("window-sep-1"),
            .item(MenuItem(id: "preset-level-default", title: presetTitle(.levelDefault)) { onCommand(.setLayoutPreset(.levelDefault)) }),
            .item(MenuItem(id: "preset-level-cine", title: presetTitle(.levelCinematics)) { onCommand(.setLayoutPreset(.levelCinematics)) }),
            .item(MenuItem(id: "preset-modeling-default", title: presetTitle(.modelingDefault)) { onCommand(.setLayoutPreset(.modelingDefault)) }),
            .item(MenuItem(id: "preset-modeling-sculpt", title: presetTitle(.modelingSculpt)) { onCommand(.setLayoutPreset(.modelingSculpt)) }),
            .item(MenuItem(id: "preset-animation-default", title: presetTitle(.animationDefault)) { onCommand(.setLayoutPreset(.animationDefault)) }),
            .item(MenuItem(id: "preset-animation-seq", title: presetTitle(.animationSequencer)) { onCommand(.setLayoutPreset(.animationSequencer)) }),
            .separator("window-sep-2"),
            .item(MenuItem(id: "reset-layout", title: L("Reset Layout")) { onCommand(.resetLayout) }),
        ]
    }

    private var toolsEntries: [MenuEntry] {
        [
            .item(MenuItem(id: "play", title: playbackTitle(for: .playing)) { onCommand(.setPlaybackState(.playing)) }),
            .item(MenuItem(id: "pause", title: playbackTitle(for: .paused)) { onCommand(.setPlaybackState(.paused)) }),
            .item(MenuItem(id: "stop", title: playbackTitle(for: .stopped)) { onCommand(.setPlaybackState(.stopped)) }),
            .separator("tools-sep-1"),
            .item(MenuItem(id: "toggle-theme", title: L("Toggle Theme")) { onCommand(.toggleTheme) }),
        ]
    }

    private var buildEntries: [MenuEntry] {
        [
            .item(MenuItem(id: "build-project", title: L("Build Editor")) { onCommand(.buildProject) }),
            .item(MenuItem(id: "build-run", title: L("Build and Run")) { onCommand(.buildAndRun) }),
        ]
    }

    private var helpEntries: [MenuEntry] {
        [
            .item(MenuItem(id: "open-docs", title: L("Documentation")) { onCommand(.openDocumentation) }),
            .separator("help-sep-1"),
            .item(MenuItem(id: "about", title: L("About Guava")) { onCommand(.about) }),
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

enum EditorMenuCommand {
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
