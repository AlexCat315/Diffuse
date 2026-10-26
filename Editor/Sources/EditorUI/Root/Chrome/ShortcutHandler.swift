internal import EngineKernel
internal import CoveUI

/// Key chords that reach the window: everything on Windows and Linux, and on
/// macOS whatever the native menu bar did not already claim. Chords come from
/// the command catalog, so a menu label and its key can never disagree.
enum EditorShortcutHandler {
    static func handle(_ key: KeyEvent,
                       catalog: EditorCommandCatalog,
                       commandPaletteVisible: Bool,
                       closeCommandPalette: () -> Void,
                       perform: (EditorCommand) -> Void,
                       unavailable: (EditorCommandEntry) -> Void = { _ in }) -> Bool {
        guard !key.isRepeat else { return false }

        // Escape dismisses the palette before anything else sees it.
        if key.scancode == Scancode.escape {
            guard commandPaletteVisible else { return false }
            closeCommandPalette()
            return true
        }

        guard let entry = catalog.entry(matching: key) else { return false }
        // Enter belongs to the palette's text field while it is open.
        if commandPaletteVisible, entry.shortcut?.key == .enter { return false }
        if EditorCommandDispatcher.isEnabled(entry.command, sceneCommandEnabled: entry.isEnabled) {
            perform(entry.command)
        } else {
            unavailable(entry)
        }
        return true
    }
}
