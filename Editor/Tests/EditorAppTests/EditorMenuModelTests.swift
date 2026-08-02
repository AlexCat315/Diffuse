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
        let cmds = actions(EditorMenuModel.make(workspaceMode: .level,
                                                activeLayoutPreset: .levelDefault,
                                                playbackState: .stopped,
                                                canUndo: true,
                                                canRedo: true,
                                                hasSelection: true)).map(\.command)
        func has(_ predicate: (EditorMenuCommand) -> Bool) -> Bool { cmds.contains(where: predicate) }

        #expect(has { if case .newScene = $0 { return true }; return false })
        #expect(has { if case .openScene = $0 { return true }; return false })
        #expect(has { if case .saveScene = $0 { return true }; return false })
        #expect(has { if case .importAssets = $0 { return true }; return false })
        #expect(has { if case .undo = $0 { return true }; return false })
        #expect(has { if case .redo = $0 { return true }; return false })
        #expect(has { if case .duplicateSelection = $0 { return true }; return false })
        #expect(has { if case .deleteSelection = $0 { return true }; return false })
        #expect(has { if case .buildProject = $0 { return true }; return false })
        #expect(has { if case .buildAndRun = $0 { return true }; return false })
        #expect(has { if case .reopenClosedPanel = $0 { return true }; return false })
    }

    @Test("edit commands reflect actual history and selection availability")
    func editCommandAvailability() {
        let unavailable = actions(make())
        for action in unavailable {
            switch action.command {
            case .undo, .redo, .duplicateSelection, .deleteSelection:
                #expect(!action.isEnabled)
            default: break
            }
        }

        let available = actions(EditorMenuModel.make(workspaceMode: .level,
                                                     activeLayoutPreset: .levelDefault,
                                                     playbackState: .stopped,
                                                     canUndo: true,
                                                     canRedo: true,
                                                     hasSelection: true))
        for action in available {
            switch action.command {
            case .undo, .redo, .duplicateSelection, .deleteSelection:
                #expect(action.isEnabled)
            default: break
            }
        }
    }

    @Test("scene authoring commands are disabled while playing or paused")
    func playbackDisablesSceneAuthoringCommands() {
        for playbackState in [PlaybackState.playing, .paused] {
            let model = EditorMenuModel.make(workspaceMode: .level,
                                             activeLayoutPreset: .levelDefault,
                                             playbackState: playbackState,
                                             canUndo: true,
                                             canRedo: true,
                                             hasSelection: true)
            for action in actions(model) {
                switch action.command {
                case .newScene, .openScene, .undo, .redo, .duplicateSelection, .deleteSelection:
                    #expect(!action.isEnabled)
                default:
                    break
                }
            }
        }
        #expect(EditorSceneAuthoringPolicy.canEditScene(during: .stopped))
        #expect(!EditorSceneAuthoringPolicy.canEditScene(during: .playing))
        #expect(!EditorSceneAuthoringPolicy.canEditScene(during: .paused))
    }

    @Test("playback state selects exactly the matching transport command")
    func playbackSelection() {
        let model = make(.playing)
        for action in actions(model) {
            switch action.command {
            case .setPlaybackState(.playing):
                #expect(action.isSelected)
                #expect(!action.isEnabled)
            case .setPlaybackState(.paused), .setPlaybackState(.stopped):
                #expect(!action.isSelected)
                #expect(action.isEnabled)
            default: break
            }
        }
    }

    @Test("playback policy rejects no-op and stopped-to-paused transitions")
    func playbackTransitionPolicy() {
        #expect(EditorPlaybackCommandPolicy.canTransition(from: .stopped, to: .playing))
        #expect(!EditorPlaybackCommandPolicy.canTransition(from: .stopped, to: .paused))
        #expect(!EditorPlaybackCommandPolicy.canTransition(from: .stopped, to: .stopped))

        #expect(EditorPlaybackCommandPolicy.canTransition(from: .playing, to: .paused))
        #expect(EditorPlaybackCommandPolicy.canTransition(from: .playing, to: .stopped))
        #expect(!EditorPlaybackCommandPolicy.canTransition(from: .playing, to: .playing))

        #expect(EditorPlaybackCommandPolicy.canTransition(from: .paused, to: .playing))
        #expect(EditorPlaybackCommandPolicy.canTransition(from: .paused, to: .stopped))
        #expect(!EditorPlaybackCommandPolicy.canTransition(from: .paused, to: .paused))
    }

    @Test("stopped tools menu disables pause and the already-active stop command")
    func stoppedPlaybackMenuAvailability() {
        for action in actions(make(.stopped)) {
            switch action.command {
            case .setPlaybackState(.playing): #expect(action.isEnabled)
            case .setPlaybackState(.paused), .setPlaybackState(.stopped):
                #expect(!action.isEnabled)
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
        // `.primary` is Cmd on macOS, Ctrl elsewhere — assert against it rather
        // than hardcoding `.command`, which is wrong on Windows/Linux.
        #expect(undo?.keyModifiers.contains(.primary) == true)
    }

    @Test("delete binds to an unmodified native Delete key")
    func deleteShortcut() {
        let model = EditorMenuModel.make(workspaceMode: .level,
                                         activeLayoutPreset: .levelDefault,
                                         playbackState: .stopped,
                                         hasSelection: true)
        let deletion = actions(model).first { action in
            if case .deleteSelection = action.command { return true }
            return false
        }
        #expect(deletion?.keyEquivalent == "\u{8}")
        #expect(deletion?.keyModifiers.isEmpty == true)
        #expect(deletion?.isEnabled == true)
    }

    @Test("model is non-empty across every playback state")
    func nonEmptyMenus() {
        for state in [PlaybackState.stopped, .playing, .paused] {
            #expect(!make(state).menus.isEmpty)
            #expect(!actions(make(state)).isEmpty)
        }
    }
}
