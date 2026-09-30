import EditorCore
import GuavaUICompose
import GuavaUIRuntime

/// Application-level playback stays reachable from every docked editor.
struct EditorPlaybackToolbar: View {
    let state: PlaybackState
    let onCommand: (EditorMenuCommand) -> Void

    var body: some View {
        Row(alignment: .center, spacing: 3) {
            control("play", title: L("Play physics simulation"), target: .playing)
            control("pause", title: L("Pause physics simulation"), target: .paused)
            control("stop", title: L("Stop physics simulation"), target: .stopped)
            Divider(axis: .vertical).frame(width: 1, height: 14)
            Text(L("Local Runtime"), lineLimit: 1)
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)
                .padding(horizontal: 6)
        }
        .padding(horizontal: 4, vertical: 2)
        .background(.surfaceSunken)
        .cornerRadius(5)
        .border(.divider, width: 1)
        .debugName("editor-playback-toolbar")
    }

    private func control(_ icon: String, title: String, target: PlaybackState) -> some View {
        Button(icon: .resource(.svg(named: icon, in: EditorAppResourceBundle.bundle,
                                    subdirectory: "ToolbarIcons")),
               size: 12,
               isEnabled: EditorPlaybackCommandPolicy.canTransition(from: state, to: target),
               isSelected: state == target && target != .stopped,
               tooltip: title) {
            onCommand(.setPlaybackState(target))
        }
        .buttonStyle(ToggleButtonStyle(minWidth: 28, height: 24))
    }
}
