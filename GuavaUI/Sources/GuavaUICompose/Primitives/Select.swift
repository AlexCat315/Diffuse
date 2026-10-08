import EngineKernel
import Foundation
import GuavaUIRuntime

/// Built-in SVG icons bundled with GuavaUICompose. Public so hosts reuse the
/// same glyphs instead of approximating them with text characters.
public enum UICommonIcons {
    public static let star = BundleImageResource.svg(named: "star", in: GuavaUIComposeResourceBundle.bundle, subdirectory: "UIIcons")
    public static let starFill = BundleImageResource.svg(named: "star-fill", in: GuavaUIComposeResourceBundle.bundle, subdirectory: "UIIcons")
    public static let user = BundleImageResource.svg(named: "user", in: GuavaUIComposeResourceBundle.bundle, subdirectory: "UIIcons")
    public static let chevronDown = BundleImageResource.svg(named: "chevron-down",
                                                            in: GuavaUIComposeResourceBundle.bundle,
                                                            subdirectory: "UIIcons")
    public static let chevronUp = BundleImageResource.svg(named: "chevron-up",
                                                          in: GuavaUIComposeResourceBundle.bundle,
                                                          subdirectory: "UIIcons")
    public static let chevronLeft = BundleImageResource.svg(named: "chevron-left",
                                                            in: GuavaUIComposeResourceBundle.bundle,
                                                            subdirectory: "UIIcons")
    public static let chevronRight = BundleImageResource.svg(named: "chevron-right",
                                                             in: GuavaUIComposeResourceBundle.bundle,
                                                             subdirectory: "UIIcons")
    public static let checkmark = BundleImageResource.svg(named: "checkmark",
                                                          in: GuavaUIComposeResourceBundle.bundle,
                                                          subdirectory: "UIIcons")
    public static let close = BundleImageResource.svg(named: "close",
                                                      in: GuavaUIComposeResourceBundle.bundle,
                                                      subdirectory: "UIIcons")
    public static let formatjson = BundleImageResource.svg(named: "format-json", in: GuavaUIComposeResourceBundle.bundle, subdirectory: "UIIcons")
    public static let revert = BundleImageResource.svg(named: "revert", in: GuavaUIComposeResourceBundle.bundle, subdirectory: "UIIcons")
    public static let format = BundleImageResource.svg(named: "format", in: GuavaUIComposeResourceBundle.bundle, subdirectory: "UIIcons")
    public static let reset = BundleImageResource.svg(named: "reset", in: GuavaUIComposeResourceBundle.bundle, subdirectory: "UIIcons")
    public static let expand = BundleImageResource.svg(named: "expand", in: GuavaUIComposeResourceBundle.bundle, subdirectory: "UIIcons")
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

public enum PopoverPlacement: Sendable, Equatable {
    case start
    case end
}

public struct Popover<Label: View, Content: View>: View {
    public let isPresented: Binding<Bool>
    public let isEnabled: Bool
    public let width: Float?
    public let placement: PopoverPlacement
    public let label: Label
    public let content: Content
    public let onKey: ((KeyEvent, EventPhase) -> EventResult)?

    public init(isPresented: Binding<Bool>,
                isEnabled: Bool = true,
                width: Float? = nil,
                placement: PopoverPlacement = .start,
                onKey: ((KeyEvent, EventPhase) -> EventResult)? = nil,
                @ViewBuilder label: () -> Label,
                @ViewBuilder content: () -> Content) {
        self.isPresented = isPresented
        self.isEnabled = isEnabled
        self.width = width
        self.placement = placement
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

                _PopoverOverlayHost(isPresented: isPresented.wrappedValue, width: width,
                                    placement: placement,
                                    onDismiss: { isPresented.wrappedValue = false },
                                    keyHandler: onKey) {
                    Box(direction: .column, alignItems: .stretch, spacing: 0) {
                        content
                    }
                    .padding(EdgeInsets(top: 2, leading: 0, bottom: 0, trailing: 0))
                }
        }
        .zIndex(isPresented.wrappedValue ? 10_000 : 0)
    }
}

private struct _PopoverOverlayHost<Content: View>: _PrimitiveView {
    let isPresented: Bool
    let width: Float?
    let placement: PopoverPlacement
    let content: Content
    let keyHandler: ((KeyEvent, EventPhase) -> EventResult)?
    let onDismiss: () -> Void

    private struct PositionIdentity: Equatable {
        let width: Float?
        let placement: PopoverPlacement
    }

    init(isPresented: Bool, width: Float?,
         placement: PopoverPlacement,
         onDismiss: @escaping () -> Void,
         keyHandler: ((KeyEvent, EventPhase) -> EventResult)? = nil,
         @ViewBuilder content: () -> Content) {
        self.isPresented = isPresented
        self.width = width
        self.placement = placement
        self.keyHandler = keyHandler
        self.onDismiss = onDismiss
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
        guard isPresented else {
            node.firstResource(PortalResource.self)?.dismiss(node: node)
            return
        }
        let position = Self.popoverPosition(for: node,
                                            width: width,
                                            placement: placement)

        // Register / update the overlay entry through the node-owned resource.
        // `present` re-registers if a prior entry was cleaned up, so a reused
        // node reliably re-shows the menu.
        let portalStore = node.compositionValue(of: PortalStoreEnvironment.key)
            ?? PortalStoreHolder.current
        node.firstResource(PortalResource.self)?
            .present(in: portalStore,
                     position: position,
                     width: width,
                     content: AnyView(FocusScope(restoresCommands: true) {
                        _MenuKeyHost(onKey: { event in
                            if event.scancode == Scancode.escape { onDismiss(); return true }
                            return keyHandler?(event, .target) == .handled
                        }) { content }
                     }), transition: .opacity.combined(with: .move(edge: .top, distance: 4)))
        node.firstResource(PortalResource.self)?.setDismissal(
            anchor: { [weak node] in node.map { Self.anchorFrame(for: $0) ?? .zero } ?? .zero },
            dismiss: onDismiss
        )
        node.attachments[LayoutDebugAttachmentKey.debugName] =
            "popover-store-\(ObjectIdentifier(portalStore))-entries-\(portalStore.entries.count)"
        node.updateOverlayDraw(identity: PositionIdentity(width: width,
                                                          placement: placement)) { [weak node] _, _ in
            guard let node else { return }
            node.firstResource(PortalResource.self)?
                .updatePosition(Self.popoverPosition(for: node,
                                                     width: width,
                                                     placement: placement))
        }
        node.layoutDidUpdate = { [width, placement] node in
            node.firstResource(PortalResource.self)?
                .updatePosition(Self.popoverPosition(for: node,
                                                     width: width,
                                                     placement: placement))
        }

        node.isFocusable = false
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

    private static func popoverPosition(for node: Node,
                                        width: Float?,
                                        placement: PopoverPlacement) -> CGPoint {
        let boxFrame = anchorFrame(for: node) ?? node.parent?.absoluteFrame ?? .zero
        let x: CGFloat
        switch placement {
        case .start:
            x = boxFrame.minX
        case .end:
            if let width {
                x = boxFrame.maxX - CGFloat(width)
            } else {
                x = boxFrame.minX
            }
        }
        return CGPoint(x: x, y: boxFrame.maxY)
    }

    private static func anchorFrame(for node: Node) -> CGRect? {
        var current: Node? = node
        while let currentNode = current, let parent = currentNode.parent {
            if let index = parent.children.firstIndex(where: { $0 === currentNode }) {
                for sibling in parent.children[..<index].reversed() {
                    if let frame = firstVisibleFrame(in: sibling) {
                        return frame
                    }
                }
            }
            current = parent
        }
        return nil
    }

    private static func firstVisibleFrame(in node: Node) -> CGRect? {
        let frame = node.absoluteFrame
        if frame.width > 0 || frame.height > 0 {
            return frame
        }
        for child in node.children.reversed() {
            if let frame = firstVisibleFrame(in: child) {
                return frame
            }
        }
        return nil
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

    var body: some View {
        ThemeReader { theme in
        Popover(isPresented: $isPresented,
                isEnabled: select.isEnabled,
                width: select.width,
                label: {
            // Trigger reads as a text input: same sunken fill, border, and
            // radius the TextField/NumberField use (theme.inputs), so a Select
            // sits flush with the fields around it in a property grid instead
            // of looking like a lighter pill from an older style.
            Row(alignment: .center, spacing: 8) {
                Text(selectedLabel)
                    .font(.body)
                    .foregroundColor(select.isEnabled ? .onSurface : .onSurfaceDisabled)
                    .flex()
                Icon(isPresented ? UICommonIcons.chevronUp : UICommonIcons.chevronDown, size: 10, color: .onSurfaceMuted)
            }
            .padding(horizontal: 8)
            .frame(height: 28)
            .background(theme.inputs.background)
            .cornerRadius(theme.inputs.radius)
            .border(isPresented ? theme.inputs.borderFocused : theme.inputs.borderColor,
                    width: isPresented ? theme.inputs.focusRingWidth : theme.inputs.borderWidth)
            .animation(.semantic(.fast, in: theme), value: isPresented)
        }, content: {
            Menu(menuEntries,
                 width: select.width,
                 maxVisibleRows: select.maxVisibleRows,
                 onItemActivated: {
                isPresented = false
            })
        })
        }
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
