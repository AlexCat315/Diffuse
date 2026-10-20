private import Foundation
internal import GuavaUI
internal import GuavaUIRuntime

/// Projects the command catalog onto the platform menu bar.
enum EditorNativeMenuBuilder {
    static func make(appName: String = "GuavaStudio",
                     catalog: EditorCommandCatalog,
                     focusChain: @escaping @MainActor () -> FocusChain? = { FocusChainHolder.current },
                     onCommand: @escaping @MainActor (EditorCommand) -> Void) -> NativeMenuBar {
        func nativeItems(_ items: [EditorCommandItem]) -> [NativeMenuItem] {
            items.map { item in
                switch item {
                case .separator:
                    return .separator
                case let .submenu(menu):
                    return .submenu(NativeMenu(title: menu.title, items: nativeItems(menu.items)))
                case let .entry(entry):
                    return .action(NativeMenuAction(
                        title: entry.title,
                        keyEquivalent: entry.shortcut?.key.equivalent ?? "",
                        keyModifiers: entry.shortcut?.modifiers.native ?? [],
                        isEnabled: entry.isEnabled,
                        isSelected: entry.isSelected,
                        isEnabledProvider: {
                            EditorCommandDispatcher.isEnabled(entry.command,
                                                              sceneCommandEnabled: entry.isEnabled,
                                                              focusChain: focusChain())
                        },
                        action: { onCommand(entry.command) }))
                }
            }
        }
        return NativeMenuBar(
            appName: appName,
            applicationItems: nativeItems(catalog.applicationItems),
            applicationTitles: applicationTitles(appName: appName),
            menus: catalog.menus.map { NativeMenu(title: $0.title, items: nativeItems($0.items)) })
    }

    /// The menu bar while no project is open: only the platform entries.
    static func welcome(appName: String = "GuavaStudio") -> NativeMenuBar {
        NativeMenuBar(appName: appName, applicationTitles: applicationTitles(appName: appName), menus: [])
    }

    private static func applicationTitles(appName: String) -> NativeApplicationMenuTitles {
        NativeApplicationMenuTitles(hide: String(format: L("Hide %@"), appName),
                                    hideOthers: L("Hide Others"),
                                    showAll: L("Show All"),
                                    quit: String(format: L("Quit %@"), appName))
    }
}
