import Foundation
import GuavaUIRuntime

public struct NativeMenuBar {
    public var appName: String
    public var menus: [NativeMenu]

    public init(appName: String, menus: [NativeMenu]) {
        self.appName = appName
        self.menus = menus
    }
}

public struct NativeMenu {
    public var title: String
    public var items: [NativeMenuItem]

    public init(title: String, items: [NativeMenuItem]) {
        self.title = title
        self.items = items
    }
}

public enum NativeMenuItem {
    case action(NativeMenuAction)
    case separator
}

public struct NativeMenuAction {
    public var title: String
    public var keyEquivalent: String
    public var keyModifiers: NativeMenuKeyModifiers
    public var isEnabled: Bool
    public var isSelected: Bool
    public var action: @MainActor () -> Void

    public init(title: String,
                keyEquivalent: String = "",
                keyModifiers: NativeMenuKeyModifiers = [.primary],
                isEnabled: Bool = true,
                isSelected: Bool = false,
                action: @escaping @MainActor () -> Void) {
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.keyModifiers = keyModifiers
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.action = action
    }
}

public struct NativeMenuKeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = NativeMenuKeyModifiers(rawValue: 1 << 0)
    public static let shift = NativeMenuKeyModifiers(rawValue: 1 << 1)
    public static let option = NativeMenuKeyModifiers(rawValue: 1 << 2)
    public static let control = NativeMenuKeyModifiers(rawValue: 1 << 3)

    #if os(macOS)
    public static let primary: NativeMenuKeyModifiers = .command
    #else
    public static let primary: NativeMenuKeyModifiers = .control
    #endif
}

#if os(macOS)
import AppKit

@MainActor
enum NativeMenuInstaller {
    private static var targets: [NativeMenuActionTarget] = []

    static func install(_ menuBar: NativeMenuBar) {
        targets.removeAll(keepingCapacity: true)

        let root = NSMenu(title: menuBar.appName)
        root.addItem(appMenuItem(appName: menuBar.appName))

        for menu in menuBar.menus {
            let item = NSMenuItem()
            item.title = menu.title
            let submenu = NSMenu(title: menu.title)
            for menuItem in menu.items {
                switch menuItem {
                case .separator:
                    submenu.addItem(.separator())
                case .action(let action):
                    let target = NativeMenuActionTarget(action: action.action)
                    targets.append(target)
                    let item = NSMenuItem(title: action.title,
                                          action: #selector(NativeMenuActionTarget.invoke),
                                          keyEquivalent: action.keyEquivalent)
                    item.target = target
                    item.isEnabled = action.isEnabled
                    item.state = action.isSelected ? .on : .off
                    item.keyEquivalentModifierMask = action.keyModifiers.eventModifiers
                    submenu.addItem(item)
                }
            }
            item.submenu = submenu
            root.addItem(item)
        }

        NSApplication.shared.mainMenu = root
    }

    private static func appMenuItem(appName: String) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: appName)
        menu.addItem(NSMenuItem(title: "Quit \(appName)",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.submenu = menu
        return item
    }
}

@MainActor
private final class NativeMenuActionTarget: NSObject {
    let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func invoke() {
        action()
    }
}

private extension NativeMenuKeyModifiers {
    var eventModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}
#else
@MainActor
enum NativeMenuInstaller {
    static func install(_ menuBar: NativeMenuBar) {}
}
#endif
