@testable import EditorApp
import EditorCore
import EngineKernel
import GuavaUICompose
import Testing

@Suite("EditorShortcutHandler")
struct ShortcutHandlerTests {

    private final class Recorder {
        var saves = 0, settings = 0, palettes = 0, undos = 0, redos = 0
        var newScenes = 0, openScenes = 0, duplicates = 0, deletions = 0
        var builds = 0, buildAndRuns = 0, reopens = 0
    }

    @discardableResult
    private func fire(_ key: KeyEvent, into r: Recorder) -> Bool {
        EditorShortcutHandler.handle(key,
                                     playbackState: .stopped,
                                     commandPaletteVisible: false,
                                     setPlaybackState: { _ in },
                                     setWorkspaceMode: { _ in },
                                     resetLayout: {},
                                     reopenClosedPanel: { r.reopens += 1 },
                                     newScene: { r.newScenes += 1 },
                                     openScene: { r.openScenes += 1 },
                                     saveScene: { r.saves += 1 },
                                     duplicateSelection: { r.duplicates += 1 },
                                     deleteSelection: { r.deletions += 1 },
                                     buildProject: { r.builds += 1 },
                                     buildAndRun: { r.buildAndRuns += 1 },
                                     openSettings: { r.settings += 1 },
                                     openCommandPalette: { r.palettes += 1 },
                                     closeCommandPalette: {},
                                     undo: { r.undos += 1 },
                                     redo: { r.redos += 1 })
    }

    @Test("Delete and Backspace dispatch after focused controls fall through")
    func globalDeleteShortcutsDispatch() {
        let r = Recorder()
        #expect(fire(key(Scancode.delete, []), into: r))
        #expect(fire(key(Scancode.backspace, []), into: r))
        #expect(r.deletions == 2)
    }

    @Test("Advertised file, edit, and build shortcuts dispatch globally")
    func advertisedMenuShortcutsDispatch() {
        let r = Recorder()
        #expect(fire(key(Scancode.n, [.lgui]), into: r))
        #expect(fire(key(Scancode.o, [.lgui]), into: r))
        #expect(fire(key(Scancode.d, [.lgui]), into: r))
        #expect(fire(key(Scancode.b, [.lgui]), into: r))
        #expect(fire(key(Scancode.r, [.lgui]), into: r))
        #expect(r.newScenes == 1)
        #expect(r.openScenes == 1)
        #expect(r.duplicates == 1)
        #expect(r.builds == 1)
        #expect(r.buildAndRuns == 1)
    }

    private func key(_ scancode: UInt32, _ modifiers: KeyModifiers) -> KeyEvent {
        KeyEvent(scancode: scancode, keycode: 0, modifiers: modifiers, isRepeat: false)
    }

    @Test("Single left Cmd triggers chords — contains(.gui) superset regression")
    func singleSidedModifierMatches() {
        let r = Recorder()
        #expect(fire(key(Scancode.s, [.lgui]), into: r))
        #expect(fire(key(Scancode.comma, [.lgui]), into: r))
        #expect(fire(key(Scancode.k, [.rgui]), into: r))
        #expect(fire(key(Scancode.s, [.rctrl]), into: r))
        #expect(r.saves == 2)
        #expect(r.settings == 1)
        #expect(r.palettes == 1)
    }

    @Test("Cmd+Z undoes, Cmd+Shift+Z with one shift key redoes")
    func undoRedo() {
        let r = Recorder()
        #expect(fire(key(Scancode.z, [.lgui]), into: r))
        #expect(fire(key(Scancode.z, [.lgui, .lshift]), into: r))
        #expect(r.undos == 1)
        #expect(r.redos == 1)
    }

    @Test("Cmd+Shift+T reopens the last closed panel")
    func reopenPanel() {
        let r = Recorder()
        #expect(fire(key(Scancode.t, [.lgui, .lshift]), into: r))
        #expect(r.reopens == 1)
    }

    @Test("Unmodified keys fall through")
    func unmodifiedIgnored() {
        let r = Recorder()
        #expect(!fire(key(Scancode.s, []), into: r))
        #expect(r.saves == 0)
    }
}
