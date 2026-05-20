import EditorCore
import GuavaUIApp

enum EditorNativeMenuBuilder {
    static func make(appName: String = "GuavaNext Editor",
                     workspaceMode: EditorWorkspaceMode,
                     activeLayoutPreset: EditorLayoutPreset,
                     playbackState: PlaybackState,
                     onCommand: @escaping @MainActor (EditorMenuCommand) -> Void) -> NativeMenuBar {
        NativeMenuBar(appName: appName, menus: [
            NativeMenu(title: L("File"), items: [
                action(L("New Scene"), key: "n") { onCommand(.newScene) },
                action(L("Open Scene..."), key: "o") { onCommand(.openScene) },
                action(L("Save Scene"), key: "s") { onCommand(.saveScene) },
                .separator,
                action(L("Import Assets..."), key: "") { onCommand(.importAssets) },
            ]),
            NativeMenu(title: L("Edit"), items: [
                action(L("Undo"), key: "z") { onCommand(.undo) },
                action(L("Redo"), key: "z", modifiers: [.primary, .shift]) { onCommand(.redo) },
                .separator,
                action(L("Settings"), key: ",") { onCommand(.openSettings) },
            ]),
            NativeMenu(title: L("Window"), items: [
                action(L("Workspace: Level"), key: "", selected: workspaceMode == .level) {
                    onCommand(.setWorkspaceMode(.level))
                },
                action(L("Workspace: Modeling"), key: "", selected: workspaceMode == .modeling) {
                    onCommand(.setWorkspaceMode(.modeling))
                },
                action(L("Workspace: Animation"), key: "", selected: workspaceMode == .animation) {
                    onCommand(.setWorkspaceMode(.animation))
                },
                .separator,
                action(presetTitle(.levelDefault), key: "", selected: activeLayoutPreset == .levelDefault) {
                    onCommand(.setLayoutPreset(.levelDefault))
                },
                action(presetTitle(.levelCinematics), key: "", selected: activeLayoutPreset == .levelCinematics) {
                    onCommand(.setLayoutPreset(.levelCinematics))
                },
                action(presetTitle(.modelingDefault), key: "", selected: activeLayoutPreset == .modelingDefault) {
                    onCommand(.setLayoutPreset(.modelingDefault))
                },
                action(presetTitle(.modelingSculpt), key: "", selected: activeLayoutPreset == .modelingSculpt) {
                    onCommand(.setLayoutPreset(.modelingSculpt))
                },
                action(presetTitle(.animationDefault), key: "", selected: activeLayoutPreset == .animationDefault) {
                    onCommand(.setLayoutPreset(.animationDefault))
                },
                action(presetTitle(.animationSequencer), key: "", selected: activeLayoutPreset == .animationSequencer) {
                    onCommand(.setLayoutPreset(.animationSequencer))
                },
                .separator,
                action(L("Reset Layout"), key: "") { onCommand(.resetLayout) },
            ]),
            NativeMenu(title: L("Tools"), items: [
                action(L("Play"), key: "", selected: playbackState == .playing) {
                    onCommand(.setPlaybackState(.playing))
                },
                action(L("Pause"), key: "", selected: playbackState == .paused) {
                    onCommand(.setPlaybackState(.paused))
                },
                action(L("Stop"), key: "", selected: playbackState == .stopped) {
                    onCommand(.setPlaybackState(.stopped))
                },
                .separator,
                action(L("Toggle Theme"), key: "") { onCommand(.toggleTheme) },
            ]),
            NativeMenu(title: L("Build"), items: [
                action(L("Build Editor"), key: "b") { onCommand(.buildProject) },
                action(L("Build and Run"), key: "r") { onCommand(.buildAndRun) },
            ]),
            NativeMenu(title: L("Help"), items: [
                action(L("Documentation"), key: "") { onCommand(.openDocumentation) },
                .separator,
                action(L("About Guava"), key: "") { onCommand(.about) },
            ]),
        ])
    }

    private static func action(_ title: String,
                               key: String,
                               modifiers: NativeMenuKeyModifiers = [.primary],
                               selected: Bool = false,
                               handler: @escaping @MainActor () -> Void) -> NativeMenuItem {
        .action(NativeMenuAction(title: title,
                                 keyEquivalent: key,
                                 keyModifiers: modifiers,
                                 isSelected: selected,
                                 action: handler))
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
