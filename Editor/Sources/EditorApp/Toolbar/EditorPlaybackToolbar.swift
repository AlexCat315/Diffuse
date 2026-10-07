import EditorCore
import GuavaUICompose
import GuavaUIRuntime

/// Application-level playback stays reachable from every docked editor.
struct EditorPlaybackToolbar: View {
    let state: PlaybackState
    let onCommand: (EditorMenuCommand) -> Void

    var body: some View {
        Row(alignment: .center, spacing: 3) {
            control("play", title: L("Play in current viewport"), target: .playing)
            control("pause", title: L("Pause game"), target: .paused)
            control("stop", title: L("Stop and return to editing"), target: .stopped)
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
        .buttonStyle(.toolToggle)
    }
}
