@testable import EditorApp
import EditorCore
import GuavaUIApp
import GuavaUIRuntime
import Testing

@Suite("Editor native menu")
struct EditorNativeMenuTests {
    @MainActor
    @Test("native menu exposes editor commands and invokes the dispatcher callback")
    func exposesAndInvokesCommands() {
        var built = false
        let bar = EditorNativeMenuBuilder.make(workspaceMode: .level,
                                               activeLayoutPreset: .levelDefault,
                                               playbackState: .stopped,
                                               canUndo: true,
                                               canRedo: true,
                                               hasSelection: true) { command in
            if case .buildProject = command { built = true }
        }

        #expect(!bar.menus.isEmpty)
        let actions = bar.menus.flatMap(\.items).compactMap { item -> NativeMenuAction? in
            if case let .action(action) = item { return action }
            return nil
        }
        let build = actions.first { $0.keyEquivalent == "b" }
        #expect(build?.isEnabled == true)
        build?.action()
        #expect(built)

        let deletion = actions.first { $0.keyEquivalent == "\u{8}" }
        #expect(deletion?.keyModifiers.isEmpty == true)
        #expect(deletion?.isEnabled == true)
    }

    @MainActor
    @Test("native menu mirrors playback authoring availability")
    func mirrorsPlaybackAvailability() {
        let bar = EditorNativeMenuBuilder.make(workspaceMode: .level,
                                               activeLayoutPreset: .levelDefault,
                                               playbackState: .playing,
                                               canUndo: true,
                                               canRedo: true,
                                               hasSelection: true) { _ in }
        let actions = bar.menus.flatMap(\.items).compactMap { item -> NativeMenuAction? in
            if case let .action(action) = item { return action }
            return nil
        }
        for action in actions where ["n", "o", "z", "d", "\u{8}"].contains(action.keyEquivalent) {
            #expect(!action.isEnabled)
        }
    }

    @MainActor
    @Test("native undo availability follows focused text history without rebuilding the menu")
    func focusedTextAvailability() {
        let focus = FocusChain()
        let bar = EditorNativeMenuBuilder.make(workspaceMode: .level,
                                               activeLayoutPreset: .levelDefault,
                                               playbackState: .playing,
                                               focusChain: { focus }) { _ in }
        let actions = bar.menus.flatMap(\.items).compactMap { item -> NativeMenuAction? in
            if case let .action(action) = item { return action }
            return nil
        }
        let undo = actions.first { $0.keyEquivalent == "z" && !$0.keyModifiers.contains(.shift) }
        let redo = actions.first { $0.keyEquivalent == "z" && $0.keyModifiers.contains(.shift) }
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
