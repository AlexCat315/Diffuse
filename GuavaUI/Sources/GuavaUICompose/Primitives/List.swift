import GuavaUIRuntime

/// Vertical, single-selection list. Visual chrome (selection fill, padding,
/// hover preview) is delegated to the active `ListRowStyle` via
/// `.listRowStyle(_:)`; defaults to `DefaultListRowStyle`.
public struct List<Data: RandomAccessCollection, ID: Hashable, RowContent: View>: View {
    public let data: Data
    public let id: KeyPath<Data.Element, ID>
    public let selection: Binding<ID?>
    public let rowHeight: Float
    public let rowSpacing: Float
    public let onActivate: ((Data.Element) -> Void)?
    public let rowContent: (Data.Element, Bool) -> RowContent

    public init(_ data: Data,
                id: KeyPath<Data.Element, ID>,
                selection: Binding<ID?> = .constant(nil),
                rowHeight: Float = 30,
                rowSpacing: Float = 0,
                onActivate: ((Data.Element) -> Void)? = nil,
                @ViewBuilder rowContent: @escaping (Data.Element, Bool) -> RowContent) {
        self.data = data
        self.id = id
        self.selection = selection
        self.rowHeight = rowHeight
        self.rowSpacing = rowSpacing
        self.onActivate = onActivate
        self.rowContent = rowContent
    }

    public var body: some View {
        ScrollView(.vertical) {
            Box(direction: .column, alignItems: .stretch, spacing: rowSpacing) {
                for element in data {
                    let selected = isSelected(element)
                    _ListRowHost(
                        isSelected: selected,
                        rowHeight: rowHeight,
                        onActivate: { activate(element) },
                        content: AnyView(rowContent(element, selected))
                    )
                }
            }
        }
    }

    private func isSelected(_ element: Data.Element) -> Bool {
        selection.wrappedValue == element[keyPath: id]
    }

    private func activate(_ element: Data.Element) {
        selection.wrappedValue = element[keyPath: id]
        onActivate?(element)
    }
}

public extension List where Data.Element: Identifiable, ID == Data.Element.ID {
    init(_ data: Data,
         selection: Binding<ID?> = .constant(nil),
         rowHeight: Float = 30,
         rowSpacing: Float = 0,
         onActivate: ((Data.Element) -> Void)? = nil,
         @ViewBuilder rowContent: @escaping (Data.Element, Bool) -> RowContent) {
        self.init(data, id: \.id,
                  selection: selection,
                  rowHeight: rowHeight, rowSpacing: rowSpacing,
                  onActivate: onActivate,
                  rowContent: rowContent)
    }
}

// MARK: - _ListRowHost

/// Primitive node behind each `List` row. Owns the tap handler and resolves
/// the active `ListRowStyle` via CompositionLocals on every recompose.
struct _ListRowHost: _PrimitiveView {
    let isSelected: Bool
    let rowHeight: Float
    let onActivate: () -> Void
    let content: AnyView

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        return n
    }

    func _updateNode(_ node: Node) {
        guard let registry = InteractionRegistryHolder.current else { return }
        let captured = onActivate
        registry.setPointer(node) { _, phase, _ in
            switch phase {
            case .down:
                node.attachments[Self.pressedKey] = true
                return .handled
            case .up:
                let was = (node.attachments[Self.pressedKey] as? Bool) ?? false
                node.attachments[Self.pressedKey] = false
                if was { captured(); return .handled }
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

    func _children(for node: Node) -> [any View] {
        let style = node.compositionValue(of: ListRowStyleEnvironment.key)
        let cfg = ListRowStyleConfiguration(
            content: content,
            isSelected: isSelected,
            isHovered: false,
            isEnabled: true,
            theme: node.theme
        )
        return [style.makeBody(cfg)]
    }

    static let pressedKey = "__list_row_pressed"
}
