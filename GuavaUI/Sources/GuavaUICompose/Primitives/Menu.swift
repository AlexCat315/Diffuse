import EngineKernel
import Foundation
import GuavaUIRuntime

public enum MenuItemRole: Sendable, Equatable { case normal, destructive }

public struct MenuItem {
    public let id: AnyHashable
    public let title: String
    public let shortcut: String?
    public let isEnabled: Bool
    public let isSelected: Bool
    public let role: MenuItemRole
    public let action: () -> Void
    public init<ID: Hashable>(id: ID, title: String, shortcut: String? = nil,
        isEnabled: Bool = true, isSelected: Bool = false, role: MenuItemRole = .normal,
        action: @escaping () -> Void) {
        self.id = AnyHashable(id); self.title = title; self.shortcut = shortcut
        self.isEnabled = isEnabled; self.isSelected = isSelected; self.role = role; self.action = action
    }
    public init(title: String, shortcut: String? = nil, isEnabled: Bool = true,
        isSelected: Bool = false, role: MenuItemRole = .normal, action: @escaping () -> Void) {
        self.init(id: title, title: title, shortcut: shortcut, isEnabled: isEnabled,
                  isSelected: isSelected, role: role, action: action)
    }
}

/// A branch has children rather than a command. Its authored settings do not
/// contain the hovered row, focus, timers or portal identifiers.
public struct MenuSubmenu {
    public let id: AnyHashable
    public let title: String
    public var entries: [MenuEntry]
    public var isEnabled = true
    public var width: Float = 220
    public init<ID: Hashable>(id: ID, title: String, entries: [MenuEntry],
                             configure: (inout Self) -> Void = { _ in }) {
        self.id = AnyHashable(id); self.title = title; self.entries = entries
        configure(&self)
        width = width.isFinite ? max(80, width) : 220
    }
}

public enum MenuEntry {
    case item(MenuItem)
    case submenu(MenuSubmenu)
    case label(id: AnyHashable, title: String)
    case separator(id: AnyHashable)
    public static func separator<ID: Hashable>(_ id: ID) -> Self { .separator(id: AnyHashable(id)) }
    public static func separator() -> Self { .separator(id: AnyHashable(UUID())) }
    var id: AnyHashable {
        switch self {
        case .item(let item): item.id
        case .submenu(let branch): branch.id
        case .label(let id, _), .separator(let id): id
        }
    }
    var row: MenuRowPresentation? {
        switch self {
        case .item(let item): MenuRowPresentation(item: item)
        case .submenu(let branch): MenuRowPresentation(submenu: branch)
        default: nil
        }
    }
}

public struct Menu: View {
    public let entries: [MenuEntry]
    public let width: Float?
    public let maxVisibleRows: Int
    public let onItemActivated: (() -> Void)?
    public let onDismiss: (() -> Void)?
    public init(_ entries: [MenuEntry], width: Float? = nil, maxVisibleRows: Int = 8,
                onItemActivated: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        self.entries = entries
        self.width = width.map { $0.isFinite ? max(80, $0) : 220 }
        self.maxVisibleRows = max(1, maxVisibleRows)
        self.onItemActivated = onItemActivated; self.onDismiss = onDismiss
    }
    public var body: some View {
        MenuLevel(configuration: MenuLevelConfiguration(entries: entries, width: width,
            maxVisibleRows: maxVisibleRows, onItemActivated: { onItemActivated?() },
            onDismiss: { (onDismiss ?? onItemActivated)?() }))
    }
}

struct MenuLevelConfiguration {
    let entries: [MenuEntry]
    let width: Float?
    var maxVisibleRows = 12
    var onItemActivated: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onCloseLevel: (() -> Void)?
}

struct MenuLevel: View {
    let configuration: MenuLevelConfiguration
    @State private var session = MenuSession()
    private var enabled: [AnyHashable] {
        configuration.entries.compactMap { entry in entry.row?.isEnabled == true ? entry.id : nil }
    }
    private var effectiveHighlight: AnyHashable? {
        if let highlighted = session.navigation.highlighted, enabled.contains(highlighted) { return highlighted }
        return configuration.entries.first { $0.row?.isEnabled == true && $0.row?.isSelected == true }?.id ?? enabled.first
    }
    var body: some View {
        MenuLevelHost(hoverIntent: session.hoverIntent, onKey: handleKey, onText: handleText) {
            Box(direction: .column, alignItems: .stretch) {
                ScrollView(.vertical, consumePolicy: .always, scrollbarGutter: .stable,
                    scrollOffset: Binding(get: { session.scrollOffset }, set: { if session.scrollOffset != $0 { session.scrollOffset = $0 } })) {
                    Box(direction: .column, alignItems: .stretch, spacing: 1) { rows() }
                }
                .frame(maxHeight: Float(configuration.maxVisibleRows) * 32)
                .modifier(MenuWindowBounds())
                .modifier(MenuScrollMarker())
            }
            .background(.surfaceFloating).cornerRadius(6).border(.border, width: 1).surfaceFinish()
            .frame(width: configuration.width)
        }
    }
    private func rows() -> [AnyView] {
        let selectionColumn = configuration.entries.contains { $0.row?.isSelected == true }
        return configuration.entries.map { entry in
            guard let row = entry.row else {
                switch entry {
                case .label(_, let title):
                    return AnyView(Text(title).font(.caption).foregroundColor(.onSurfaceMuted)
                        .padding(horizontal: 16, vertical: 5).id(entry.id))
                default: return AnyView(Box(direction: .column, alignItems: .stretch) { Divider() }
                    .padding(horizontal: 8, vertical: 3).id(entry.id))
                }
            }
            let submenu: AnyView?
            if case .submenu(let branch) = entry, session.navigation.opened == entry.id, row.isEnabled {
                submenu = AnyView(FocusScope(restoresCommands: true) {
                    MenuLevel(configuration: MenuLevelConfiguration(entries: branch.entries, width: branch.width,
                        onItemActivated: { session.navigation.opened = nil; configuration.onItemActivated() },
                        onDismiss: { session.navigation.opened = nil; configuration.onDismiss() },
                        onCloseLevel: { session.navigation.opened = nil }))
                })
            } else { submenu = nil }
            let events = MenuRowEvents(activate: { node in activate(entry, node: node) },
                hover: { node, inside in hovered(entry, node: node, inside: inside) },
                focus: { if effectiveHighlight != entry.id { session.navigation.highlighted = entry.id } },
                reveal: reveal, closeSubmenu: { if session.navigation.opened == entry.id { session.navigation.opened = nil } })
            return AnyView(MenuItemRowHost(item: row, isHighlighted: effectiveHighlight == entry.id,
                showsSelectionColumn: selectionColumn, submenu: submenu, events: events,
                revealToken: session.navigation.revealToken).id(entry.id))
        }
    }
    private func activate(_ entry: MenuEntry, node: Node) {
        guard entry.row?.isEnabled == true else { return }
        session.hoverIntent.cancel()
        if effectiveHighlight != entry.id { session.navigation.highlighted = entry.id }
        if case .submenu = entry {
            FocusChainHolder.current?.focus(node, visible: FocusChainHolder.current?.isFocusVisible ?? true)
            session.navigation.opened = entry.id
        } else if case .item(let item) = entry {
            session.navigation.opened = nil; item.action(); configuration.onItemActivated()
        }
    }
    private func hovered(_ entry: MenuEntry, node: Node, inside: Bool) {
        guard inside else { session.hoverIntent.cancel(id: entry.id); return }
        session.hoverIntent.schedule(id: entry.id) { [weak node] in
            guard let node, node.acceptsSubtreeInput else { return }
            session.navigation.highlighted = entry.id
            FocusChainHolder.current?.focus(node, visible: false)
            session.navigation.opened = entry.row?.hasSubmenu == true ? entry.id : nil
        }
    }
    private func handleKey(_ event: KeyEvent, root: Node) -> Bool {
        let command: SelectionNavigation?
        switch event.scancode {
        case Scancode.arrowDown: command = .next
        case Scancode.arrowUp: command = .previous
        case Scancode.home: command = .first
        case Scancode.end: command = .last
        case Scancode.escape:
            session.hoverIntent.cancel(); session.navigation.opened = nil
            if let close = configuration.onCloseLevel { close() } else { configuration.onDismiss() }
            return true
        case Scancode.tab: session.hoverIntent.cancel(); session.navigation.opened = nil; configuration.onDismiss(); return true
        case Scancode.arrowLeft:
            guard let close = configuration.onCloseLevel else { return false }
            session.hoverIntent.cancel(); session.navigation.opened = nil; close(); return true
        case Scancode.arrowRight, Scancode.return, Scancode.keypadEnter, Scancode.space:
            if event.isRepeat { return true }
            guard let id = effectiveHighlight, let entry = configuration.entries.first(where: { $0.id == id }),
                  let row = menuRow(id, in: root) else { return false }
            if event.scancode == Scancode.arrowRight && entry.row?.hasSubmenu != true { return false }
            activate(entry, node: row); return true
        default: return false
        }
        guard let destination = command?.destination(in: enabled, from: effectiveHighlight) else { return true }
        select(destination, root: root); return true
    }
    private func handleText(_ text: String, root: Node) -> Bool {
        let rows = configuration.entries.compactMap(\.row).filter(\.isEnabled)
        if let target = session.typeahead.destination(text, rows: rows, from: effectiveHighlight) { select(target, root: root) }
        return true
    }
    private func select(_ id: AnyHashable, root: Node) {
        session.hoverIntent.cancel(); session.navigation.opened = nil; session.navigation.highlighted = id; session.navigation.revealToken &+= 1
        if let row = menuRow(id, in: root) {
            FocusChainHolder.current?.focus(row); reveal(row)
        }
    }
    private func reveal(_ row: Node) {
        var ancestor = row.parent
        while let node = ancestor {
            if node.attachments[MenuScrollMarker.key] as? Bool == true {
                let rect = row.absoluteFrame, viewport = node.absoluteFrame
                var next = session.scrollOffset
                if rect.minY < viewport.minY { next.y = max(0, next.y + rect.minY - viewport.minY) }
                else if rect.maxY > viewport.maxY { next.y += rect.maxY - viewport.maxY }
                if next != session.scrollOffset { session.scrollOffset = next }
                return
            }
            ancestor = node.parent
        }
    }
}

public extension Menu {
    init(descriptor: MenuDescriptor, width: Float? = nil, maxVisibleRows: Int = 8,
         onItemActivated: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        self.init(Self.entries(descriptor.items), width: width, maxVisibleRows: maxVisibleRows,
                  onItemActivated: onItemActivated, onDismiss: onDismiss)
    }
    private static func entries(_ items: [MenuItemDescriptor]) -> [MenuEntry] {
        items.enumerated().map { index, item in
            switch item {
            case .separator: .separator(index)
            case .label(let title): .label(id: AnyHashable(index), title: title)
            case .action(let title, let shortcut, let enabled, let action):
                .item(MenuItem(id: index, title: title, shortcut: shortcut?.displayString, isEnabled: enabled, action: action))
            case .submenu(let title, let enabled, let children):
                .submenu(MenuSubmenu(id: index, title: title, entries: entries(children), configure: { $0.isEnabled = enabled }))
            }
        }
    }
}
