import EngineKernel
import Foundation
import GuavaUIRuntime

/// Built-in SVG icons bundled with GuavaUICompose. Public so hosts reuse the
/// same glyphs instead of approximating them with text characters.
public enum UICommonIcons {
    public static let chevronDown = BundleImageResource.svg(named: "chevron-down",
                                                            in: .module,
                                                            subdirectory: "UIIcons")
    public static let chevronUp = BundleImageResource.svg(named: "chevron-up",
                                                          in: .module,
                                                          subdirectory: "UIIcons")
    public static let chevronRight = BundleImageResource.svg(named: "chevron-right",
                                                             in: .module,
                                                             subdirectory: "UIIcons")
    public static let checkmark = BundleImageResource.svg(named: "checkmark",
                                                          in: .module,
                                                          subdirectory: "UIIcons")
    public static let close = BundleImageResource.svg(named: "close",
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
    /// Rendered as a leading checkmark glyph (e.g. the current value in a
    /// Select menu or a toggled menu-bar action).
    public let isSelected: Bool
    public let role: MenuItemRole
    public let action: () -> Void

    public init<ID: Hashable>(id: ID,
                              title: String,
                              shortcut: String? = nil,
                              isEnabled: Bool = true,
                              isSelected: Bool = false,
                              role: MenuItemRole = .normal,
                              action: @escaping () -> Void) {
        self.id = AnyHashable(id)
        self.title = title
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.role = role
        self.action = action
    }

    public init(title: String,
                shortcut: String? = nil,
                isEnabled: Bool = true,
                isSelected: Bool = false,
                role: MenuItemRole = .normal,
                action: @escaping () -> Void) {
        self.id = AnyHashable(UUID().uuidString)
        self.title = title
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.isSelected = isSelected
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
        let rowHeight: Float = 28
        let shouldScroll = entries.count > maxVisibleRows
        let listHeight = Float(maxVisibleRows) * rowHeight
        Box(direction: .column, alignItems: .stretch, spacing: 1) {
            if shouldScroll {
                ScrollView(.vertical,
                           consumePolicy: .always,
                           scrollbarGutter: .stable) {
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
        .cornerRadius(7)
        .border(.border, width: 1)
        .ifLet(width) { view, width in
            view.frame(width: width)
        }
    }

    private func rows() -> [AnyView] {
        // Reserve a leading checkmark column for every row as soon as any
        // sibling is selected, so titles stay aligned.
        let showsSelectionColumn = entries.contains {
            if case .item(let item) = $0 { return item.isSelected }
            return false
        }
        var itemIndex = 0
        return entries.map { entry in
            let isHighlighted: Bool = {
                if case .item = entry {
                    defer { itemIndex += 1 }
                    return highlightedIndex == itemIndex
                }
                return false
            }()
            return AnyView(menuEntry(entry,
                                     isHighlighted: isHighlighted,
                                     showsSelectionColumn: showsSelectionColumn)
                .id(entry.id))
        }
    }

    private func menuEntry(_ entry: MenuEntry,
                           isHighlighted: Bool,
                           showsSelectionColumn: Bool) -> some View {
        switch entry {
        case .separator:
            return AnyView(
                Divider(color: nil, thickness: 1, axis: .horizontal)
                    .background(.divider)
            )
        case .item(let item):
            return AnyView(
                _MenuItemRow(item: item,
                             isHighlighted: isHighlighted,
                             showsSelectionColumn: showsSelectionColumn,
                             onActivate: {
                                 item.action()
                                 onItemActivated?()
                             })
            )
        }
    }
}

private struct _MenuItemRow: View {
    let item: MenuItem
    let isHighlighted: Bool
    let showsSelectionColumn: Bool
    let onActivate: () -> Void
    @State var isHovered: Bool = false
    @State var isPressed: Bool = false

    var body: some View {
        _MenuItemRowHost(item: item,
                         isHighlighted: isHighlighted,
                         showsSelectionColumn: showsSelectionColumn,
                         isHovered: isHovered,
                         isPressed: isPressed,
                         onHoverChange: { hovered in
                             if isHovered != hovered {
                                 isHovered = hovered
                             }
                         },
                         onDown: {
                             if !isPressed {
                                 isPressed = true
                             }
                         },
                         onUp: {
                             isPressed = false
                             onActivate()
                             return true
                         },
                         onCancel: {
                             if isPressed {
                                 isPressed = false
                             }
                         })
    }
}

private struct _MenuItemRowHost: _PrimitiveView {
    let item: MenuItem
    let isHighlighted: Bool
    let showsSelectionColumn: Bool
    let isHovered: Bool
    let isPressed: Bool
    let onHoverChange: (Bool) -> Void
    let onDown: () -> Void
    let onUp: () -> Bool
    let onCancel: () -> Void

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        node.isFocusable = true
        return node
    }

    func _updateNode(_ node: Node) {
        node.attachments[Self.itemIDKey] = item.id
        node.attachments[Self.hoveredKey] = isHovered
        node.attachments[Self.pressedKey] = isPressed
        node.cursor = item.isEnabled ? .pointer : .notAllowed

        guard item.isEnabled, let registry = InteractionRegistryHolder.current else {
            InteractionRegistryHolder.current?.remove(node)
            return
        }

        registry.setHover(node) { phase in
            switch phase {
            case .enter:
                onHoverChange(true)
            case .leave:
                node.attachments.removeValue(forKey: Self.activePressKey)
                if PointerCaptureHolder.current?.target === node {
                    PointerCaptureHolder.current?.release()
                }
                onHoverChange(false)
                onCancel()
            }
        }
        registry.setPointer(node) { event, phase, _ in
            guard event.button == .left else { return .ignored }
            switch phase {
            case .down:
                node.attachments[Self.activePressKey] = ActiveMenuPress(onUp: onUp)
                PointerCaptureHolder.current?.acquire(node)
                onDown()
                return .handled
            case .up:
                let activePress = node.attachments[Self.activePressKey] as? ActiveMenuPress
                node.attachments.removeValue(forKey: Self.activePressKey)
                defer {
                    if PointerCaptureHolder.current?.target === node {
                        PointerCaptureHolder.current?.release()
                    }
                }
                guard let activePress else { return .ignored }
                return activePress.onUp() ? .handled : .ignored
            }
        }
        registry.setKey(node) { event, _ in
            guard !event.isRepeat else { return .ignored }
            switch event.scancode {
            case Scancode.return, Scancode.space, Scancode.keypadEnter:
                _ = onUp()
                return .handled
            default:
                return .ignored
            }
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexDirection = .column
        layout.alignItems = .stretch
        layout.height = 34
        return layout
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.flexDirection = .column
        layout.alignItems = .stretch
        layout.height = 34
    }

    func _children(for node: Node) -> [any View] {
        let theme = node.theme
        let background: Color = {
            guard item.isEnabled else { return Color(r: 0, g: 0, b: 0, a: 0) }
            if isPressed { return theme.colors.stateLayerPressed }
            if isHovered { return theme.colors.stateLayerHover }
            if isHighlighted { return theme.colors.stateLayerSelected }
            return Color(r: 0, g: 0, b: 0, a: 0)
        }()

        let titleColor: Color = item.role == .destructive
            ? theme.colors.error
            : theme.colors.onSurface
        let textOpacity: Float = item.isEnabled ? 1 : 0.55

        let checkmarkSize: Float = 10
        let row = Row(alignment: .center, spacing: 8) {
            if showsSelectionColumn {
                // Fixed-width slot — a grow-able Spacer here pushes every
                // unchecked title toward the centre of the menu.
                Box(direction: .row, alignItems: .center, justifyContent: .center) {
                    if item.isSelected {
                        Icon(UICommonIcons.checkmark, size: checkmarkSize, color: titleColor)
                            .opacity(textOpacity)
                    }
                }
                .frame(width: checkmarkSize)
            }
            Text(item.title)
                .font(.body)
                .foregroundColor(titleColor)
                .opacity(textOpacity)
                .flex()
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.caption)
                    .foregroundColor(theme.colors.onSurfaceMuted)
                    .opacity(textOpacity)
            }
        }
        .padding(horizontal: 12, vertical: 0)
        .frame(height: 26)
        .background(background)
        .cornerRadius(5)
        .padding(horizontal: 4, vertical: 2)

        return [row]
    }

    private static let hoveredKey = "__menu_item_hovered"
    private static let itemIDKey = "__menu_item_id"
    private static let pressedKey = "__menu_item_pressed"
    private static let activePressKey = "__menu_item_active_press"
}

private final class ActiveMenuPress {
    let onUp: () -> Bool

    init(onUp: @escaping () -> Bool) {
        self.onUp = onUp
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
        // The portal entry is owned by this node's lifetime: when the popover
        // closes or its subtree is torn down, `Node.removeChild` unmounts the
        // resource and the entry is unregistered — no modifier cleanup needed.
        node.addResource(PortalResource())
        return node
    }

    func _updateNode(_ node: Node) {
        let position = popoverPosition(for: node)

        // Register / update the overlay entry through the node-owned resource.
        // `present` re-registers if a prior entry was cleaned up, so a reused
        // node reliably re-shows the menu.
        node.firstResource(PortalResource.self)?
            .present(position: position, width: width, content: AnyView(content))
        node.overlayDraw = { [weak node] _, _ in
            guard let node else { return }
            node.firstResource(PortalResource.self)?
                .updatePosition(popoverPosition(for: node))
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
        // Content is portal-rendered via the window-scoped PortalStore + PortalHost
        []
    }

    private func popoverPosition(for node: Node) -> CGPoint {
        let boxFrame = node.parent?.absoluteFrame ?? .zero
        return CGPoint(x: boxFrame.minX, y: boxFrame.maxY)
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
    public let maxVisibleRows: Int
    public let placeholder: String

    public init(selection: Binding<Value>,
                options: [SelectOption<Value>],
                isEnabled: Bool = true,
                width: Float? = nil,
                maxVisibleRows: Int = 8,
                placeholder: String = "Select") {
        self.selection = selection
        self.options = options
        self.isEnabled = isEnabled
        self.width = width
        self.maxVisibleRows = max(1, maxVisibleRows)
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
        // Only write state on an actual transition: @State writes invalidate
        // the owning scope unconditionally, so an unguarded write here would
        // recompose this Select on every commit, forever.
        let _ = {
            if isPresented != popoverWasPresented {
                if isPresented, highlightedIndex != 0 {
                    highlightedIndex = 0
                }
                popoverWasPresented = isPresented
            }
        }()

        let itemCount = select.options.count
        let keyHandler: (KeyEvent, EventPhase) -> EventResult = { event, phase in
            guard phase == .target || phase == .bubble else { return .ignored }
            switch event.scancode {
            case Scancode.arrowDown:
                if highlightedIndex + 1 < itemCount { highlightedIndex += 1 }
                return .handled
            case Scancode.arrowUp:
                if highlightedIndex > 0 { highlightedIndex -= 1 }
                return .handled
            case Scancode.return, Scancode.keypadEnter:
                if highlightedIndex < itemCount {
                    select.selection.wrappedValue = select.options[highlightedIndex].value
                }
                isPresented = false
                return .handled
            case Scancode.escape:
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
            // Trigger reads as a text input: same sunken fill, border, and
            // radius the TextField/NumberField use (theme.inputs), so a Select
            // sits flush with the fields around it in a property grid instead
            // of looking like a lighter pill from an older style.
            Row(alignment: .center, spacing: 8) {
                Text(selectedLabel)
                    .font(.body)
                    .foregroundColor(select.isEnabled ? .onSurface : .onSurfaceMuted)
                    .flex()
                Icon(isPresented ? UICommonIcons.chevronUp : UICommonIcons.chevronDown, size: 10, color: .onSurfaceMuted)
            }
            .padding(horizontal: 8, vertical: 5)
            .background(.surfaceSunken)
            .cornerRadius(7)
            .border(isPresented ? .focusRing : .border, width: isPresented ? 2 : 1)
        }, content: {
            Menu(menuEntries,
                 width: select.width,
                 maxVisibleRows: select.maxVisibleRows,
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
            .item(MenuItem(
                id: option.id,
                title: option.label,
                isEnabled: option.isEnabled,
                isSelected: option.value == select.selection.wrappedValue,
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
    public let maxVisibleRows: Int
    public let label: (Value) -> String

    public init(value: Binding<Value>,
                isEnabled: Bool = true,
                width: Float? = nil,
                maxVisibleRows: Int = 8,
                label: @escaping (Value) -> String = { String(describing: $0) }) {
        self.value = value
        self.isEnabled = isEnabled
        self.width = width
        self.maxVisibleRows = max(1, maxVisibleRows)
        self.label = label
    }

    public var body: some View {
        Select(selection: value,
               options: options,
               isEnabled: isEnabled,
               width: width,
               maxVisibleRows: maxVisibleRows,
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
