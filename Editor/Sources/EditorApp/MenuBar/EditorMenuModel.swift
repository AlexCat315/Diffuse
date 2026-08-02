import EditorCore

enum EditorPlaybackCommandPolicy {
    static func canTransition(from current: PlaybackState,
                              to next: PlaybackState) -> Bool {
        current.canTransition(to: next)
    }
}

enum EditorSceneAuthoringPolicy {
    static func canEditScene(during playbackState: PlaybackState) -> Bool {
        playbackState == .stopped
    }
}

struct EditorMenuModel {
    let menus: [EditorApplicationMenu]

    static func make(workspaceMode: EditorWorkspaceMode,
                     activeLayoutPreset: EditorLayoutPreset,
                     playbackState: PlaybackState,
                     canUndo: Bool = false,
                     canRedo: Bool = false,
                     hasSelection: Bool = false) -> EditorMenuModel {
        let canAuthorScene = EditorSceneAuthoringPolicy.canEditScene(during: playbackState)
        return EditorMenuModel(menus: [
            EditorApplicationMenu(title: L("File"), items: [
                action(L("New Scene"), key: "n", enabled: canAuthorScene, command: .newScene),
                action(L("Open Scene..."), key: "o", enabled: canAuthorScene, command: .openScene),
                action(L("Save Scene"), key: "s", command: .saveScene),
                .separator,
                action(L("Import Assets..."), key: "", command: .importAssets),
            ]),
            EditorApplicationMenu(title: L("Edit"), items: [
                action(L("Undo"), key: "z", enabled: canAuthorScene && canUndo, command: .undo),
                action(L("Redo"), key: "z", modifiers: [.primary, .shift], enabled: canAuthorScene && canRedo, command: .redo),
                .separator,
                action(L("Duplicate Selection"), key: "d", enabled: canAuthorScene && hasSelection, command: .duplicateSelection),
                action(L("Delete Selection"), key: "\u{8}", modifiers: [],
                       enabled: canAuthorScene && hasSelection, command: .deleteSelection),
                .separator,
                action(L("Settings"), key: ",", command: .openSettings),
            ]),
            EditorApplicationMenu(title: L("Window"), items: [
                action(L("Workspace: Level"), key: "", selected: workspaceMode == .level,
                       command: .setWorkspaceMode(.level)),
                action(L("Workspace: Modeling"), key: "", selected: workspaceMode == .modeling,
                       command: .setWorkspaceMode(.modeling)),
                action(L("Workspace: Animation"), key: "", selected: workspaceMode == .animation,
                       command: .setWorkspaceMode(.animation)),
                .separator,
                action(presetTitle(.levelDefault), key: "", selected: activeLayoutPreset == .levelDefault,
                       command: .setLayoutPreset(.levelDefault)),
                action(presetTitle(.levelCinematics), key: "", selected: activeLayoutPreset == .levelCinematics,
                       command: .setLayoutPreset(.levelCinematics)),
                action(presetTitle(.modelingDefault), key: "", selected: activeLayoutPreset == .modelingDefault,
                       command: .setLayoutPreset(.modelingDefault)),
                action(presetTitle(.modelingSculpt), key: "", selected: activeLayoutPreset == .modelingSculpt,
                       command: .setLayoutPreset(.modelingSculpt)),
                action(presetTitle(.animationDefault), key: "", selected: activeLayoutPreset == .animationDefault,
                       command: .setLayoutPreset(.animationDefault)),
                action(presetTitle(.animationSequencer), key: "", selected: activeLayoutPreset == .animationSequencer,
                       command: .setLayoutPreset(.animationSequencer)),
                .separator,
                action(L("Reopen Closed Panel"), key: "t", modifiers: [.primary, .shift],
                       command: .reopenClosedPanel),
                action(L("Reset Layout"), key: "", command: .resetLayout),
            ]),
            EditorApplicationMenu(title: L("Tools"), items: [
                action(L("Play"), key: "",
                       enabled: EditorPlaybackCommandPolicy.canTransition(from: playbackState,
                                                                          to: .playing),
                       selected: playbackState == .playing,
                       command: .setPlaybackState(.playing)),
                action(L("Pause"), key: "",
                       enabled: EditorPlaybackCommandPolicy.canTransition(from: playbackState,
                                                                          to: .paused),
                       selected: playbackState == .paused,
                       command: .setPlaybackState(.paused)),
                action(L("Stop"), key: "",
                       enabled: EditorPlaybackCommandPolicy.canTransition(from: playbackState,
                                                                          to: .stopped),
                       selected: playbackState == .stopped,
                       command: .setPlaybackState(.stopped)),
                .separator,
                action(L("Toggle Theme"), key: "", command: .toggleTheme),
            ]),
            EditorApplicationMenu(title: L("Build"), items: [
                action(L("Build Project"), key: "b", command: .buildProject),
                action(L("Build and Run"), key: "r", command: .buildAndRun),
            ]),
            EditorApplicationMenu(title: L("Help"), items: [
                action(L("Documentation"), key: "", command: .openDocumentation),
                .separator,
                action(L("About Guava"), key: "", command: .about),
            ]),
        ])
    }

    private static func action(_ title: String,
                               key: String,
                               modifiers: EditorMenuKeyModifiers = [.primary],
                               enabled: Bool = true,
                               selected: Bool = false,
                               command: EditorMenuCommand) -> EditorApplicationMenuItem {
        .action(EditorApplicationMenuAction(title: title,
                                            keyEquivalent: key,
                                            keyModifiers: modifiers,
                                            isEnabled: enabled,
                                            isSelected: selected,
                                            command: command))
    }

    private static func presetTitle(_ preset: EditorLayoutPreset) -> String {
        switch preset {
        case .levelDefault:
            return L("Level: Default")
        case .levelCinematics:
            return L("Level: Cinematics")
        case .modelingDefault:
            return L("Modeling: Default")
        case .modelingSculpt:
            return L("Modeling: Sculpt")
        case .animationDefault:
            return L("Animation: Default")
        case .animationSequencer:
            return L("Animation: Sequencer")
        }
    }
}

struct EditorApplicationMenu {
    let title: String
    let items: [EditorApplicationMenuItem]
}

enum EditorApplicationMenuItem {
    case action(EditorApplicationMenuAction)
    case separator
}

struct EditorApplicationMenuAction {
    let title: String
    let keyEquivalent: String
    let keyModifiers: EditorMenuKeyModifiers
    var isEnabled: Bool = true
    var isSelected: Bool = false
    let command: EditorMenuCommand
}

struct EditorMenuKeyModifiers: OptionSet {
    let rawValue: UInt8

    static let command = EditorMenuKeyModifiers(rawValue: 1 << 0)
    static let shift = EditorMenuKeyModifiers(rawValue: 1 << 1)
    static let option = EditorMenuKeyModifiers(rawValue: 1 << 2)
    static let control = EditorMenuKeyModifiers(rawValue: 1 << 3)

    #if os(macOS)
    static let primary: EditorMenuKeyModifiers = .command
    #else
    static let primary: EditorMenuKeyModifiers = .control
    #endif
}
