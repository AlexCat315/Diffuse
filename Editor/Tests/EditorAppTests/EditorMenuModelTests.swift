@testable import EditorApp
import EditorCore
import Testing

@Suite("EditorMenuModel")
struct EditorMenuModelTests {

    private func actions(_ model: EditorMenuModel) -> [EditorApplicationMenuAction] {
        model.menus.flatMap { menu in
            menu.items.compactMap { item -> EditorApplicationMenuAction? in
                if case let .action(a) = item { return a }
                return nil
            }
        }
    }

    private func make(_ playback: PlaybackState = .stopped,
                      workspace: EditorWorkspaceMode = .level,
                      preset: EditorLayoutPreset = .levelDefault) -> EditorMenuModel {
        EditorMenuModel.make(workspaceMode: workspace, activeLayoutPreset: preset, playbackState: playback)
    }

    @Test("exposes the core file / edit / build commands")
    func coreCommands() {
        let cmds = actions(make()).map(\.command)
        func has(_ predicate: (EditorMenuCommand) -> Bool) -> Bool { cmds.contains(where: predicate) }

        #expect(has { if case .newScene = $0 { return true }; return false })
        #expect(has { if case .openScene = $0 { return true }; return false })
        #expect(has { if case .saveScene = $0 { return true }; return false })
        #expect(has { if case .importAssets = $0 { return true }; return false })
        #expect(has { if case .undo = $0 { return true }; return false })
        #expect(has { if case .redo = $0 { return true }; return false })
        #expect(has { if case .buildProject = $0 { return true }; return false })
        #expect(has { if case .buildAndRun = $0 { return true }; return false })
    }

    @Test("playback state selects exactly the matching transport command")
    func playbackSelection() {
        let model = make(.playing)
        for action in actions(model) {
            switch action.command {
            case .setPlaybackState(.playing): #expect(action.isSelected)
            case .setPlaybackState(.paused): #expect(!action.isSelected)
            case .setPlaybackState(.stopped): #expect(!action.isSelected)
            default: break
            }
        }
    }

    @Test("active workspace mode is marked selected")
    func workspaceSelection() {
        let model = make(workspace: .modeling)
        let selected = actions(model).first { action in
            if case .setWorkspaceMode(.modeling) = action.command { return true }
            return false
        }
        #expect(selected?.isSelected == true)

        let other = actions(model).first { action in
            if case .setWorkspaceMode(.level) = action.command { return true }
            return false
        }
        #expect(other?.isSelected == false)
    }

    @Test("undo binds to the primary+Z shortcut")
    func undoShortcut() {
        let undo = actions(make()).first { action in
            if case .undo = action.command { return true }
            return false
        }
        #expect(undo?.keyEquivalent == "z")
        #expect(undo?.keyModifiers.contains(.command) == true)
    }

    @Test("model is non-empty across every playback state")
    func nonEmptyMenus() {
        for state in [PlaybackState.stopped, .playing, .paused] {
            #expect(!make(state).menus.isEmpty)
            #expect(!actions(make(state)).isEmpty)
        }
    }
}
