import GuavaUIRuntime

/// Vertical, virtualized list with single or multiple selection.
///
/// Pass `Binding<ID?>` for single selection or `Binding<Set<ID>>` for
/// multiple selection. With multiple selection a plain click selects one row,
/// Shift-click extends from the anchor, Cmd/Ctrl-click toggles, Shift+Arrow
/// extends, Space toggles the cursor row and Cmd/Ctrl+A selects everything.
/// Visual chrome is delegated to the active `ListRowStyle`.
public struct List<Data: RandomAccessCollection, ID: Hashable, RowContent: View>: View {
    private let data: Data
    private let id: KeyPath<Data.Element, ID>
    private let selection: CollectionSelection<ID>
    /// Authored logical height, before text scaling and the touch density floor.
    private let rowHeight: Float
    /// Authored logical spacing, before text scaling.
    private let rowSpacing: Float
    private let onActivate: ((Data.Element) -> Void)?
    private let refresh: RefreshOptions?
    private let rowContent: (Data.Element, Bool) -> RowContent

    @State private var anchor: ID?
    @State private var cursor: ID?

    private init(_ data: Data, id: KeyPath<Data.Element, ID>, selection: CollectionSelection<ID>,
                 rowHeight: Float, rowSpacing: Float, onActivate: ((Data.Element) -> Void)?,
                 refresh: RefreshOptions?, rowContent: @escaping (Data.Element, Bool) -> RowContent) {
        self.data = data
        self.id = id
        self.selection = selection
        self.rowHeight = max(1, rowHeight)
        self.rowSpacing = max(0, rowSpacing)
        self.onActivate = onActivate
        self.refresh = refresh
        self.rowContent = rowContent
    }

    public init(_ data: Data,
                id: KeyPath<Data.Element, ID>,
                selection: Binding<ID?> = .constant(nil),
                rowHeight: Float = 30,
                rowSpacing: Float = 0,
                onActivate: ((Data.Element) -> Void)? = nil,
                refresh: RefreshOptions? = nil,
                @ViewBuilder rowContent: @escaping (Data.Element, Bool) -> RowContent) {
        self.init(data, id: id, selection: .single(selection), rowHeight: rowHeight, rowSpacing: rowSpacing,
                  onActivate: onActivate, refresh: refresh, rowContent: rowContent)
    }

    public init(_ data: Data,
                id: KeyPath<Data.Element, ID>,
                selection: Binding<Set<ID>>,
                rowHeight: Float = 30,
                rowSpacing: Float = 0,
                onActivate: ((Data.Element) -> Void)? = nil,
                refresh: RefreshOptions? = nil,
                @ViewBuilder rowContent: @escaping (Data.Element, Bool) -> RowContent) {
        self.init(data, id: id, selection: .multiple(selection), rowHeight: rowHeight, rowSpacing: rowSpacing,
                  onActivate: onActivate, refresh: refresh, rowContent: rowContent)
    }

    public var body: some View {
        SurfaceReader { surface in
            TextScalerReader { scaler in
                let effectiveHeight = max(scaler.scale(rowHeight), surface.input.contains(.touch) ? surface.minimumControlExtent : 0)
                SelectionKeyHost(onKey: handleKey) {
                    VirtualStack(data, id: id, rowHeight: effectiveHeight, spacing: scaler.scale(rowSpacing),
                                 scrollToIndex: (cursor ?? selection.first).flatMap(index(of:)),
                                 onScrollOffsetChange: nil, refresh: refresh) { element in
                        let selected = selection.contains(element[keyPath: id])
                        _ListRowHost(isSelected: selected, rowHeight: effectiveHeight,
                                     onActivate: { activate(element) },
                                     onTap: selection.allowsMultiple ? { tap(element, $0) } : nil,
                                     content: AnyView(rowContent(element, selected)))
                    }
                    // The keyboard host is the outermost node, so it is where a caller's
                    // `.frame`/`.flex` lands. The scroll view has to take the height that
                    // is left for it — otherwise it sizes to its own content and paints
                    // rows past the bottom of whatever constrained it.
                    .flex().frame(minWidth: 0, minHeight: 0)
                }
            }
        }
    }

    private func index(of target: ID) -> Int? {
        data.firstIndex { $0[keyPath: id] == target }
            .map { data.distance(from: data.startIndex, to: $0) }
    }

    private func element(at index: Int) -> Data.Element {
        data[data.index(data.startIndex, offsetBy: index)]
    }

    private func ids(between first: ID, and second: ID) -> [ID]? {
        guard let start = index(of: first), let end = index(of: second) else { return nil }
        return data.dropFirst(min(start, end)).prefix(abs(end - start) + 1).map { $0[keyPath: id] }
    }

    private func tap(_ element: Data.Element, _ modifiers: KeyModifiers) {
        let value = element[keyPath: id]
        if modifiers.contains(.shift), let anchor, let range = ids(between: anchor, and: value) {
            selection.replace(with: range)
        } else if modifiers.contains(.gui) || modifiers.contains(.ctrl) {
            selection.toggle(value)
            anchor = value
        } else {
            selection.replace(with: [value])
            anchor = value
        }
        cursor = value
    }

    private func activate(_ element: Data.Element) {
        let value = element[keyPath: id]
        selection.replace(with: [value])
        anchor = value
        cursor = value
        onActivate?(element)
    }

    private func handleKey(_ event: KeyEvent) -> Bool {
        guard !data.isEmpty else { return false }
        let multiple = selection.allowsMultiple
        let current = (multiple ? cursor : nil).flatMap(index(of:)) ?? selection.first.flatMap(index(of:))
        if multiple, event.modifiers.contains(.gui) || event.modifiers.contains(.ctrl), event.scancode == Scancode.a {
            selection.replace(with: data.map { $0[keyPath: id] })
            anchor = data.first.map { $0[keyPath: id] }
            cursor = data.last.map { $0[keyPath: id] }
            return true
        }
        if multiple, event.scancode == Scancode.space, let current {
            let value = element(at: current)[keyPath: id]
            selection.toggle(value)
            anchor = value
            cursor = value
            return true
        }
        let next: Int
        switch event.scancode {
        case Scancode.arrowDown: next = min(data.count - 1, (current ?? -1) + 1)
        case Scancode.arrowUp: next = max(0, (current ?? data.count) - 1)
        case Scancode.home: next = 0
        case Scancode.end: next = data.count - 1
        case Scancode.return, Scancode.keypadEnter:
            guard let current else { return false }
            if multiple { activate(element(at: current)) } else { onActivate?(element(at: current)) }
            return true
        default:
            return false
        }
        let value = element(at: next)[keyPath: id]
        if multiple, event.modifiers.contains(.shift), let anchor, let range = ids(between: anchor, and: value) {
            selection.replace(with: range)
        } else {
            selection.replace(with: [value])
            anchor = value
        }
        cursor = value
        return true
    }
}

public extension List where Data.Element: Identifiable, ID == Data.Element.ID {
    init(_ data: Data,
         selection: Binding<ID?> = .constant(nil),
         rowHeight: Float = 30,
         rowSpacing: Float = 0,
         onActivate: ((Data.Element) -> Void)? = nil,
         refresh: RefreshOptions? = nil,
         @ViewBuilder rowContent: @escaping (Data.Element, Bool) -> RowContent) {
        self.init(data, id: \.id, selection: selection, rowHeight: rowHeight, rowSpacing: rowSpacing,
                  onActivate: onActivate, refresh: refresh, rowContent: rowContent)
    }

    init(_ data: Data,
         selection: Binding<Set<ID>>,
         rowHeight: Float = 30,
         rowSpacing: Float = 0,
         onActivate: ((Data.Element) -> Void)? = nil,
         refresh: RefreshOptions? = nil,
         @ViewBuilder rowContent: @escaping (Data.Element, Bool) -> RowContent) {
        self.init(data, id: \.id, selection: selection, rowHeight: rowHeight, rowSpacing: rowSpacing,
                  onActivate: onActivate, refresh: refresh, rowContent: rowContent)
    }
}

// MARK: - _ListRowHost

/// Primitive node behind each `List` row. Owns the tap handler and resolves
/// the active `ListRowStyle` via CompositionLocals on every recompose.
struct _ListRowHost: _PrimitiveView {
    let isSelected: Bool
    let rowHeight: Float
    let onActivate: () -> Void
    let onTap: ((KeyModifiers) -> Void)?
    let content: AnyView

    init(isSelected: Bool, rowHeight: Float, onActivate: @escaping () -> Void,
         onTap: ((KeyModifiers) -> Void)? = nil, content: AnyView) {
        self.isSelected = isSelected
        self.rowHeight = rowHeight
        self.onActivate = onActivate
        self.onTap = onTap
        self.content = content
    }

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        return n
    }

    func _updateNode(_ node: Node) {
        node.applyTouchControlExtent()
        node.accessibility = AccessibilitySemantics(.listItem) { $0.state.isSelected = isSelected; $0.combinesChildren = true }
        node.accessibilityActions.activate = onActivate
        guard let registry = InteractionRegistryHolder.current else { return }
        node.cursor = .pointer
        // Hover is painted on the host so entering a row never recomposes it.
        // The radius comes from the shared selection appearance, so the hover
        // band is not the one square thing left on the row.
        node.cornerRadius = SelectionAppearance.resolve(.navigation, theme: node.theme).cornerRadius
        let applyHover: (Bool) -> Void = { hovered in
            let hovered = hovered && node.supportsControlHover
            node.attachments[Self.hoveredKey] = hovered
            node.backgroundColor = hovered && !isSelected ? node.theme.colors.stateLayerHover : .clear
        }
        applyHover(node.attachments[Self.hoveredKey] as? Bool == true)
        registry.setHover(node) { applyHover($0 == .enter) }
        let captured = onActivate
        registry.setPointer(node) { event, phase, eventPhase in
            // Embedded controls get first refusal before row selection.
            guard eventPhase != .capture else { return .ignored }
            guard event.button == .left else { return .ignored }
            switch phase {
            case .down:
                node.attachments[Self.pressedKey] = true
                PointerCaptureHolder.current?.acquire(node)
                return .handled
            case .up:
                let was = (node.attachments[Self.pressedKey] as? Bool) ?? false
                node.attachments[Self.pressedKey] = false
                if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
                if was {
                    if node.absoluteFrame.contains(CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))) {
                        if let onTap { onTap(event.modifiers) } else { captured() }
                    }
                    return .handled
                }
                return .ignored
            }
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let l = LayoutNode()
        l.flexDirection = .column
        l.alignItems = .stretch
        l.height = rowHeight
        return l
    }

    func _updateLayout(_ layout: LayoutNode) { layout.height = rowHeight }

    func _children(for node: Node) -> [any View] {
        let style = node.compositionValue(of: ListRowStyleEnvironment.key)
        let cfg = ListRowStyleConfiguration(
            content: content,
            isSelected: isSelected,
            isHovered: false,
            isEnabled: true,
            rowHeight: rowHeight,
            theme: node.theme
        )
        return [style.makeBody(cfg)]
    }

    static let pressedKey = "__list_row_pressed"
    static let hoveredKey = "__list_row_hovered"
}
