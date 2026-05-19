import EditorCore
import EngineKernel
import GuavaUIRuntime

enum EditorShortcutHandler {
    static func handle(_ key: KeyEvent,
                       playbackState: PlaybackState,
                       commandPaletteVisible: Bool,
                       setPlaybackState: (PlaybackState) -> Void,
                       setWorkspaceMode: (EditorWorkspaceMode) -> Void,
                       resetLayout: () -> Void,
                       newScene: () -> Void,
                       openSettings: () -> Void,
                       openCommandPalette: () -> Void,
                       closeCommandPalette: () -> Void,
                       undo: () -> Void,
                       redo: () -> Void) -> Bool {
        guard !key.isRepeat else { return false }

        // Escape — highest priority: dismiss any overlay first
        if key.scancode == 41 {
            if commandPaletteVisible {
                closeCommandPalette()
                return true
            }
            return false
        }

        let commandLike = key.modifiers.contains(.gui) || key.modifiers.contains(.ctrl)
        guard commandLike else { return false }

        // Undo / Redo — Cmd+Z / Cmd+Shift+Z
        if key.keycode == 0x7A {  // z
            if key.modifiers.contains(.shift) {
                redo()
            } else {
                undo()
            }
            return true
        }

        switch key.keycode {
        case 0x6B:  // k
            openCommandPalette()
            return true
        case 0x6E:
            newScene()
            return true
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
