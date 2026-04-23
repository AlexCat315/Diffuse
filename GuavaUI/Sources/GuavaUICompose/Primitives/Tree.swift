import GuavaUIRuntime

/// Hierarchical, single-selection tree. Visual chrome (selection fill,
/// indentation, disclosure chevron) is delegated to the active
/// `TreeRowStyle` via `.treeRowStyle(_:)`; defaults to `DefaultTreeRowStyle`.
public struct Tree<Roots: RandomAccessCollection, ID: Hashable, RowContent: View>: View {
    public typealias Element = Roots.Element
    public typealias DisclosureContent = (Bool) -> AnyView

    public let roots: [Element]
    public let id: KeyPath<Element, ID>
    public let children: (Element) -> [Element]
    public let selection: Binding<ID?>
    public let expanded: Binding<Set<ID>>?
    public let rowHeight: Float
    public let rowSpacing: Float
    public let indentation: Float
    public let disclosureWidth: Float
    public let showsIndentGuides: Bool
    public let disclosureContent: DisclosureContent?
    public let onSelect: ((Element) -> Void)?
    public let rowContent: (Element, Bool, Bool, Int) -> RowContent

    @State private var localExpanded: Set<ID> = []
    @State private var hoveredID: ID? = nil

    public init(_ roots: Roots,
                id: KeyPath<Element, ID>,
                children: @escaping (Element) -> [Element],
                selection: Binding<ID?> = .constant(nil),
                expanded: Binding<Set<ID>>? = nil,
                rowHeight: Float = 30,
                rowSpacing: Float = 0,
                indentation: Float = 14,
                disclosureWidth: Float = 18,
                showsIndentGuides: Bool = true,
                disclosureContent: DisclosureContent? = nil,
                onSelect: ((Element) -> Void)? = nil,
                @ViewBuilder rowContent: @escaping (Element, Bool, Bool, Int) -> RowContent) {
        self.roots = Array(roots)
        self.id = id
        self.children = children
        self.selection = selection
        self.expanded = expanded
        self.rowHeight = rowHeight
        self.rowSpacing = rowSpacing
        self.indentation = indentation
        self.disclosureWidth = disclosureWidth
        self.showsIndentGuides = showsIndentGuides
        self.disclosureContent = disclosureContent
        self.onSelect = onSelect
        self.rowContent = rowContent
    }

    public var body: some View {
        ScrollView(.vertical) {
            Box(direction: .column, alignItems: .stretch, spacing: rowSpacing) {
                for entry in visibleEntries {
                    let isSel = selection.wrappedValue == entry.id
                    _TreeRowComposite(
                        depth: entry.depth,
                        hasChildren: entry.hasChildren,
                        isExpanded: entry.isExpanded,
                        isSelected: isSel,
                        isHovered: hoveredID == entry.id,
                        rowHeight: rowHeight,
                        indentation: indentation,
                        disclosureWidth: disclosureWidth,
                        showsIndentGuides: showsIndentGuides,
                        disclosureContent: disclosureContent,
                        onToggle: { toggle(entry.id) },
                        onSelect: { select(entry.element) },
                        onHoverChange: { hovered in
                            if hovered {
                                if hoveredID != entry.id {
                                    hoveredID = entry.id
                                }
                            } else if hoveredID == entry.id {
                                hoveredID = nil
                            }
                        },
                        content: AnyView(rowContent(entry.element, isSel, entry.isExpanded, entry.depth))
                    )
                }
            }
        }
    }

    private var expandedIDs: Set<ID> {
        expanded?.wrappedValue ?? localExpanded
    }

    private var visibleEntries: [VisibleEntry] {
        var out: [VisibleEntry] = []
        appendVisible(nodes: roots, depth: 0, into: &out)
        return out
    }

    private func appendVisible(nodes: [Element],
                               depth: Int,
                               into out: inout [VisibleEntry]) {
        let expanded = expandedIDs
        for node in nodes {
            let nodeID = node[keyPath: id]
            let childNodes = children(node)
            let isExpanded = expanded.contains(nodeID)
            out.append(VisibleEntry(id: nodeID,
                                    element: node,
                                    depth: depth,
                                    hasChildren: !childNodes.isEmpty,
                                    isExpanded: isExpanded))
            if isExpanded && !childNodes.isEmpty {
                appendVisible(nodes: childNodes, depth: depth + 1, into: &out)
            }
        }
    }

    private func select(_ element: Element) {
        selection.wrappedValue = element[keyPath: id]
        onSelect?(element)
    }

    private func toggle(_ nodeID: ID) {
        var next = expandedIDs
        if next.contains(nodeID) {
            next.remove(nodeID)
        } else {
            next.insert(nodeID)
        }
        if let expanded {
            expanded.wrappedValue = next
        } else {
            localExpanded = next
        }
    }

    private struct VisibleEntry {
        let id: ID
        let element: Element
        let depth: Int
        let hasChildren: Bool
        let isExpanded: Bool
    }
}

// MARK: - Convenience inits

public extension Tree {
    init(_ roots: Roots,
         id: KeyPath<Element, ID>,
         children: KeyPath<Element, [Element]>,
         selection: Binding<ID?> = .constant(nil),
         expanded: Binding<Set<ID>>? = nil,
         rowHeight: Float = 30,
         rowSpacing: Float = 0,
         indentation: Float = 14,
         disclosureWidth: Float = 18,
         showsIndentGuides: Bool = true,
         disclosureContent: DisclosureContent? = nil,
         onSelect: ((Element) -> Void)? = nil,
         @ViewBuilder rowContent: @escaping (Element, Bool, Bool, Int) -> RowContent) {
        self.init(roots, id: id,
                  children: { $0[keyPath: children] },
                  selection: selection, expanded: expanded,
                  rowHeight: rowHeight, rowSpacing: rowSpacing,
                  indentation: indentation, disclosureWidth: disclosureWidth,
                  showsIndentGuides: showsIndentGuides,
                  disclosureContent: disclosureContent,
                  onSelect: onSelect, rowContent: rowContent)
    }
}

public extension Tree where Element: Identifiable, ID == Element.ID {
    init(_ roots: Roots,
         children: KeyPath<Element, [Element]>,
         selection: Binding<ID?> = .constant(nil),
         expanded: Binding<Set<ID>>? = nil,
         rowHeight: Float = 30,
         rowSpacing: Float = 0,
         indentation: Float = 14,
         disclosureWidth: Float = 18,
         showsIndentGuides: Bool = true,
         disclosureContent: DisclosureContent? = nil,
         onSelect: ((Element) -> Void)? = nil,
         @ViewBuilder rowContent: @escaping (Element, Bool, Bool, Int) -> RowContent) {
        self.init(roots, id: \.id,
                  children: children,
                  selection: selection, expanded: expanded,
                  rowHeight: rowHeight, rowSpacing: rowSpacing,
                  indentation: indentation, disclosureWidth: disclosureWidth,
                  showsIndentGuides: showsIndentGuides,
                  disclosureContent: disclosureContent,
                  onSelect: onSelect, rowContent: rowContent)
    }
}

// MARK: - _TreeRowComposite

/// One visible row in a `Tree`. The disclosure chevron stays a separate
/// `Button` (with `PlainButtonStyle` to avoid accent chrome) so it has its
/// own pointer node, keeping disclosure-vs-row hit testing trivial. The row
/// body itself is hosted by `_TreeRowHost` which delegates to the active
/// `TreeRowStyle`.
struct _TreeRowComposite: View {
    let depth: Int
    let hasChildren: Bool
    let isExpanded: Bool
    let isSelected: Bool
    let isHovered: Bool
    let rowHeight: Float
    let indentation: Float
    let disclosureWidth: Float
    let showsIndentGuides: Bool
    let disclosureContent: Tree<[Int], Int, EmptyView>.DisclosureContent?
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onHoverChange: (Bool) -> Void
    let content: AnyView

    var body: some View {
        Row(alignment: .center, spacing: 0) {
            if showsIndentGuides {
                for level in 0..<depth {
                    _TreeGuideCell(width: indentation,
                                   rowHeight: rowHeight,
                                   isActiveDepth: level == depth - 1)
                }
            } else if depth > 0 {
                Box { EmptyView() }
                    .frame(width: Float(depth) * indentation, height: rowHeight)
            }

            // Disclosure: a Button (so it gets its own pointer node) with
            // plain style so it adds no chrome of its own. Empty glyph when
            // the row has no children, but the slot is reserved so siblings
            // align.
            if hasChildren {
                Button(action: onToggle) {
                    if let disclosureContent {
                        disclosureContent(isExpanded)
                            .frame(width: disclosureWidth, height: rowHeight)
                    } else {
                        Text(isExpanded ? "▾" : "▸")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.onSurfaceVariant)
                            .frame(width: disclosureWidth, height: rowHeight)
                    }
                }
                .buttonStyle(.plain)
                .frame(width: disclosureWidth, height: rowHeight)
            } else {
                Box { EmptyView() }
                    .frame(width: disclosureWidth, height: rowHeight)
            }

            // Row body — delegates visuals to the TreeRowStyle env.
            _TreeRowHost(
                depth: depth,
                indentation: indentation,
                disclosureWidth: disclosureWidth,
                hasChildren: hasChildren,
                isExpanded: isExpanded,
                isSelected: isSelected,
                isHovered: isHovered,
                rowHeight: rowHeight,
                onSelect: onSelect,
                onHoverChange: onHoverChange,
                content: content
            )
            .flex()
        }
    }
}

private struct _TreeGuideCell: View {
    let width: Float
    let rowHeight: Float
    let isActiveDepth: Bool

    var body: some View {
        Box(direction: .row, alignItems: .stretch, justifyContent: .center) {
            Box { EmptyView() }
                .frame(width: 1)
                .background(.divider)
                .opacity(isActiveDepth ? 0.22 : 0.1)
        }
        .frame(width: width, height: rowHeight)
    }
}

struct _TreeRowHost: _PrimitiveView {
    let depth: Int
    let indentation: Float
    let disclosureWidth: Float
    let hasChildren: Bool
    let isExpanded: Bool
    let isSelected: Bool
    let isHovered: Bool
    let rowHeight: Float
    let onSelect: () -> Void
    let onHoverChange: (Bool) -> Void
    let content: AnyView

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        return n
    }

    func _updateNode(_ node: Node) {
        guard let registry = InteractionRegistryHolder.current else { return }
        let captured = onSelect
        let hoverChange = onHoverChange
        node.cursor = .pointer
        node.attachments[Self.hoveredKey] = isHovered
        registry.setHover(node) { phase in
            switch phase {
            case .enter:
                hoverChange(true)
            case .leave:
                hoverChange(false)
            }
        }
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
        // The chevron + indent gutter are drawn by `_TreeRowComposite`, so
        // the configuration we hand the style describes only the row body.
        // Style implementations that want to paint their own indent/chevron
        // can ignore the dedicated slots above and use these fields.
        let style = node.compositionValue(of: TreeRowStyleEnvironment.key)
        let cfg = TreeRowStyleConfiguration(
            content: content,
            depth: depth,
            indentation: indentation,
            disclosureWidth: disclosureWidth,
            hasChildren: hasChildren,
            isExpanded: isExpanded,
            isSelected: isSelected,
            isHovered: isHovered,
            isEnabled: true,
            theme: node.theme
        )
        return [style.makeBody(cfg)]
    }

    static let pressedKey = "__tree_row_pressed"
    static let hoveredKey = "__tree_row_hovered"
}
