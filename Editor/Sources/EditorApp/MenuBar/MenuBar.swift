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