import EditorCore
import GuavaUIApp
import GuavaUIRuntime

enum EditorNativeMenuBuilder {
    static func make(appName: String = "GuavaNext Editor",
                     workspaceMode: EditorWorkspaceMode,
                     activeLayoutPreset: EditorLayoutPreset,
                     playbackState: PlaybackState,
                     interactionMode: EditorInteractionMode = .manual,
                     canUndo: Bool = false,
                     canRedo: Bool = false,
                     hasSelection: Bool = false,
                     focusChain: @escaping @MainActor () -> FocusChain? = { FocusChainHolder.current },
                     onCommand: @escaping @MainActor (EditorMenuCommand) -> Void) -> NativeMenuBar {
        let model = EditorMenuModel.make(workspaceMode: workspaceMode,
                                         activeLayoutPreset: activeLayoutPreset,
                                         playbackState: playbackState,
                             interactionMode: interactionMode,
                                         canUndo: canUndo,
                                         canRedo: canRedo,
                                         hasSelection: hasSelection)
        let menus = model.menus.map { menu in
            NativeMenu(title: menu.title,
                       items: menu.items.map { nativeItem($0, focusChain: focusChain, onCommand: onCommand) })
        }
        return NativeMenuBar(appName: appName, menus: menus)
    }

    private static func nativeItem(_ item: EditorApplicationMenuItem,
                                   focusChain: @escaping @MainActor () -> FocusChain?,
                                   onCommand: @escaping @MainActor (EditorMenuCommand) -> Void) -> NativeMenuItem {
        switch item {
        case .separator:
            return .separator
        case .action(let action):
            return .action(NativeMenuAction(title: action.title,
                                            keyEquivalent: action.keyEquivalent,
                                            keyModifiers: action.keyModifiers.nativeModifiers,
                                            isEnabled: action.isEnabled,
                                            isSelected: action.isSelected,
                                            isEnabledProvider: {
                                                EditorCommandDispatcher.isEnabled(action.command,
                                                                                  sceneCommandEnabled: action.isEnabled,
                                                                                  focusChain: focusChain())
                                            },
                                            action: {
                                                onCommand(action.command)
                                            }))
        }
    }
}

private extension EditorMenuKeyModifiers {
    var nativeModifiers: NativeMenuKeyModifiers {
        var out: NativeMenuKeyModifiers = []
        if contains(.command) { out.insert(.command) }
        if contains(.shift) { out.insert(.shift) }
        if contains(.option) { out.insert(.option) }
        if contains(.control) { out.insert(.control) }
        return out
    }
}
