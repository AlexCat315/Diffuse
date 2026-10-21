@testable import EditorUI
import EditorCore
import GuavaUI
import GuavaUIRuntime
import Testing

@Suite("Editor native menu")
struct EditorNativeMenuTests {
    private func actions(_ items: [NativeMenuItem]) -> [NativeMenuAction] {
        items.flatMap { item -> [NativeMenuAction] in
            switch item {
            case let .action(action): [action]
            case let .submenu(menu): actions(menu.items)
            case .separator: []
            }
        }
    }

    private func catalog(_ playback: PlaybackState = .stopped) -> EditorCommandCatalog {
        .make(EditorCommandContext(workspaceMode: .level, playbackState: playback,
                                   canUndo: true, canRedo: true, hasSelection: true))
    }

    @MainActor
    @Test("native menu exposes editor commands and invokes the dispatcher callback")
    func exposesAndInvokesCommands() {
        var built = false
        let bar = EditorNativeMenuBuilder.make(catalog: catalog()) { command in
            if case .buildProject = command { built = true }
        }

        #expect(!bar.menus.isEmpty)
        let all = actions(bar.menus.flatMap(\.items))
        let build = all.first { $0.keyEquivalent == "b" }
        #expect(build?.isEnabled == true)
        build?.action()
        #expect(built)

        let deletion = all.first { $0.keyEquivalent == "\u{8}" }
        #expect(deletion?.keyModifiers.isEmpty == true)
        #expect(deletion?.isEnabled == true)
    }

    @MainActor
    @Test("About and Settings live in the application menu and nowhere else")
    func applicationMenu() {
        let bar = EditorNativeMenuBuilder.make(catalog: catalog()) { _ in }
        let application = actions(bar.applicationItems)
        #expect(application.map(\.title) == [L("About Guava"), L("Settings...")])
        #expect(application.last?.keyEquivalent == ",")
        #expect(!actions(bar.menus.flatMap(\.items)).contains { $0.keyEquivalent == "," })
        #expect(bar.applicationTitles.quit.contains("GuavaStudio"))
    }

    @MainActor
    @Test("View nests Space, Layout and Panels as native submenus with their key equivalents")
    func nestedSubmenus() {
        let bar = EditorNativeMenuBuilder.make(catalog: catalog()) { _ in }
        let view = bar.menus.first { $0.title == L("View") }
        let submenus = view?.items.compactMap { item -> NativeMenu? in
            if case let .submenu(menu) = item { return menu }
            return nil
        } ?? []
        #expect(submenus.map(\.title) == [L("Space"), L("Layout"), L("Panels")])
        #expect(actions(submenus.first?.items ?? []).filter { !$0.keyEquivalent.isEmpty }.map(\.keyEquivalent)
            == ["1", "2", "3", "4", "5"])
    }

    @MainActor
    @Test("native menu mirrors playback authoring availability")
    func mirrorsPlaybackAvailability() {
        let bar = EditorNativeMenuBuilder.make(catalog: catalog(.playing)) { _ in }
        for action in actions(bar.menus.flatMap(\.items)) where ["n", "o", "z", "d", "\u{8}"].contains(action.keyEquivalent) {
            #expect(!action.isEnabled)
        }
    }

    @MainActor
    @Test("native undo availability follows focused text history without rebuilding the menu")
    func focusedTextAvailability() {
        let focus = FocusChain()
        let bar = EditorNativeMenuBuilder.make(
            catalog: .make(EditorCommandContext(workspaceMode: .level, playbackState: .playing)),
            focusChain: { focus }) { _ in }
        let all = actions(bar.menus.flatMap(\.items))
        let undo = all.first { $0.keyEquivalent == "z" && !$0.keyModifiers.contains(.shift) }
        let redo = all.first { $0.keyEquivalent == "z" && $0.keyModifiers.contains(.shift) }
        #expect(undo?.resolvedIsEnabled == false)
        var canUndo = true
        let input = Node()
        input.isFocusable = true
        input.attachments[TextInputAttachmentKey.editActions] = TextEditActions(
            canPerform: { $0 == .undo ? canUndo : !canUndo },
            perform: { _ in canUndo.toggle() }
        )
        focus.focus(input)
        #expect(undo?.resolvedIsEnabled == true)
        #expect(redo?.resolvedIsEnabled == false)
        focus.performTextEdit(.undo)
        #expect(undo?.resolvedIsEnabled == false)
        #expect(redo?.resolvedIsEnabled == true)
        focus.beginModal(input)
        #expect(!EditorCommandDispatcher.isEnabled(.saveScene, sceneCommandEnabled: true, focusChain: focus))
        #expect(redo?.resolvedIsEnabled == true)
        focus.endModal(input)
        focus.clear()
        #expect(redo?.resolvedIsEnabled == false)
    }
}
