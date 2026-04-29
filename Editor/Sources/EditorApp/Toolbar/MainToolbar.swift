import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import Foundation

extension View {
    func toggleButtonStyle(_ isActive: Bool) -> some View {
        compositionLocal(ButtonStyleEnvironment.key,
                         isActive ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(GhostButtonStyle()))
    }
}

enum EditorToolbarIcon: String {
    case play = "play"
    case pause = "pause"
    case stop = "stop"
    case layoutGrid = "toolbar-squares-2x2"

    var resource: BundleImageResource {
        .svg(named: rawValue,
             in: .module,
             subdirectory: "ToolbarIcons")
    }
}

struct EditorMainToolbar: View {
    let playbackState: PlaybackState
    let workspaceMode: EditorWorkspaceMode
    let activeLayoutPreset: EditorLayoutPreset
    let onSetPlaybackState: (PlaybackState) -> Void
    let onSetWorkspaceMode: (EditorWorkspaceMode) -> Void
    let onSetLayoutPreset: (EditorLayoutPreset) -> Void
    let onResetLayout: () -> Void

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            IconButton(resource: EditorToolbarIcon.play.resource,
                       size: 15,
                       tooltip: L("Play")) {
                onSetPlaybackState(.playing)
            }
            .toggleButtonStyle(playbackState == .playing)
            IconButton(resource: EditorToolbarIcon.pause.resource,
                       size: 15,
                       tooltip: L("Pause")) {
                onSetPlaybackState(.paused)
            }
            .toggleButtonStyle(playbackState == .paused)
            IconButton(resource: EditorToolbarIcon.stop.resource,
                       size: 15,
                       tooltip: L("Stop")) {
                onSetPlaybackState(.stopped)
            }
            .toggleButtonStyle(playbackState == .stopped)

            Divider()
                .frame(width: 1, height: 20)

            Button(action: { onSetWorkspaceMode(.level) }) {
                Text(L("Level")).font(.caption)
            }
            .toggleButtonStyle(workspaceMode == .level)
            Button(action: { onSetWorkspaceMode(.modeling) }) {
                Text(L("Modeling")).font(.caption)
            }
            .toggleButtonStyle(workspaceMode == .modeling)
            Button(action: { onSetWorkspaceMode(.animation) }) {
                Text(L("Animation")).font(.caption)
            }
            .toggleButtonStyle(workspaceMode == .animation)

            Divider()
                .frame(width: 1, height: 20)

            LayoutPresetSelector(workspaceMode: workspaceMode,
                                 activePreset: activeLayoutPreset,
                                 onSelectPreset: onSetLayoutPreset)

            IconButton(resource: EditorToolbarIcon.layoutGrid.resource,
                       size: 15,
                       tooltip: L("Reset Layout"),
                       action: onResetLayout)
                .buttonStyle(.ghost)

            Spacer(minLength: 0)
        }
        .padding(horizontal: 8, vertical: 6)
        .background(.surfaceVariant)
    }
}
