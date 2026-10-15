import GuavaUIRuntime

/// One command shared by the bar and its overflow menu. Actions and enabled,
/// selected and destructive semantics come from the same MenuItem value.
public struct ToolbarItem {
    public enum Placement: Sendable, Equatable {
        /// Larger priorities remain in the bar longer. Ties retain source order.
        case automatic(priority: Int = 0)
        /// Keep a primary command in the bar, scrolling if necessary.
        case always
        case overflow
    }

    public let command: MenuItem
    public var icon: ButtonIcon.Source?
    public var placement: Placement = .automatic()

    public init(_ command: MenuItem, icon: ButtonIcon.Source? = nil,
                placement: Placement = .automatic()) {
        self.command = command
        self.icon = icon
        self.placement = placement
    }
}

public extension Toolbar where Content == AnyView {
    /// Measure commands at their natural size, then move lower priority commands
    /// into a menu. Icon commands retain their full title as help and semantics.
    init(items: [ToolbarItem], configure: (inout ToolbarOptions) -> Void = { _ in }) {
        precondition(Set(items.map(\.command.id)).count == items.count, "Toolbar command IDs must be unique")
        var options = ToolbarOptions()
        configure(&options)
        self.init(configure: { $0 = options }) {
            AnyView(ToolbarCommands(items: items, isEnabled: options.isEnabled))
        }
    }
}

private struct ToolbarCommands: View {
    let items: [ToolbarItem]
    let isEnabled: Bool
    @State private var overflow: Set<AnyHashable> = []
    @State private var isPresented = false
    @State private var focus = ToolbarOverflowFocus()

    var body: some View {
        if !isEnabled {
            if isPresented { isPresented = false }
            focus.pendingVisibility = nil
        }
        return ThemeReader { theme in
            ContainerSizeReader { size in
                ScrollView(.horizontal, scrollbarGutter: .overlay) {
                    ToolbarOverflowLayout(availableWidth: size.width,
                        placements: items.map(\.placement), spacing: CGFloat(theme.spacing.xs),
                        onOverflow: { indices in
                            let next = Set(indices.map { items[$0].command.id })
                            if next != overflow {
                                if isPresented && next.isEmpty {
                                    focus.pendingVisibility = FocusChainHolder.current?.isFocusVisible ?? true
                                }
                                overflow = next
                                isPresented = false
                            }
                        }) {
                        items.map { item in
                            ToolbarRetainedCommand(isVisible: !overflow.contains(item.command.id), focus: focus) {
                                command(item)
                            }.id(item.command.id)
                        }
                        ToolbarRetainedCommand(isVisible: !overflow.isEmpty, focus: focus, isOverflow: true) {
                            Popover(isPresented: $isPresented, isEnabled: isEnabled, placement: .end) {
                                Text("…").font(.bodyStrong).padding(horizontal: 10, vertical: 6)
                            } content: {
                                Menu(items.filter { overflow.contains($0.command.id) }.map { .item($0.command) },
                                    onItemActivated: { isPresented = false }, onDismiss: { isPresented = false })
                            }
                            .compositionLocal(ActionControlAccessibility.label, "More actions")
                            .compositionLocal(ActionControlAccessibility.isExpanded, isPresented)
                            .tooltip("More actions")
                        }
                    }
                }
            }
        }
    }

    private func command(_ item: ToolbarItem) -> AnyView {
        let command = item.command
        if let icon = item.icon {
            return AnyView(Button(icon: icon, role: command.role == .destructive ? .destructive : .normal,
                isEnabled: isEnabled && command.isEnabled, isSelected: command.isSelected,
                tooltip: command.title, action: command.action)
                .compositionLocal(ActionControlAccessibility.label, command.title))
        }
        return AnyView(Button(command.title, role: command.role == .destructive ? .destructive : .normal,
            isEnabled: isEnabled && command.isEnabled, isSelected: command.isSelected,
            tooltip: command.title, action: command.action)
            .compositionLocal(ActionControlAccessibility.label, command.title))
    }
}
