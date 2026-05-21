import EngineKernel
import Foundation
import GuavaUIRuntime

private enum SelectIcons {
    static let chevronDown = BundleImageResource.svg(named: "chevron-down",
                                                      in: .module,
                                                      subdirectory: "UIIcons")
    static let chevronUp = BundleImageResource.svg(named: "chevron-up",
                                                    in: .module,
                                                    subdirectory: "UIIcons")
    static let checkmark = BundleImageResource.svg(named: "checkmark",
                                                    in: .module,
                                                    subdirectory: "UIIcons")
}

public enum KeyboardShortcutPlatform: Sendable, Equatable {
    case macOS
    case windows
    case linux
    case other

    public static var current: KeyboardShortcutPlatform {
        #if os(macOS)
        return .macOS
        #elseif os(Windows)
        return .windows
        #elseif os(Linux)
        return .linux
        #else
        return .other
        #endif
    }
}

public enum KeyboardShortcutModifier: Sendable, Equatable, Hashable {
    case primary
    case command
    case control
    case option
    case shift
}

public struct KeyboardShortcut: Sendable, Equatable, Hashable {
    public var modifiers: [KeyboardShortcutModifier]
    public var key: String

    public init(_ key: String, modifiers: [KeyboardShortcutModifier] = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public static func primary(_ key: String) -> KeyboardShortcut {
        KeyboardShortcut(key, modifiers: [.primary])
    }

    public static func primaryShift(_ key: String) -> KeyboardShortcut {
        KeyboardShortcut(key, modifiers: [.primary, .shift])
    }

    public var displayString: String {
        displayString(platform: .current)
    }

    public func displayString(platform: KeyboardShortcutPlatform) -> String {
        let labels = resolvedModifiers(for: platform).map { modifierDisplay($0, platform: platform) }
        switch platform {
        case .macOS:
            return labels.joined() + key
        case .windows, .linux, .other:
            return (labels + [key]).joined(separator: "+")
        }
    }

    private func resolvedModifiers(for platform: KeyboardShortcutPlatform) -> [KeyboardShortcutModifier] {
        var resolved: [KeyboardShortcutModifier] = []
        for modifier in modifiers {
            let platformModifier: KeyboardShortcutModifier
            if modifier == .primary {
                platformModifier = platform == .macOS ? .command : .control
            } else {
                platformModifier = modifier
            }
            if !resolved.contains(platformModifier) {
                resolved.append(platformModifier)
            }
        }
        return resolved
    }

    private func modifierDisplay(_ modifier: KeyboardShortcutModifier,
                                 platform: KeyboardShortcutPlatform) -> String {
        switch platform {
        case .macOS:
            switch modifier {
            case .primary, .command: return "⌘"
            case .control: return "⌃"
            case .option: return "⌥"
            case .shift: return "⇧"
            }
        case .windows, .linux, .other:
            switch modifier {
            case .primary, .control: return "Ctrl"
            case .command: return "Meta"
            case .option: return "Alt"
            case .shift: return "Shift"
            }
        }
    }
}

public enum MenuItemRole: Sendable {
    case normal
    case destructive
}

public struct MenuItem {
    public let id: AnyHashable
    public let title: String
    public let shortcut: String?
    public let isEnabled: Bool
    public let role: MenuItemRole
    public let action: () -> Void

    public init<ID: Hashable>(id: ID,
                              title: String,
                              shortcut: String? = nil,
                              isEnabled: Bool = true,
                              role: MenuItemRole = .normal,
                              action: @escaping () -> Void) {
        self.id = AnyHashable(id)
        self.title = title
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.role = role
        self.action = action
    }

    public init(title: String,
                shortcut: String? = nil,
                isEnabled: Bool = true,
                role: MenuItemRole = .normal,
                action: @escaping () -> Void) {
        self.id = AnyHashable(UUID().uuidString)
        self.title = title
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.role = role
        self.action = action
    }
}

public enum MenuEntry {
    case item(MenuItem)
    case separator(id: AnyHashable)

    public static func separator<ID: Hashable>(_ id: ID) -> MenuEntry {
        .separator(id: AnyHashable(id))
    }

    public static func separator() -> MenuEntry {
        .separator(id: AnyHashable(UUID().uuidString))
    }

    var id: AnyHashable {
        switch self {
        case .item(let item):
            return item.id
        case .separator(let id):
            return id
        }
    }
}

public struct Menu: View {
    public let entries: [MenuEntry]
    public let width: Float?
    public let maxVisibleRows: Int
    public let onItemActivated: (() -> Void)?
    public let highlightedIndex: Int?

    public init(_ entries: [MenuEntry],
                width: Float? = nil,
                maxVisibleRows: Int = 8,
                highlightedIndex: Int? = nil,
                onItemActivated: (() -> Void)? = nil) {
        self.entries = entries
        self.width = width
        self.maxVisibleRows = max(1, maxVisibleRows)
        self.highlightedIndex = highlightedIndex
        self.onItemActivated = onItemActivated
    }

    public var body: some View {
        let rowHeight: Float = 32
        let shouldScroll = entries.count > maxVisibleRows
        let listHeight = Float(maxVisibleRows) * rowHeight
        Box(direction: .column, alignItems: .stretch, spacing: 1) {
            if shouldScroll {
                ScrollView(.vertical) {
                    Box(direction: .column, alignItems: .stretch, spacing: 1) {
                        rows()
                    }
                }
                .frame(height: listHeight)
            } else {
                rows()
            }
        }
        .background(.surfaceFloating)
        .cornerRadius(6)
        .border(.border, width: 1)
        .ifLet(width) { view, width in
            view.frame(width: width)
        }
    }

    private func rows() -> [AnyView] {
        var itemIndex = 0
        return entries.map { entry in
            let isHighlighted: Bool = {
                if case .item = entry {
                    defer { itemIndex += 1 }
                    return highlightedIndex == itemIndex
                }
                return false
            }()
            return AnyView(menuEntry(entry, isHighlighted: isHighlighted).id(entry.id))
        }
    }

    private func menuEntry(_ entry: MenuEntry, isHighlighted: Bool) -> some View {
        switch entry {
        case .separator:
            return AnyView(
                Divider(color: nil, thickness: 1, axis: .horizontal)
                    .background(.divider)
            )
        case .item(let item):
            let row = Row(alignment: .center, spacing: 8) {
                Text(item.title)
                    .font(.body)
                    .foregroundColor(.onSurface)
                    .flex()
                if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
            }
            .padding(horizontal: 10, vertical: 7)
            return AnyView(
                Button(role: item.role == .destructive ? .destructive : .normal,
                       isEnabled: item.isEnabled,
                       action: {
                    item.action()
                    onItemActivated?()
                }) {
                    if isHighlighted {
                        row.background(.surfaceVariant)
                    } else {
                        row
                    }
                }
                .buttonStyle(.ghost)
            )
        }
    }
}

public extension Menu {
    init(descriptor: MenuDescriptor,
         width: Float? = nil,
         maxVisibleRows: Int = 8,
         onItemActivated: (() -> Void)? = nil) {
        self.entries = descriptor.items.enumerated().map { index, item in
            switch item {
            case .separator:
                return .separator(id: AnyHashable("sep-\(index)"))
            case .action(let title, let shortcut, let isEnabled, let action):
                return .item(MenuItem(
                    id: "item-\(index)",
                    title: title,
                    shortcut: shortcut?.displayString,
                    isEnabled: isEnabled,
                    role: .normal,
                    action: action
                ))
            }
        }
        self.width = width
        self.maxVisibleRows = max(1, maxVisibleRows)
        self.highlightedIndex = nil
        self.onItemActivated = onItemActivated
    }
}

public struct Popover<Label: View, Content: View>: View {
    public let isPresented: Binding<Bool>
    public let isEnabled: Bool
    public let width: Float?
    public let label: Label
    public let content: Content
    public let onKey: ((KeyEvent, EventPhase) -> EventResult)?

    public init(isPresented: Binding<Bool>,
                isEnabled: Bool = true,
                width: Float? = nil,
                onKey: ((KeyEvent, EventPhase) -> EventResult)? = nil,
                @ViewBuilder label: () -> Label,
                @ViewBuilder content: () -> Content) {
        self.isPresented = isPresented
        self.isEnabled = isEnabled
        self.width = width
        self.onKey = onKey
        self.label = label()
        self.content = content()
    }

    public var body: some View {
        Box(direction: .column, alignItems: .flexStart, spacing: 0) {
            Button(role: .normal,
                   isEnabled: isEnabled,
                   action: {
                isPresented.wrappedValue.toggle()
            }) {
                label
            }
            .buttonStyle(.plain)

            if isPresented.wrappedValue {
                _PopoverOverlayHost(width: width, keyHandler: onKey) {
                    Box(direction: .column, alignItems: .stretch, spacing: 0) {
                        content
                    }
                    .padding(EdgeInsets(top: 2, leading: 0, bottom: 0, trailing: 0))
                }
            }
        }
        .zIndex(isPresented.wrappedValue ? 10_000 : 0)
        .modifier(_PopoverFrontmostModifier(isPresented: isPresented.wrappedValue))
    }
}

private struct _PopoverFrontmostModifier: ViewModifier {
    let isPresented: Bool

    func apply(node: Node) {
        // When the popover closes, clean up the portal entry that
        // _PopoverOverlayHost registered. Visual ordering is already
        // handled by _PortalLayer's elevated zIndex — reordering the
        // node tree is unnecessary and inverts hit-test priority.
        guard !isPresented else { return }
        if let entryID = node.attachments["__popover_entry_id"] as? String {
            PortalRegistry.unregister(entryID)
            node.attachments.removeValue(forKey: "__popover_entry_id")
        }
    }
}

private struct _PopoverOverlayHost<Content: View>: _PrimitiveView {
    let width: Float?
    let content: Content
    let keyHandler: ((KeyEvent, EventPhase) -> EventResult)?

    init(width: Float?,
         keyHandler: ((KeyEvent, EventPhase) -> EventResult)? = nil,
         @ViewBuilder content: () -> Content) {
        self.width = width
        self.keyHandler = keyHandler
        self.content = content()
    }

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _updateNode(_ node: Node) {
        // Compute absolute position from the trigger container (parent Box)
        let boxNode = node.parent
        var absX: CGFloat = 0
        var absY: CGFloat = 0
        var current = boxNode
        while let n = current {
            absX += n.frame.origin.x
            absY += n.frame.origin.y
            current = n.parent
        }
        let overlayY = absY + (boxNode?.frame.height ?? 0)
        let position = CGPoint(x: absX, y: overlayY)

        // Register / update the portal overlay entry
        if let entryID = node.attachments["__popover_entry_id"] as? String {
            PortalRegistry.updatePosition(entryID, position: position)
            PortalRegistry.updateContent(entryID, content: AnyView(content))
        } else {
            let entryID = PortalRegistry.register(
                position: position,
                width: width,
                content: AnyView(content)
            )
            node.attachments["__popover_entry_id"] = entryID
            // Also store on parent so _PopoverFrontmostModifier can clean up
            boxNode?.attachments["__popover_entry_id"] = entryID
        }

        // Keyboard handler
        node.isFocusable = keyHandler != nil
        if let keyHandler, let registry = InteractionRegistryHolder.current {
            registry.setKey(node, keyHandler)
            if node.attachments["__popover_autofocused"] == nil {
                node.attachments["__popover_autofocused"] = true
                FocusChainHolder.current?.focus(node)
            }
        } else {
            InteractionRegistryHolder.current?.remove(node)
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        LayoutNode()
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.positionType = .absolute
        layout.setPosition(0, edge: .left)
        layout.setPositionPercent(100, edge: .top)
        if let width {
            layout.width = width
        }
    }

    var _children: [any View] {
        // Content is portal-rendered via PortalRegistry + PortalHost
        []
    }
}

public struct SelectOption<Value: Hashable>: Identifiable {
    public let value: Value
    public let label: String
    public let isEnabled: Bool

    public var id: AnyHashable { AnyHashable(value) }

    public init(value: Value,
                label: String,
                isEnabled: Bool = true) {
        self.value = value
        self.label = label
        self.isEnabled = isEnabled
    }
}

public struct Select<Value: Hashable>: View {
    public let selection: Binding<Value>
    public let options: [SelectOption<Value>]
    public let isEnabled: Bool
    public let width: Float?
    public let placeholder: String

    public init(selection: Binding<Value>,
                options: [SelectOption<Value>],
                isEnabled: Bool = true,
                width: Float? = nil,
                placeholder: String = "Select") {
        self.selection = selection
        self.options = options
        self.isEnabled = isEnabled
        self.width = width
        self.placeholder = placeholder
    }

    public var body: some View {
        _StatefulSelect(select: self)
    }
}

private struct _StatefulSelect<Value: Hashable>: View {
    let select: Select<Value>

    @State var isPresented: Bool = false
    @State var highlightedIndex: Int = 0
    @State var popoverWasPresented: Bool = false

    var body: some View {
        let _ = {
            if isPresented, !popoverWasPresented {
                highlightedIndex = 0
            }
            popoverWasPresented = isPresented
        }()

        let itemCount = select.options.count
        let keyHandler: (KeyEvent, EventPhase) -> EventResult = { event, phase in
            guard phase == .target || phase == .bubble else { return .ignored }
            switch event.scancode {
            case 81: // Arrow Down
                if highlightedIndex + 1 < itemCount { highlightedIndex += 1 }
                return .handled
            case 82: // Arrow Up
                if highlightedIndex > 0 { highlightedIndex -= 1 }
                return .handled
            case 40, 88: // Return, KP Enter
                if highlightedIndex < itemCount {
                    select.selection.wrappedValue = select.options[highlightedIndex].value
                }
                isPresented = false
                return .handled
            case 41: // Escape
                isPresented = false
                return .handled
            default:
                return .ignored
            }
        }

        Popover(isPresented: $isPresented,
                isEnabled: select.isEnabled,
                width: select.width,
                onKey: keyHandler,
                label: {
            Row(alignment: .center, spacing: 8) {
                Text(selectedLabel)
                    .font(.body)
                    .foregroundColor(select.isEnabled ? .onSurface : .onSurfaceMuted)
                    .flex()
                Image(resource: isPresented ? SelectIcons.chevronUp : SelectIcons.chevronDown,
                      width: 10,
                      height: 10,
                      tint: .white,
                      contentMode: .fit,
                      renderingMode: .alphaMask)
                    .foregroundColor(.onSurfaceMuted)
            }
            .padding(horizontal: 10, vertical: 8)
            .background(.surface)
            .cornerRadius(6)
            .border(.border, width: 1)
        }, content: {
            Menu(menuEntries,
                 width: select.width,
                 highlightedIndex: isPresented ? highlightedIndex : nil,
                 onItemActivated: {
                isPresented = false
            })
        })
    }

    private var selectedLabel: String {
        if let matched = select.options.first(where: { $0.value == select.selection.wrappedValue }) {
            return matched.label
        }
        return select.placeholder
    }

    private var menuEntries: [MenuEntry] {
        select.options.map { option in
            let selected = option.value == select.selection.wrappedValue
            let title = selected ? "✓ \(option.label)" : option.label
            return .item(MenuItem(
                id: option.id,
                title: title,
                isEnabled: option.isEnabled,
                role: .normal,
                action: {
                    select.selection.wrappedValue = option.value
                }
            ))
        }
    }
}

public struct EnumField<Value: Hashable & CaseIterable>: View where Value.AllCases: Collection {
    public let value: Binding<Value>
    public let isEnabled: Bool
    public let width: Float?
    public let label: (Value) -> String

    public init(value: Binding<Value>,
                isEnabled: Bool = true,
                width: Float? = nil,
                label: @escaping (Value) -> String = { String(describing: $0) }) {
        self.value = value
        self.isEnabled = isEnabled
        self.width = width
        self.label = label
    }

    public var body: some View {
        Select(selection: value,
               options: options,
               isEnabled: isEnabled,
               width: width,
               placeholder: "Select")
    }

    private var options: [SelectOption<Value>] {
        Array(Value.allCases).map { option in
            SelectOption(value: option, label: label(option), isEnabled: true)
        }
    }
}

private extension View {
    @ViewBuilder
    func ifLet<T>(_ value: T?,
                  transform: (Self, T) -> some View) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}
