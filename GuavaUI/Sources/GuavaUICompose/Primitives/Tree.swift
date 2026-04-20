import GuavaUIRuntime

public struct Tree<Roots: RandomAccessCollection, ID: Hashable, RowContent: View>: View {
    public typealias Element = Roots.Element

    public let roots: [Element]
    public let id: KeyPath<Element, ID>
    public let children: (Element) -> [Element]
    public let selection: Binding<ID?>
    public let expanded: Binding<Set<ID>>?
    public let rowHeight: Float
    public let rowSpacing: Float
    public let rowInsets: EdgeInsets
    public let indentation: Float
    public let disclosureWidth: Float
    public let onSelect: ((Element) -> Void)?
    public let rowContent: (Element, Bool, Bool, Int) -> RowContent

    @State private var localExpanded: Set<ID> = []

    public init(_ roots: Roots,
                id: KeyPath<Element, ID>,
                children: @escaping (Element) -> [Element],
                selection: Binding<ID?> = .constant(nil),
                expanded: Binding<Set<ID>>? = nil,
                rowHeight: Float = 30,
                rowSpacing: Float = 0,
                rowInsets: EdgeInsets = EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10),
                indentation: Float = 14,
                disclosureWidth: Float = 18,
                onSelect: ((Element) -> Void)? = nil,
                @ViewBuilder rowContent: @escaping (Element, Bool, Bool, Int) -> RowContent) {
        self.roots = Array(roots)
        self.id = id
        self.children = children
        self.selection = selection
        self.expanded = expanded
        self.rowHeight = rowHeight
        self.rowSpacing = rowSpacing
        self.rowInsets = rowInsets
        self.indentation = indentation
        self.disclosureWidth = disclosureWidth
        self.onSelect = onSelect
        self.rowContent = rowContent
    }

    public var body: some View {
        ScrollView(.vertical) {
            Box(direction: .column, alignItems: .stretch, spacing: rowSpacing) {
                for entry in visibleEntries {
                    _TreeRow(element: entry.element,
                             nodeID: entry.id,
                             depth: entry.depth,
                             hasChildren: entry.hasChildren,
                             isExpanded: entry.isExpanded,
                             isSelected: selection.wrappedValue == entry.id,
                             rowHeight: rowHeight,
                             rowInsets: rowInsets,
                             indentation: indentation,
                             disclosureWidth: disclosureWidth,
                             onToggle: { toggle(entry.id) },
                             onSelect: { select(entry.element) },
                             rowContent: rowContent)
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

private struct _TreeRow<Element, ID: Hashable, RowContent: View>: View {
    let element: Element
    let nodeID: ID
    let depth: Int
    let hasChildren: Bool
    let isExpanded: Bool
    let isSelected: Bool
    let rowHeight: Float
    let rowInsets: EdgeInsets
    let indentation: Float
    let disclosureWidth: Float
    let onToggle: () -> Void
    let onSelect: () -> Void
    let rowContent: (Element, Bool, Bool, Int) -> RowContent

    var body: some View {
        Row(alignment: .center, spacing: 0) {
            Box { EmptyView() }
                .frame(width: Float(depth) * indentation, height: rowHeight)

            if hasChildren {
                Button(action: onToggle) {
                    Text(isExpanded ? "▾" : "▸",
                         color: Color(r: 0.72, g: 0.76, b: 0.84))
                        .frame(width: disclosureWidth, height: rowHeight)
                }
                .frame(width: disclosureWidth, height: rowHeight)
            } else {
                Box { EmptyView() }
                    .frame(width: disclosureWidth, height: rowHeight)
            }

            _SelectableListRow(isSelected: isSelected,
                               rowHeight: rowHeight,
                               rowInsets: rowInsets,
                               action: onSelect) {
                rowContent(element, isSelected, isExpanded, depth)
            }
            .flex()
        }
    }
}

public extension Tree {
    init(_ roots: Roots,
         id: KeyPath<Element, ID>,
         children: KeyPath<Element, [Element]>,
         selection: Binding<ID?> = .constant(nil),
         expanded: Binding<Set<ID>>? = nil,
         rowHeight: Float = 30,
         rowSpacing: Float = 0,
         rowInsets: EdgeInsets = EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10),
         indentation: Float = 14,
         disclosureWidth: Float = 18,
         onSelect: ((Element) -> Void)? = nil,
         @ViewBuilder rowContent: @escaping (Element, Bool, Bool, Int) -> RowContent) {
        self.init(roots,
                  id: id,
                  children: { $0[keyPath: children] },
                  selection: selection,
                  expanded: expanded,
                  rowHeight: rowHeight,
                  rowSpacing: rowSpacing,
                  rowInsets: rowInsets,
                  indentation: indentation,
                  disclosureWidth: disclosureWidth,
                  onSelect: onSelect,
                  rowContent: rowContent)
    }
}

public extension Tree where Element: Identifiable, ID == Element.ID {
    init(_ roots: Roots,
         children: KeyPath<Element, [Element]>,
         selection: Binding<ID?> = .constant(nil),
         expanded: Binding<Set<ID>>? = nil,
         rowHeight: Float = 30,
         rowSpacing: Float = 0,
         rowInsets: EdgeInsets = EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10),
         indentation: Float = 14,
         disclosureWidth: Float = 18,
         onSelect: ((Element) -> Void)? = nil,
         @ViewBuilder rowContent: @escaping (Element, Bool, Bool, Int) -> RowContent) {
        self.init(roots,
                  id: \.id,
                  children: children,
                  selection: selection,
                  expanded: expanded,
                  rowHeight: rowHeight,
                  rowSpacing: rowSpacing,
                  rowInsets: rowInsets,
                  indentation: indentation,
                  disclosureWidth: disclosureWidth,
                  onSelect: onSelect,
                  rowContent: rowContent)
    }
}