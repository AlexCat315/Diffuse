import EditorCore
import GuavaUI
import GuavaUIRuntime

/// The run box: where the game runs, Build, then only the transport that
/// applies: Play while stopped, Pause and Stop while playing, Play and Stop
/// while paused.
struct EditorPlaybackToolbar: View {
    let state: PlaybackState
    /// Narrow windows drop the target and Build.
    var compact = false
    /// The run target label needs the widest windows.
    var showsTarget = true
    let onCommand: (EditorCommand) -> Void

    var body: some View {
        Row(alignment: .center, spacing: 2) {
            if !compact && showsTarget {
                Row(alignment: .center, spacing: 5) {
                    Icon(UIIcons.Media.monitor, size: 11, color: .onSurfaceVariant)
                    Text(Self.hostTarget).font(.caption).foregroundColor(.onSurfaceVariant)
                }.padding(horizontal: 7).frame(height: 22)
                    .accessibility { $0.label = L("Run Target") + " " + Self.hostTarget }
                    .debugName("editor-run-target")
            }
            if !compact {
                Button(icon: .resource(.svg(named: "build", in: EditorAppResourceBundle.bundle, subdirectory: "ToolbarIcons")), size: 13,
                       tooltip: L("Build Project") + " " + EditorShortcut(.letter("b")).label) {
                    onCommand(.buildProject)
                }.buttonStyle(PlaybackButtonStyle(primary: false)).debugName("editor-build")
            }
            if state == .playing {
                control("pause", title: L("Pause game"), target: .paused, primary: true)
            } else {
                control("play", title: L("Play in current viewport"), target: .playing)
            }
            if state != .stopped {
                control("stop", title: L("Stop and return to editing"), target: .stopped)
            }
        }
        .padding(2)
        .background(.surfaceVariant)
        .cornerRadius(7)
        .debugName("editor-playback-toolbar")
    }

    /// Play runs in this editor on the machine it runs on.
    static var hostTarget: String {
        #if os(macOS)
        "macOS"
        #elseif os(Windows)
        "Windows"
        #else
        "Linux"
        #endif
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
            .animation(motion: .fast, value: configuration.interactionKey)
    }
}
