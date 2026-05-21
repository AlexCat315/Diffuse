import EditorCore
import GuavaUIApp

enum EditorNativeMenuBuilder {
    static func make(appName: String = "GuavaNext Editor",
                     workspaceMode: EditorWorkspaceMode,
                     activeLayoutPreset: EditorLayoutPreset,
                     playbackState: PlaybackState,
                     onCommand: @escaping @MainActor (EditorMenuCommand) -> Void) -> NativeMenuBar {
        let model = EditorMenuModel.make(workspaceMode: workspaceMode,
                                         activeLayoutPreset: activeLayoutPreset,
                                         playbackState: playbackState)
        let menus = model.menus.map { menu in
            NativeMenu(title: menu.title,
                       items: menu.items.map { nativeItem($0, onCommand: onCommand) })
        }
        return NativeMenuBar(appName: appName, menus: menus)
    }

    private static func nativeItem(_ item: EditorApplicationMenuItem,
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
