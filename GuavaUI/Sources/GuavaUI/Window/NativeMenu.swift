import Foundation
import GuavaUIRuntime

public struct NativeMenuBar {
    public var appName: String
    /// Leading entries of the application menu, such as About and Settings.
    /// The platform appends its own window-management and quit entries.
    public var applicationItems: [NativeMenuItem]
    public var applicationTitles: NativeApplicationMenuTitles
    public var menus: [NativeMenu]

    public init(appName: String,
                applicationItems: [NativeMenuItem] = [],
                applicationTitles: NativeApplicationMenuTitles? = nil,
                menus: [NativeMenu]) {
        self.appName = appName
        self.applicationItems = applicationItems
        self.applicationTitles = applicationTitles ?? NativeApplicationMenuTitles(appName: appName)
        self.menus = menus
    }
}

/// Labels for the entries the platform owns in the application menu.
public struct NativeApplicationMenuTitles: Sendable, Equatable {
    public var hide: String
    public var hideOthers: String
    public var showAll: String
    public var quit: String

    public init(appName: String) {
        hide = "Hide \(appName)"
        hideOthers = "Hide Others"
        showAll = "Show All"
        quit = "Quit \(appName)"
    }

    public init(hide: String, hideOthers: String, showAll: String, quit: String) {
        self.hide = hide
        self.hideOthers = hideOthers
        self.showAll = showAll
        self.quit = quit
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
    case submenu(NativeMenu)
    case separator
}

public struct NativeMenuAction {
    public var title: String
    public var keyEquivalent: String
    public var keyModifiers: NativeMenuKeyModifiers
    public var isEnabled: Bool
    public var isSelected: Bool
    /// Re-evaluated when the native menu opens or a key equivalent runs.
    public var isEnabledProvider: (@MainActor () -> Bool)?
    public var action: @MainActor () -> Void

    public init(title: String,
                keyEquivalent: String = "",
                keyModifiers: NativeMenuKeyModifiers = [.primary],
                isEnabled: Bool = true,
                isSelected: Bool = false,
                isEnabledProvider: (@MainActor () -> Bool)? = nil,
                action: @escaping @MainActor () -> Void) {
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.keyModifiers = keyModifiers
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.isEnabledProvider = isEnabledProvider
        self.action = action
    }

    @MainActor public var resolvedIsEnabled: Bool { isEnabledProvider?() ?? isEnabled }
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
        root.addItem(appMenuItem(menuBar))
        for menu in menuBar.menus {
            root.addItem(menuItem(for: menu))
        }

        NSApplication.shared.mainMenu = root
    }

    private static func menuItem(for menu: NativeMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = menu.title
        let submenu = NSMenu(title: menu.title)
        append(menu.items, to: submenu)
        item.submenu = submenu
        return item
    }

    private static func append(_ items: [NativeMenuItem], to menu: NSMenu) {
        for entry in items {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .submenu(let nested):
                menu.addItem(menuItem(for: nested))
            case .action(let action):
                let target = NativeMenuActionTarget(action: action)
                targets.append(target)
                let item = NSMenuItem(title: action.title,
                                      action: #selector(NativeMenuActionTarget.invoke),
                                      keyEquivalent: action.keyEquivalent)
                item.target = target
                item.isEnabled = action.resolvedIsEnabled
                item.state = action.isSelected ? .on : .off
                item.keyEquivalentModifierMask = action.keyModifiers.eventModifiers
                menu.addItem(item)
            }
        }
    }

    private static func appMenuItem(_ menuBar: NativeMenuBar) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: menuBar.appName)
        append(menuBar.applicationItems, to: menu)
        if !menuBar.applicationItems.isEmpty { menu.addItem(.separator()) }
        let titles = menuBar.applicationTitles
        menu.addItem(NSMenuItem(title: titles.hide,
                                action: #selector(NSApplication.hide(_:)),
                                keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: titles.hideOthers,
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(NSMenuItem(title: titles.showAll,
                                action: #selector(NSApplication.unhideAllApplications(_:)),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: titles.quit,
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.submenu = menu
        return item
    }
}

@MainActor
private final class NativeMenuActionTarget: NSObject, NSMenuItemValidation {
    let action: NativeMenuAction

    init(action: NativeMenuAction) {
        self.action = action
    }

    @objc func invoke() {
        guard action.resolvedIsEnabled else { return }
        action.action()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        action.resolvedIsEnabled
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
#elseif os(Windows)
@MainActor
enum NativeMenuInstaller {
    static func install(_ menuBar: NativeMenuBar) {
        // Immersive windows draw their own title bar in the client area, so a
        // Win32 menu strip would sit below it. Apps present the same menu tree
        // inside that title bar instead.
    }
}

#else
@MainActor
enum NativeMenuInstaller {
    static func install(_ menuBar: NativeMenuBar) {}
}
#endif
