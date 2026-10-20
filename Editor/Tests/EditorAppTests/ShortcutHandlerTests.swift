@testable import EditorUI
import EditorCore
import EngineKernel
import GuavaUICompose
import Testing

@Suite("EditorShortcutHandler")
struct ShortcutHandlerTests {
    private final class Recorder {
        var performed: [String] = []
        var closedPalette = 0
    }

    @discardableResult
    private func fire(_ key: KeyEvent,
                      into r: Recorder,
                      context: EditorCommandContext = EditorCommandContext(workspaceMode: .level, canUndo: true,
                                                                           canRedo: true, hasSelection: true),
                      paletteVisible: Bool = false) -> Bool {
        let catalog = EditorCommandCatalog.make(context)
        return EditorShortcutHandler.handle(key,
                                            catalog: catalog,
                                            commandPaletteVisible: paletteVisible,
                                            closeCommandPalette: { r.closedPalette += 1 },
                                            perform: { command in
            r.performed.append(catalog.entries.first { "\($0.command)" == "\(command)" }?.id ?? "\(command)")
        })
    }

    private func key(_ scancode: UInt32, _ modifiers: KeyModifiers, repeat isRepeat: Bool = false) -> KeyEvent {
        KeyEvent(scancode: scancode, keycode: 0, modifiers: modifiers, isRepeat: isRepeat)
    }

    @Test("Delete and Backspace dispatch after focused controls fall through")
    func globalDeleteShortcutsDispatch() {
        let r = Recorder()
        #expect(fire(key(Scancode.delete, []), into: r))
        #expect(fire(key(Scancode.backspace, []), into: r))
        #expect(r.performed == ["edit.delete", "edit.delete"])
    }

    @Test("Advertised file, edit, and build shortcuts dispatch globally")
    func advertisedMenuShortcutsDispatch() {
        let r = Recorder()
        for scancode in [Scancode.n, Scancode.o, Scancode.d, Scancode.b, Scancode.r] {
            #expect(fire(key(scancode, [.lgui]), into: r))
        }
        #expect(r.performed == ["scene.new", "scene.open", "edit.duplicate", "project.build", "project.run"])
    }

    @Test("Single left or right modifiers trigger chords — contains(.gui) superset regression")
    func singleSidedModifierMatches() {
        let r = Recorder()
        #expect(fire(key(Scancode.s, [.lgui]), into: r))
        #expect(fire(key(Scancode.comma, [.lgui]), into: r))
        #expect(fire(key(Scancode.k, [.rgui]), into: r))
        #expect(fire(key(Scancode.s, [.rctrl]), into: r))
        #expect(r.performed == ["scene.save", "preferences", "agent.intent", "scene.save"])
    }

    @Test("Cmd+Z undoes, Cmd+Shift+Z with one shift key redoes")
    func undoRedo() {
        let r = Recorder()
        #expect(fire(key(Scancode.z, [.lgui]), into: r))
        #expect(fire(key(Scancode.z, [.lgui, .lshift]), into: r))
        #expect(r.performed == ["edit.undo", "edit.redo"])
    }

    @Test("Cmd+Shift+T reopens the last closed panel")
    func reopenPanel() {
        let r = Recorder()
        #expect(fire(key(Scancode.t, [.lgui, .lshift]), into: r))
        #expect(r.performed == ["layout.reopen"])
    }

    @Test("Space and palette chords open their destinations")
    func spacesAndPalette() {
        let r = Recorder()
        #expect(fire(key(Scancode.digit1, [.lgui]), into: r))
        #expect(fire(key(Scancode.digit5, [.lgui]), into: r))
        #expect(fire(key(Scancode.p, [.lgui]), into: r))
        #expect(fire(key(Scancode.p, [.lgui, .lshift]), into: r))
        #expect(r.performed == ["workspace.documents", "workspace.modeling", "search.resources", "palette.commands"])
    }

    @Test("Unmodified keys and key repeats fall through")
    func unmodifiedIgnored() {
        let r = Recorder()
        #expect(!fire(key(Scancode.s, []), into: r))
        #expect(!fire(key(Scancode.s, [.lgui], repeat: true), into: r))
        #expect(r.performed.isEmpty)
    }

    @Test("Disabled commands consume their chord without running")
    func disabledCommandsDoNotRun() {
        let r = Recorder()
        let empty = EditorCommandContext(workspaceMode: .level)
        #expect(fire(key(Scancode.delete, []), into: r, context: empty))
        #expect(fire(key(Scancode.d, [.lgui]), into: r, context: empty))
        #expect(r.performed.isEmpty)
    }

    @Test("Commands outside the workspace never match")
    func workspaceScopedChords() {
        let r = Recorder()
        let film = EditorCommandContext(workspaceMode: .modeling)
        #expect(!fire(key(Scancode.b, [.lgui]), into: r, context: film))
        #expect(!fire(key(Scancode.return, [.lgui]), into: r, context: film))
        #expect(r.performed.isEmpty)
    }

    @Test("Escape closes the palette, and Enter stays with the palette field")
    func paletteKeys() {
        let r = Recorder()
        #expect(!fire(key(Scancode.escape, []), into: r))
        #expect(fire(key(Scancode.escape, []), into: r, paletteVisible: true))
        #expect(r.closedPalette == 1)
        #expect(!fire(key(Scancode.return, [.lgui]), into: r, paletteVisible: true))
        #expect(fire(key(Scancode.return, [.lgui]), into: r))
        #expect(r.performed == ["playback.toggle"])
    }
}
