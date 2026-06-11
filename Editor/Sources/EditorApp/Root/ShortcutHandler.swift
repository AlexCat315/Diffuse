import EditorCore
import EngineKernel
import GuavaUICompose
import GuavaUIRuntime

enum EditorShortcutHandler {
    static func handle(_ key: KeyEvent,
                       playbackState: PlaybackState,
                       commandPaletteVisible: Bool,
                       setPlaybackState: (PlaybackState) -> Void,
                       setWorkspaceMode: (EditorWorkspaceMode) -> Void,
                       resetLayout: () -> Void,
                       newScene: () -> Void,
                       saveScene: () -> Void,
                       openSettings: () -> Void,
                       openCommandPalette: () -> Void,
                       closeCommandPalette: () -> Void,
                       undo: () -> Void,
                       redo: () -> Void) -> Bool {
        guard !key.isRepeat else { return false }

        // Escape — highest priority: dismiss any overlay first.
        if key.scancode == Scancode.escape {
            if commandPaletteVisible {
                closeCommandPalette()
                return true
            }
            return false
        }

        let commandLike = key.modifiers.hasGui || key.modifiers.hasCtrl
        guard commandLike else { return false }

        // Scancodes (physical key) rather than keycodes: layout-independent and
        // consistent with the rest of the compose controls.
        switch key.scancode {
        case Scancode.z:
            if key.modifiers.hasShift { redo() } else { undo() }
            return true
        case Scancode.s:
            saveScene()
            return true
        case Scancode.k:
            openCommandPalette()
            return true
        case Scancode.n:
            newScene()
            return true
        case Scancode.comma:
            openSettings()
            return true
        case Scancode.digit0:
            resetLayout()
            return true
        case Scancode.digit1:
            setWorkspaceMode(.level)
            return true
        case Scancode.digit2:
            setWorkspaceMode(.modeling)
            return true
        case Scancode.digit3:
            setWorkspaceMode(.animation)
            return true
        case Scancode.return, Scancode.keypadEnter:
            // Enter belongs to the palette's text field while it is open.
            guard !commandPaletteVisible else { return false }
            switch playbackState {
            case .playing: setPlaybackState(.paused)
            case .paused, .stopped: setPlaybackState(.playing)
            }
            return true
        default:
            return false
        }
    }
}
