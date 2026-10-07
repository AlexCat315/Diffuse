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
                     interactionMode: EditorInteractionMode = .manual,
                     canUndo: Bool = false,
                     canRedo: Bool = false,
                     hasSelection: Bool = false) -> EditorMenuModel {
        let canAuthorScene = EditorSceneAuthoringPolicy.canEditScene(during: playbackState)
        let menus = [
            EditorApplicationMenu(title: L("File"), items: [
                action(L("New Scene"), key: "n", enabled: canAuthorScene, command: .newScene),
                action(L("Open Scene..."), key: "o", enabled: canAuthorScene, command: .openScene),
                action(L("Save Scene"), key: "s", command: .saveScene),
                .separator,
                action(L("Import Assets..."), key: "", command: .importAssets),
                .separator,
                action(L("Close Project / Welcome"), key: "", command: .closeProject),
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
            EditorApplicationMenu(title: L("Workspace"), items: [
                action(L(EditorWorkspaceMode.level.title), key: "1", selected: workspaceMode == .level,
                       command: .setWorkspaceMode(.level)),
                action(L(EditorWorkspaceMode.scripting.title), key: "4", selected: workspaceMode == .scripting,
                       command: .setWorkspaceMode(.scripting)),
                .separator,
                action(L(EditorWorkspaceMode.modeling.title), key: "2", selected: workspaceMode == .modeling,
                       command: .setWorkspaceMode(.modeling)),
                action(L(EditorWorkspaceMode.animation.title), key: "3", selected: workspaceMode == .animation,
                       command: .setWorkspaceMode(.animation)),
                .separator,
                action(L("Manual Editing"), key: "", selected: interactionMode == .manual, command: .setInteractionMode(.manual)),
                action(L("Agent Workbench"), key: "", selected: interactionMode == .agent, command: .setInteractionMode(.agent)),
            ]),
            EditorApplicationMenu(title: L("Layout"), items:
                EditorLayoutPreset.presets(for: workspaceMode).map { preset in
                    action(L(preset.title), key: "", selected: activeLayoutPreset == preset,
                           command: .setLayoutPreset(preset))
                } + [
                    .separator,
                    action(L("Save Layout"), key: "", command: .saveLayout),
                    action(L("Reset Layout"), key: "", command: .resetLayout),
                    .separator,
                    action(L("Maximize Viewport"), key: "", command: .maximizePanel("viewport")),
                    action(L("Restore Panels"), key: "", command: .restorePanels),
                ]),
            EditorApplicationMenu(title: L("Window"), items: [
                action(L("Command Palette"), key: "p", modifiers: [.primary, .shift], command: .showCommandPalette),
                .separator,
                action(L("Viewport"), key: "", command: .showPanel("viewport")),
                action(L("Hierarchy"), key: "", command: .showPanel("hierarchy")),
                action(L("Inspector"), key: "", command: .showPanel("inspector")),
                action(L("Scene Settings"), key: "", command: .showSceneSettings),
                action(L("Assets"), key: "", command: .showAssets),
                action(L("Scripts"), key: "5", command: .showScripts),
                action(L("Console"), key: "", command: .showPanel("console")),
                action(L("Animation"), key: "", command: .showPanel("animation")),
                action(L("Render Pipeline"), key: "", command: .showPanel("render-pipeline")),
                action(L("Developer Tools"), key: "", command: .showPanel("developer-tools")),
                action(L("AI"), key: "", command: .showPanel("intent-input")),
                .separator,
                action(L("Reopen Closed Panel"), key: "t", modifiers: [.primary, .shift],
                       command: .reopenClosedPanel),
            ]),
            EditorApplicationMenu(title: L("Tools"), items: [
                action(L("Play"), key: "",
                       enabled: workspaceMode.isGameWorkspace && EditorPlaybackCommandPolicy.canTransition(from: playbackState,
                                                                          to: .playing),
                       selected: playbackState == .playing,
                       command: .setPlaybackState(.playing)),
                action(L("Pause"), key: "",
                       enabled: workspaceMode.isGameWorkspace && EditorPlaybackCommandPolicy.canTransition(from: playbackState,
                                                                          to: .paused),
                       selected: playbackState == .paused,
                       command: .setPlaybackState(.paused)),
                action(L("Stop"), key: "",
                       enabled: workspaceMode.isGameWorkspace && EditorPlaybackCommandPolicy.canTransition(from: playbackState,
                                                                          to: .stopped),
                       selected: playbackState == .stopped,
                       command: .setPlaybackState(.stopped)),
                .separator,
                action(L("Toggle Theme"), key: "", command: .toggleTheme),
            ]),
            EditorApplicationMenu(title: L("Build"), items: [
                action(L("Build Project"), key: "b", enabled: workspaceMode.isGameWorkspace, command: .buildProject),
                action(L("Build and Run"), key: "r", enabled: workspaceMode.isGameWorkspace, command: .buildAndRun),
            ]),
            EditorApplicationMenu(title: L("Help"), items: [
                action(L("Documentation"), key: "", command: .openDocumentation),
                .separator,
                action(L("About Guava"), key: "", command: .about),
            ]),
        ]
        return EditorMenuModel(menus: menus.compactMap { menu in
            if interactionMode == .agent && menu.title == L("Layout") { return nil }
            var items: [EditorApplicationMenuItem] = []
            for item in menu.items {
                if case .action(let action) = item,
                   !EditorWorkspaceCommandPolicy.allows(action.command, in: workspaceMode) { continue }
                if case .separator = item {
                    guard !items.isEmpty else { continue }
                    if case .separator = items.last { continue }
                }
                items.append(item)
            }
            if case .separator = items.last { items.removeLast() }
            return items.isEmpty ? nil : EditorApplicationMenu(title: menu.title, items: items)
        })
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
