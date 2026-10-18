import GuavaUIRuntime

public struct WheelPickerOption<Value: Hashable>: Identifiable {
    public let value: Value
    public let label: String
    public let isEnabled: Bool

    public var id: AnyHashable { AnyHashable(value) }

    public init(_ value: Value, _ label: String, isEnabled: Bool = true) {
        self.value = value
        self.label = label
        self.isEnabled = isEnabled
    }
}

/// A five-row wheel. Pointer drags follow the finger, wheel and arrow keys move
/// one option, and the selection lands only on enabled options.
public struct WheelPicker<Value: Hashable>: View {
    public let selection: Binding<Value>
    public let options: [WheelPickerOption<Value>]
    public var isEnabled: Bool
    public var visibleRows: Int
    public var label: String
    public var onChange: ((Value) -> Void)?

    @State private var dragOffset: CGFloat = 0

    public init(selection: Binding<Value>,
                options: [WheelPickerOption<Value>],
                isEnabled: Bool = true,
                visibleRows: Int = 5,
                label: String = "Wheel picker",
                onChange: ((Value) -> Void)? = nil) {
        self.selection = selection
        self.options = options
        self.isEnabled = isEnabled
        self.visibleRows = max(3, min(9, visibleRows | 1))
        self.label = label
        self.onChange = onChange
    }

    public var body: some View {
        ThemeReader { theme in
            SurfaceReader { surface in
                let rowHeight = Float(surface.input.contains(.touch) ? 44 : 32)
                let selected = Binding<Int>(
                    get: { selectedIndex },
                    set: { index in
                        guard options.indices.contains(index) else { return }
                        let value = options[index].value
                        guard value != selection.wrappedValue else { return }
                        selection.wrappedValue = value
                        onChange?(value)
                    })
                ContainerSizeReader { size in
                  let columnWidth = Float(size.width)
                  Box(direction: .row, alignItems: .center, justifyContent: .center) {
                    ZStack(alignment: .center) {
                        AnyView(selectionBar(theme: theme, rowHeight: rowHeight, width: columnWidth))
                        rows(theme: theme, rowHeight: rowHeight, selected: selected.wrappedValue, width: columnWidth)
                        WheelPickerGestureLayer(
                            selectedIndex: selected,
                            dragOffset: $dragOffset,
                            rowHeight: rowHeight,
                            count: options.count,
                            enabledIndices: enabledIndices,
                            isEnabled: isEnabled,
                            label: label,
                            valueLabel: { index in options[index].label })
                        .frame(width: .percent(100))
                    }
                    .frame(width: .percent(100))
                    .frame(height: rowHeight * Float(visibleRows))
                    .clipped()
                }
                .frame(height: rowHeight * Float(visibleRows))
                }
                // The gesture layer owns the wheel's semantics; the decorative
                // center bar and row texts must not be read twice.
            }
        }
    }

    private var selectedIndex: Int {
        options.firstIndex { $0.value == selection.wrappedValue } ?? enabledIndices.first ?? 0
    }

    private var enabledIndices: [Int] {
        options.indices.filter { options[$0].isEnabled }
    }

    @ViewBuilder
    private func selectionBar(theme: Theme, rowHeight: Float, width: Float) -> some View {
        Box {}.frame(height: max(0, rowHeight - 4))
            .frame(width: .points(width))
            .background(theme.colors.surfaceVariant)
            .cornerRadius(theme.radius.sm)
    }

    private func rows(theme: Theme, rowHeight: Float, selected: Int, width: Float) -> some View {
        let lower = max(0, selected - visibleRows - 2)
        let upper = min(options.count - 1, selected + visibleRows + 2)
        return ZStack(alignment: .center) {
            if options.isEmpty {
                Text("No options").font(.body).foregroundColor(.onSurfaceMuted)
            } else if lower <= upper {
                for index in lower...upper {
                    let dragRows = Float(dragOffset / CGFloat(rowHeight))
                    let distance = Float(index - selected) + (dragRows.isFinite ? dragRows : 0)
                    AnyView(row(index: index, distance: distance, rowHeight: rowHeight, width: width))
                }
            }
        }
        .frame(width: .points(width))
        .frame(height: rowHeight * Float(visibleRows))
        .clipped()
    }

    private func row(index: Int, distance: Float, rowHeight: Float, width: Float) -> AnyView {
        let option = options[index]
        let isSelected = abs(distance) < 0.5
        let alpha: Float = option.isEnabled ? max(0.18, 1 - abs(distance) * 0.22) : 0.4
        let color: SemanticColorRef = option.isEnabled
            ? (isSelected ? .onSurface : .onSurfaceVariant)
            : .onSurfaceDisabled
        let font: SemanticFontRef = isSelected ? .bodyStrong : .body
        return AnyView(
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Text(option.label)
                    .font(font)
                    .foregroundColor(color)
            }
            .frame(width: .points(width))
            .frame(height: rowHeight)
            .opacity(alpha)
            .offset(y: distance * rowHeight)
            .accessibilityHidden())
    }
}

private struct WheelPickerGestureLayer: _PrimitiveView {
    let selectedIndex: Binding<Int>
    let dragOffset: Binding<CGFloat>
    let rowHeight: Float
    let count: Int
    let enabledIndices: [Int]
    let isEnabled: Bool
    let label: String
    let valueLabel: (Int) -> String

    private static let startKey = "__wheel.start"
    private static let baseKey = "__wheel.base"

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        node.isFocusable = isEnabled
        return node
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.height = rowHeight * 5
        layout.alignSelf = .stretch
        return layout
    }

    func _updateNode(_ node: Node) {
        node.applyTouchControlExtent()
        node.isFocusable = isEnabled
        node.cursor = isEnabled ? .pointer : .notAllowed
        node.accessibility = AccessibilitySemantics(.slider) {
            $0.label = label
            $0.value = count > 0 ? valueLabel(min(count - 1, max(0, selectedIndex.wrappedValue))) : ""
            $0.help = "Use arrow keys, Home or End to choose a value"
            $0.state.isEnabled = isEnabled
        }
        node.accessibilityActions = AccessibilityActions()
        guard isEnabled, let registry = InteractionRegistryHolder.current else { return }
        node.accessibilityActions.increment = { step(node: node, 1) }
        node.accessibilityActions.decrement = { step(node: node, -1) }
        node.accessibilityActions.setValue = { raw in
            if let index = (0..<count).first(where: { valueLabel($0) == raw }) {
                choose(index, node: node)
            }
        }

        registry.setPointer(node) { event, phase, _ in
            guard event.button == .left else { return .ignored }
            switch phase {
            case .down:
                FocusChainHolder.current?.focus(node)
                node.attachments[Self.startKey] = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
                node.attachments[Self.baseKey] = dragOffset.wrappedValue
                PointerCaptureHolder.current?.acquire(node)
                return .handled
            case .up:
                let start = node.attachments.removeValue(forKey: Self.startKey) as? CGPoint
                node.attachments.removeValue(forKey: Self.baseKey)
                if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
                guard let start else { return .ignored }
                let travel = CGFloat(event.y) - start.y
                if abs(travel) < 4 {
                    let localY = CGFloat(event.y) - node.absoluteFrame.midY
                    let clicked = selectedIndex.wrappedValue + Int((localY / CGFloat(rowHeight)).rounded())
                    choose(clicked, node: node)
                } else {
                    let steps = Int((-dragOffset.wrappedValue / CGFloat(rowHeight)).rounded())
                    choose(selectedIndex.wrappedValue + steps, node: node)
                }
                return .handled
            }
        }
        registry.setMotion(node) { event, _ in
            guard let start = node.attachments[Self.startKey] as? CGPoint,
                  let base = node.attachments[Self.baseKey] as? CGFloat else { return .ignored }
            dragOffset.wrappedValue = base + (CGFloat(event.y) - start.y)
            return .handled
        }
        registry.setWheel(node) { event, phase in
            guard phase == .target, abs(event.y) > 0 else { return .ignored }
            step(node: node, event.y > 0 ? -1 : 1)
            return .handled
        }
        registry.setKey(node) { event, phase in
            guard phase == .target, !event.isRepeat else { return .ignored }
            switch event.scancode {
            case Scancode.arrowUp, Scancode.arrowLeft:
                step(node: node, -1); return .handled
            case Scancode.arrowDown, Scancode.arrowRight:
                step(node: node, 1); return .handled
            case Scancode.home:
                choose(enabledIndices.first ?? 0, node: node); return .handled
            case Scancode.end:
                choose(enabledIndices.last ?? count - 1, node: node); return .handled
            default:
                return .ignored
            }
        }
    }

    private func step(node: Node, _ delta: Int) {
        guard let current = enabledIndices.firstIndex(of: selectedIndex.wrappedValue) else { return }
        let target = min(enabledIndices.count - 1, max(0, current + delta))
        choose(enabledIndices[target], node: node)
    }

    private func choose(_ index: Int, node: Node) {
        guard count > 0 else { return }
        let target = min(count - 1, max(0, index))
        guard enabledIndices.contains(target) else {
            withAnimation(.semantic(.fast, in: node.theme)) { dragOffset.wrappedValue = 0 }
            return
        }
        let allowed = target
        guard allowed != selectedIndex.wrappedValue else {
            withAnimation(.semantic(.fast, in: node.theme)) { dragOffset.wrappedValue = 0 }
            return
        }
        withAnimation(.semantic(.fast, in: node.theme)) {
            selectedIndex.wrappedValue = allowed
            dragOffset.wrappedValue = 0
        }
    }
}
