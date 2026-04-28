import EditorCore
import EngineKernel
import GuavaUIRuntime

enum EditorShortcutHandler {
    static func handle(_ key: KeyEvent,
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
