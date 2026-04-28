import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import Foundation

// MARK: - Toolbar Icon Enum

enum EditorToolbarIcon: String {
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

// MARK: - Main Toolbar View

struct EditorMainToolbar: View {
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