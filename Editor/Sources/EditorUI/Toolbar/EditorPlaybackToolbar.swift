import EditorCore
import GuavaUI
import GuavaUIRuntime

/// Application-level playback stays reachable from every docked editor.
struct EditorPlaybackToolbar: View {
    let state: PlaybackState
    /// Narrow windows keep one play/pause toggle and Stop.
    var compact = false
    let onCommand: (EditorCommand) -> Void

    var body: some View {
        Row(alignment: .center, spacing: 2) {
            if compact {
                if state == .playing {
                    control("pause", title: L("Pause game"), target: .paused, primary: true)
                } else {
                    control("play", title: L("Play in current viewport"), target: .playing)
                }
            } else {
                Icon(UIIcons.Media.monitor, size: 12, color: .onSurfaceVariant)
                    .padding(horizontal: 5)
                control("play", title: L("Play in current viewport"), target: .playing)
                control("pause", title: L("Pause game"), target: .paused)
            }
            control("stop", title: L("Stop and return to editing"), target: .stopped)
        }
        .padding(2)
        .background(.surfaceSunken)
        .cornerRadius(7)
        .border(.divider, width: 1)
        .debugName("editor-playback-toolbar")
    }

    private func control(_ icon: String, title: String, target: PlaybackState, primary: Bool? = nil) -> some View {
        Button(icon: .resource(.svg(named: icon, in: EditorAppResourceBundle.bundle,
                                    subdirectory: "ToolbarIcons")),
               size: 12,
               isEnabled: EditorPlaybackCommandPolicy.canTransition(from: state, to: target),
               isSelected: state == target && target != .stopped,
               tooltip: title) {
            onCommand(.setPlaybackState(target))
        }
        .buttonStyle(PlaybackButtonStyle(primary: primary ?? (target == .playing)))
    }
}

private struct PlaybackButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let colors = configuration.theme.colors
        let emphasized = configuration.isEnabled && (primary || configuration.isSelected)
        Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label).foregroundColor(emphasized ? colors.onAccent
                : configuration.isEnabled ? colors.onSurfaceVariant : colors.onSurfaceMuted)
        }.frame(width: primary ? 30 : 24, height: 24)
            .background(emphasized ? colors.accent
                : configuration.isPressed ? colors.stateLayerPressed
                : configuration.isHovered ? colors.stateLayerHover : .clear)
            .cornerRadius(5)
            .border(configuration.isFocused ? colors.focusRing : .clear, width: 1)
    }
}
