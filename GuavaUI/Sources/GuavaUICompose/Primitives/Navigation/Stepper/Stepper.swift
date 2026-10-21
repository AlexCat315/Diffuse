import GuavaUIRuntime

/// A controlled workflow navigator. The caller owns selection, outcomes and
/// availability. Lock future steps with `StepperItem.isEnabled`; completing or
/// selecting a step never changes another step's status.
public struct Stepper<ID: Hashable>: View {
    public let items: [StepperItem<ID>]
    public let selection: Binding<ID?>
    public var options = StepperOptions()
    public init(_ items: [StepperItem<ID>], selection: Binding<ID?>,
                configure: (inout StepperOptions) -> Void = { _ in }) {
        self.items = items; self.selection = selection; configure(&options)
        precondition(Set(items.map(\.id)).count == items.count, "Stepper item IDs must be unique")
    }
    private var enabled: [ID] { options.isEnabled ? items.filter(\.isEnabled).map(\.id) : [] }
    private var tabStop: ID? { enabled.first(where: { $0 == selection.wrappedValue }) ?? enabled.first }
    public var body: some View {
        if options.axis == .vertical {
            content(vertical: true)
        } else {
            // Two retained branches keep each layout tree stable. Mutating one
            // row's direction in place lets Yoga keep the old row height when
            // the narrow branch activates, which collapses the step buttons.
            ViewThatFits(threshold: CGFloat(horizontalBudget),
                         wide: { content(vertical: false) },
                         compact: { content(vertical: true) })
        }
    }

    private func content(vertical: Bool) -> some View {
        RovingFocusHost(enabledItems: enabled.map { AnyHashable($0) }, selection: { selection.wrappedValue.map { AnyHashable($0) } },
            onSelect: { if let id = $0.base as? ID { select(id) } }, wraps: options.allowsWrap,
            command: { navigation($0, vertical: vertical) }) {
            Box(direction: vertical ? .column : .row,
                alignItems: .stretch, spacing: vertical ? 4 : 8) {
                for (index, item) in items.enumerated() {
                    AnyView(step(item, index: index, vertical: vertical))
                    if index < items.count - 1 { AnyView(connector(after: item, vertical: vertical)) }
                }
            }
            .accessibility { $0.role = .list; $0.label = options.label; $0.state.isEnabled = options.isEnabled }
        }
    }

    /// A horizontal stepper only keeps its row while every step has its
    /// budget. Below that it stacks, so titles, detail text and the 44pt touch
    /// target stay readable instead of being compressed into unreadable cells.
    private var horizontalBudget: Float {
        let budget = max(80, options.minimumHorizontalStepWidth)
        let connectors = Float(max(0, items.count - 1)) * 32
        return Float(items.count) * budget + connectors
    }
    private func select(_ id: ID) {
        guard enabled.contains(id), selection.wrappedValue != id else { return }
        selection.wrappedValue = id
    }
    private func navigation(_ event: KeyEvent, vertical: Bool) -> SelectionNavigation? {
        guard event.modifiers.isEmpty else { return nil }
        switch event.scancode {
        case Scancode.home: return .first
        case Scancode.end: return .last
        case Scancode.arrowLeft where !vertical: return .previous
        case Scancode.arrowRight where !vertical: return .next
        case Scancode.arrowUp where vertical: return .previous
        case Scancode.arrowDown where vertical: return .next
        default: return nil
        }
    }
    private func step(_ item: StepperItem<ID>, index: Int, vertical: Bool) -> some View {
        let selected = selection.wrappedValue == item.id
        return Button(isEnabled: options.isEnabled && item.isEnabled, isSelected: selected,
            tooltip: "Step \(index + 1) of \(items.count) · \(item.status.description)", action: { select(item.id) }) {
            Row(alignment: .center, spacing: 10) {
                StepperMarker(number: index + 1, status: item.status, isSelected: selected).accessibilityHidden()
                Box(direction: .column, alignItems: .stretch, spacing: 3) {
                    Text(item.title).font(.bodyStrong)
                    if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundColor(.onSurfaceMuted) }
                }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
            }
        }
        .buttonStyle(StepperButtonStyle())
        .modifier(RovingItemModifier(id: AnyHashable(item.id), isTabStop: item.id == tabStop))
        .compositionLocal(ActionControlAccessibility.role, .listItem)
        .compositionLocal(ActionControlAccessibility.value, "Step \(index + 1) of \(items.count) · \(item.status.description)")
        .flex(vertical ? 0 : 1, shrink: vertical ? 0 : 1, basis: vertical ? nil : 0)
        .id(item.id)
    }
    private func connector(after item: StepperItem<ID>, vertical: Bool) -> some View {
        ThemeReader { theme in
            let color = item.status == .completed ? theme.colors.success : theme.colors.border
            if !vertical {
                Box(direction: .column, justifyContent: .center) {
                    Box {}.frame(width: 24, height: 1).background(color)
                }.accessibilityHidden()
            } else { StepperVerticalConnector(color: color).accessibilityHidden() }
        }
    }
}

private struct StepperButtonStyle: ButtonStyle {
    func makeBody(configuration c: ButtonStyleConfiguration) -> some View {
        let colors = c.theme.colors
        let fill = c.isPressed ? colors.stateLayerPressed : c.isHovered ? colors.stateLayerHover
            : c.isSelected ? colors.accent.multipliedAlpha(0.08) : .clear
        return Row(alignment: .center) { AnyView(c.label).flex(1, shrink: 1, basis: 0) }
            .flex(1, shrink: 1, basis: 0).padding(8).background(fill).cornerRadius(c.theme.radius.md)
            .foregroundColor(c.isEnabled ? colors.onSurface : colors.onSurfaceMuted)
            .border(c.isFocused ? colors.focusRing : .clear, width: 1)
            .opacity(c.isEnabled ? 1 : 0.5)
            .animation(motion: .fast, value: c.interactionKey)
    }
}

private struct StepperVerticalConnector: _PrimitiveView {
    let color: Color
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    func _updateNode(_ node: Node) {
        let size = node.compositionValue(of: ControlSizeEnvironment.key)
        node.layoutNode?.height = 16
        node.layoutNode?.flexDirection = .row
        node.layoutNode?.setPadding(9 + node.iconMetrics.size(size.buttonHeight) / 2, edge: .left)
    }
    var _children: [any View] { [Box {}.frame(width: 1, height: 16).background(color)] }
}

private struct StepperMarker: _PrimitiveView {
    let number: Int
    let status: StepStatus
    let isSelected: Bool
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    func _updateNode(_ node: Node) {
        let diameter = node.iconMetrics.size(node.compositionValue(of: ControlSizeEnvironment.key).buttonHeight)
        let color = isSelected && status == .pending ? node.theme.colors.accent : status.tone.color.resolve(node.theme)
        node.layoutNode?.width = diameter; node.layoutNode?.height = diameter
        node.layoutNode?.flexShrink = 0; node.layoutNode?.alignItems = .center; node.layoutNode?.justifyContent = .center
        node.cornerRadius = diameter / 2
        node.backgroundColor = color.multipliedAlpha(isSelected ? 0.16 : 0.09)
        node.borderColor = color; node.borderWidth = isSelected ? 1.5 : 1
    }
    func _children(for node: Node) -> [any View] {
        let diameter = node.iconMetrics.size(node.compositionValue(of: ControlSizeEnvironment.key).buttonHeight)
        let color = isSelected && status == .pending ? node.theme.colors.accent : status.tone.color.resolve(node.theme)
        switch status {
        case .completed: return [Icon(UIIcons.Action.check, size: diameter * 0.5).iconScaling(.fixed).foregroundColor(color)]
        case .failed: return [Icon(UIIcons.Action.x, size: diameter * 0.5).iconScaling(.fixed).foregroundColor(color)]
        case .inProgress: return [Spinner(size: diameter * 0.55).foregroundColor(color)]
        case .pending: return [Text("\(number)").font(.label).foregroundColor(color)]
        }
    }
}
