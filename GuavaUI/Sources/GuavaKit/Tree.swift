// Hierarchical, single-selection tree — a focused MVP of the legacy
// GuavaUICompose `Tree`. Covers the 80% case: expand/collapse with a disclosure
// chevron, depth indentation, and themed selection. Multi-select, range-select,
// drag-and-drop, search/filter, indent guides, and keyboard navigation are
// deliberately deferred (see the legacy Tree for the full feature set).
//
// Rows are clickable via `Button`; the disclosure chevron is a nested `Button`
// that consumes its own click (so toggling a node doesn't also select it).

public struct Tree<Item, ID: Hashable, RowContent: View>: View {
    private let roots: [Item]
    private let idKey: KeyPath<Item, ID>
    private let childrenOf: (Item) -> [Item]
    private let selection: Binding<ID?>
    private let externalExpanded: Binding<Set<ID>>?
    private let rowHeight: Float
    private let indentation: Float
    private let onSelect: ((Item) -> Void)?
    private let rowContent: (Item, Bool, Int) -> RowContent

    /// Used when no external `expanded` binding is supplied.
    @State private var localExpanded: Set<ID> = []

    public init(_ roots: [Item],
                id: KeyPath<Item, ID>,
                children: @escaping (Item) -> [Item],
                selection: Binding<ID?>,
                expanded: Binding<Set<ID>>? = nil,
                rowHeight: Float = 24,
                indentation: Float = 14,
                onSelect: ((Item) -> Void)? = nil,
                @ViewBuilder rowContent: @escaping (Item, Bool, Int) -> RowContent) {
        self.roots = roots
        self.idKey = id
        self.childrenOf = children
        self.selection = selection
        self.externalExpanded = expanded
        self.rowHeight = rowHeight
        self.indentation = indentation
        self.onSelect = onSelect
        self.rowContent = rowContent
    }

    public var body: some View {
        ScrollView(.column) {
            Column(alignment: .stretch, spacing: 0) {
                for entry in visibleEntries {
                    row(for: entry)
                }
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(for entry: Entry) -> some View {
        let isSelected = selection.wrappedValue == entry.id
        Button(action: { select(entry) }) {
            Row(alignment: .center, spacing: 0) {
                Element(width: Float(entry.depth) * indentation, height: rowHeight)
                disclosure(for: entry)
                rowContent(entry.item, isSelected, entry.depth)
                Spacer()
            }
            .frame(height: rowHeight)
            .background(isSelected ? SemanticColorRef.stateLayerSelected : .clear)
        }
    }

    @ViewBuilder
    private func disclosure(for entry: Entry) -> some View {
        if entry.hasChildren {
            Button(action: { toggle(entry.id) }) {
                Text(entry.isExpanded ? "▾" : "▸", fontSize: 9)
                    .foregroundColor(.onSurfaceMuted)
                    .frame(width: 16, height: rowHeight)
            }
        } else {
            Element(width: 16, height: rowHeight)
        }
    }

    // MARK: - Expansion / selection

    private var expandedSet: Set<ID> { externalExpanded?.wrappedValue ?? localExpanded }

    private func setExpanded(_ next: Set<ID>) {
        if let externalExpanded { externalExpanded.wrappedValue = next } else { localExpanded = next }
    }

    private func toggle(_ id: ID) {
        var next = expandedSet
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        setExpanded(next)
    }

    private func select(_ entry: Entry) {
        selection.wrappedValue = entry.id
        onSelect?(entry.item)
    }

    // MARK: - Flatten (visible rows in display order)

    private struct Entry {
        let item: Item
        let id: ID
        let depth: Int
        let hasChildren: Bool
        let isExpanded: Bool
    }

    private var visibleEntries: [Entry] {
        var out: [Entry] = []
        let expanded = expandedSet
        func walk(_ nodes: [Item], depth: Int) {
            for node in nodes {
                let nid = node[keyPath: idKey]
                let kids = childrenOf(node)
                let isExpanded = expanded.contains(nid)
                out.append(Entry(item: node, id: nid, depth: depth,
                                 hasChildren: !kids.isEmpty, isExpanded: isExpanded))
                if isExpanded && !kids.isEmpty { walk(kids, depth: depth + 1) }
            }
        }
        walk(roots, depth: 0)
        return out
    }
}

// MARK: - Convenience init (children via key path)

public extension Tree {
    init(_ roots: [Item],
         id: KeyPath<Item, ID>,
         children: KeyPath<Item, [Item]>,
         selection: Binding<ID?>,
         expanded: Binding<Set<ID>>? = nil,
         rowHeight: Float = 24,
         indentation: Float = 14,
         onSelect: ((Item) -> Void)? = nil,
         @ViewBuilder rowContent: @escaping (Item, Bool, Int) -> RowContent) {
        self.init(roots, id: id, children: { $0[keyPath: children] },
                  selection: selection, expanded: expanded,
                  rowHeight: rowHeight, indentation: indentation,
                  onSelect: onSelect, rowContent: rowContent)
    }
}
