@testable import EditorApp
import EditorCore
import GuavaUIApp
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
}
