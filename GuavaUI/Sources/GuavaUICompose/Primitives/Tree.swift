import EngineKernel
import GuavaUIRuntime

public enum TreeSearchFilterPolicy: Sendable {
    case highlightOnly
    case filterAndAutoExpand
}

/// Hierarchical, single-selection tree. Visual chrome (selection fill,
/// indentation, disclosure chevron) is delegated to the active
/// `TreeRowStyle` via `.treeRowStyle(_:)`; defaults to `DefaultTreeRowStyle`.
public struct Tree<Roots: RandomAccessCollection, ID: Hashable, RowContent: View>: View {
    public typealias Element = Roots.Element
    public typealias DisclosureContent = (Bool) -> AnyView
    public typealias TrailingContent = (Element, Bool, Bool, Bool, Bool, Int) -> AnyView

    public let roots: [Element]
    public let id: KeyPath<Element, ID>
    public let children: (Element) -> [Element]
    public let selection: Binding<ID?>
    public let multiSelection: Binding<Set<ID>>?
    public let expanded: Binding<Set<ID>>?
    public let rowHeight: Float
    public let rowSpacing: Float
    public let indentation: Float
    public let disclosureWidth: Float
    public let showsIndentGuides: Bool
    public let disclosureContent: DisclosureContent?
    public let trailingSlotWidth: Float
    public let trailingContent: TrailingContent?
    public let searchQuery: String
    public let searchText: ((Element) -> String)?
    public let searchFilterPolicy: TreeSearchFilterPolicy
    public let onKeyCommand: ((KeyEvent, Set<ID>) -> Bool)?
    public let onSelect: ((Element) -> Void)?
    public let rowContent: (Element, Bool, Bool, Int) -> RowContent

    @State private var localExpanded: Set<ID> = []
    @State private var hoveredID: ID? = nil
    @State private var activeModifiers: KeyModifiers = []
    @State private var rangeAnchorID: ID? = nil

    public init(_ roots: Roots,
                id: KeyPath<Element, ID>,
                children: @escaping (Element) -> [Element],
                selection: Binding<ID?> = .constant(nil),
                multiSelection: Binding<Set<ID>>? = nil,
                expanded: Binding<Set<ID>>? = nil,
                rowHeight: Float = 30,
                rowSpacing: Float = 0,
                indentation: Float = 14,
                disclosureWidth: Float = 18,
                showsIndentGuides: Bool = true,
                disclosureContent: DisclosureContent? = nil,
                trailingSlotWidth: Float = 64,
                trailingContent: TrailingContent? = nil,
                searchQuery: String = "",
                searchText: ((Element) -> String)? = nil,
                searchFilterPolicy: TreeSearchFilterPolicy = .filterAndAutoExpand,
                onKeyCommand: ((KeyEvent, Set<ID>) -> Bool)? = nil,
                onSelect: ((Element) -> Void)? = nil,
                @ViewBuilder rowContent: @escaping (Element, Bool, Bool, Int) -> RowContent) {
        self.roots = Array(roots)
        self.id = id
        self.children = children
        self.selection = selection
        self.multiSelection = multiSelection
        self.expanded = expanded
        self.rowHeight = rowHeight
        self.rowSpacing = rowSpacing
        self.indentation = indentation
        self.disclosureWidth = disclosureWidth
        self.showsIndentGuides = showsIndentGuides
        self.disclosureContent = disclosureContent
        self.trailingSlotWidth = trailingSlotWidth
        self.trailingContent = trailingContent
        self.searchQuery = searchQuery
        self.searchText = searchText
        self.searchFilterPolicy = searchFilterPolicy
        self.onKeyCommand = onKeyCommand
        self.onSelect = onSelect
        self.rowContent = rowContent
    }

    public var body: some View {
        ScrollView(.vertical) {
            Box(direction: .column, alignItems: .stretch, spacing: rowSpacing) {
                for entry in visibleEntries {
                    let isSel = selectedIDs.contains(entry.id)
                    _TreeRowComposite(
                        depth: entry.depth,
                        ancestorHasNextSiblings: entry.ancestorHasNextSiblings,
                        hasNextSibling: entry.hasNextSibling,
                        hasChildren: entry.hasChildren,
                        isExpanded: entry.isExpanded,
                        isSearchHit: entry.isSearchHit,
                        isSelected: isSel,
                        isHovered: hoveredID == entry.id,
                        rowHeight: rowHeight,
                        indentation: indentation,
                        disclosureWidth: disclosureWidth,
                        showsIndentGuides: showsIndentGuides,
                        disclosureContent: disclosureContent,
                        trailingSlotWidth: trailingContent == nil ? nil : trailingSlotWidth,
                        trailingContent: trailingContent.map {
                            $0(entry.element,
                               isSel,
                               entry.isExpanded,
                               entry.isSearchHit,
                               hoveredID == entry.id,
                               entry.depth)
                        },
                        onToggle: { toggle(entry.id) },
                        onSelect: { select(entry.element, modifiers: activeModifiers) },
                        onMoveSelection: { delta in
                            moveSelection(from: entry.id, delta: delta)
                        },
                        onCollapseOrParent: {
                            collapseOrSelectParent(entry)
                        },
                        onExpandOrChild: {
                            expandOrSelectFirstChild(entry)
                        },
                        onKeyEvent: { event in
                            activeModifiers = event.modifiers
                            if onKeyCommand?(event, selectedIDs) == true {
                                return true
                            }
                            return false
                        },
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

    private var selectedIDs: Set<ID> {
        if let multiSelection {
            return multiSelection.wrappedValue
        }
        guard let single = selection.wrappedValue else { return [] }
        return [single]
    }

    private var visibleEntries: [VisibleEntry] {
        let searchMetadata = buildSearchMetadata()
        let filterActive = isFilterActive
        let autoExpand = isAutoExpandActive
        var out: [VisibleEntry] = []
        appendVisible(nodes: roots,
                      depth: 0,
                      ancestorHasNextSiblings: [],
                      parentID: nil,
                      searchMetadata: searchMetadata,
                      filterActive: filterActive,
                      autoExpand: autoExpand,
                      into: &out)
        return out
    }

    private func appendVisible(nodes: [Element],
                               depth: Int,
                               ancestorHasNextSiblings: [Bool],
                               parentID: ID?,
                               searchMetadata: SearchMetadata?,
                               filterActive: Bool,
                               autoExpand: Bool,
                               into out: inout [VisibleEntry]) {
        let expanded = expandedIDs
        let visibleNodes: [Element]
        if filterActive {
            visibleNodes = nodes.filter {
                let nodeID = $0[keyPath: id]
                return searchMetadata?.subtreeMatches[nodeID] ?? false
            }
        } else {
            visibleNodes = nodes
        }

        for (index, node) in visibleNodes.enumerated() {
            let nodeID = node[keyPath: id]
            let childNodes = children(node)

            let selfMatches = searchMetadata?.selfMatches[nodeID] ?? false
            let childSubtreeMatches = childNodes.contains {
                let childID = $0[keyPath: id]
                return searchMetadata?.subtreeMatches[childID] ?? false
            }
            let isExpanded = expanded.contains(nodeID) || (autoExpand && childSubtreeMatches)
            let hasNextSibling = index < visibleNodes.count - 1
            out.append(VisibleEntry(id: nodeID,
                                    element: node,
                                    depth: depth,
                                    parentID: parentID,
                                    ancestorHasNextSiblings: ancestorHasNextSiblings,
                                    hasNextSibling: hasNextSibling,
                                    isSearchHit: selfMatches,
                                    hasChildren: !childNodes.isEmpty,
                                    isExpanded: isExpanded))
            if isExpanded && !childNodes.isEmpty {
                var childGuide = ancestorHasNextSiblings
                childGuide.append(hasNextSibling)
                appendVisible(nodes: childNodes,
                              depth: depth + 1,
                              ancestorHasNextSiblings: childGuide,
                              parentID: nodeID,
                              searchMetadata: searchMetadata,
                              filterActive: filterActive,
                              autoExpand: autoExpand,
                              into: &out)
            }
        }
    }

    private func select(_ element: Element,
                        modifiers: KeyModifiers) {
        let targetID = element[keyPath: id]
        if let multiSelection {
            var next = multiSelection.wrappedValue
            if modifiers.contains(.shift),
               let anchor = rangeAnchorID ?? selection.wrappedValue {
                let ids = idsBetween(anchor, targetID)
                if !ids.isEmpty {
                    next = ids
                } else {
                    next = [targetID]
                }
            } else if modifiers.contains(.gui) || modifiers.contains(.ctrl) {
                if next.contains(targetID) {
                    next.remove(targetID)
                } else {
                    next.insert(targetID)
                }
                if next.isEmpty {
                    rangeAnchorID = nil
                } else {
                    rangeAnchorID = targetID
                }
            } else {
                next = [targetID]
                rangeAnchorID = targetID
            }
            multiSelection.wrappedValue = next
            selection.wrappedValue = next.isEmpty ? nil : targetID
        } else {
            selection.wrappedValue = targetID
            rangeAnchorID = targetID
        }
        onSelect?(element)
    }

    private func idsBetween(_ a: ID, _ b: ID) -> Set<ID> {
        let entries = visibleEntries
        guard let ia = entries.firstIndex(where: { $0.id == a }),
              let ib = entries.firstIndex(where: { $0.id == b }) else {
            return []
        }
        let lower = min(ia, ib)
        let upper = max(ia, ib)
        return Set(entries[lower...upper].map(\.id))
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

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var isFilterActive: Bool {
        !normalizedSearchQuery.isEmpty
            && searchText != nil
            && searchFilterPolicy == .filterAndAutoExpand
    }

    private var isAutoExpandActive: Bool {
        isFilterActive
    }

    private struct SearchMetadata {
        var selfMatches: [ID: Bool]
        var subtreeMatches: [ID: Bool]
    }

    private func buildSearchMetadata() -> SearchMetadata? {
        let query = normalizedSearchQuery
        guard !query.isEmpty, let searchText else {
            return nil
        }
        var selfMatches: [ID: Bool] = [:]
        var subtreeMatches: [ID: Bool] = [:]

        func walk(_ node: Element) -> Bool {
            let nodeID = node[keyPath: id]
            let own = searchText(node).lowercased().contains(query)
            selfMatches[nodeID] = own
            var any = own
            for child in children(node) {
                if walk(child) {
                    any = true
                }
            }
            subtreeMatches[nodeID] = any
            return any
        }

        for root in roots {
            _ = walk(root)
        }

        return SearchMetadata(selfMatches: selfMatches,
                              subtreeMatches: subtreeMatches)
    }

    private func moveSelection(from currentID: ID, delta: Int) {
        let entries = visibleEntries
        guard let index = entries.firstIndex(where: { $0.id == currentID }) else { return }
        let target = max(0, min(entries.count - 1, index + delta))
        guard target != index else { return }
        select(entries[target].element, modifiers: activeModifiers)
    }

    private func collapseOrSelectParent(_ entry: VisibleEntry) {
        if entry.hasChildren && entry.isExpanded {
            toggle(entry.id)
            return
        }
        guard let parentID = entry.parentID,
              let parent = visibleEntries.first(where: { $0.id == parentID }) else {
            return
        }
                select(parent.element, modifiers: activeModifiers)
    }

    private func expandOrSelectFirstChild(_ entry: VisibleEntry) {
        guard entry.hasChildren else { return }
        if !entry.isExpanded {
            toggle(entry.id)
            return
        }
        guard let firstChild = children(entry.element).first else { return }
        select(firstChild, modifiers: activeModifiers)
    }

    private struct VisibleEntry {
        let id: ID
        let element: Element
        let depth: Int
        let parentID: ID?
        let ancestorHasNextSiblings: [Bool]
        let hasNextSibling: Bool
        let isSearchHit: Bool
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
            multiSelection: Binding<Set<ID>>? = nil,
         expanded: Binding<Set<ID>>? = nil,
         rowHeight: Float = 30,
         rowSpacing: Float = 0,
         indentation: Float = 14,
         disclosureWidth: Float = 18,
         showsIndentGuides: Bool = true,
         disclosureContent: DisclosureContent? = nil,
         trailingSlotWidth: Float = 64,
         trailingContent: TrailingContent? = nil,
         searchQuery: String = "",
         searchText: ((Element) -> String)? = nil,
         searchFilterPolicy: TreeSearchFilterPolicy = .filterAndAutoExpand,
         onKeyCommand: ((KeyEvent, Set<ID>) -> Bool)? = nil,
         onSelect: ((Element) -> Void)? = nil,
         @ViewBuilder rowContent: @escaping (Element, Bool, Bool, Int) -> RowContent) {
        self.init(roots, id: id,
                  children: { $0[keyPath: children] },
                  selection: selection,
                  multiSelection: multiSelection,
                  expanded: expanded,
                  rowHeight: rowHeight, rowSpacing: rowSpacing,
                  indentation: indentation, disclosureWidth: disclosureWidth,
                  showsIndentGuides: showsIndentGuides,
                  disclosureContent: disclosureContent,
                  trailingSlotWidth: trailingSlotWidth,
                  trailingContent: trailingContent,
                  searchQuery: searchQuery,
                  searchText: searchText,
                  searchFilterPolicy: searchFilterPolicy,
                  onKeyCommand: onKeyCommand,
                  onSelect: onSelect, rowContent: rowContent)
    }
}

public extension Tree where Element: Identifiable, ID == Element.ID {
    init(_ roots: Roots,
         children: KeyPath<Element, [Element]>,
         selection: Binding<ID?> = .constant(nil),
            multiSelection: Binding<Set<ID>>? = nil,
         expanded: Binding<Set<ID>>? = nil,
         rowHeight: Float = 30,
         rowSpacing: Float = 0,
         indentation: Float = 14,
         disclosureWidth: Float = 18,
         showsIndentGuides: Bool = true,
         disclosureContent: DisclosureContent? = nil,
         trailingSlotWidth: Float = 64,
         trailingContent: TrailingContent? = nil,
         searchQuery: String = "",
         searchText: ((Element) -> String)? = nil,
         searchFilterPolicy: TreeSearchFilterPolicy = .filterAndAutoExpand,
         onKeyCommand: ((KeyEvent, Set<ID>) -> Bool)? = nil,
         onSelect: ((Element) -> Void)? = nil,
         @ViewBuilder rowContent: @escaping (Element, Bool, Bool, Int) -> RowContent) {
        self.init(roots, id: \Element.id,
                  children: children,
                  selection: selection,
                  multiSelection: multiSelection,
                  expanded: expanded,
                  rowHeight: rowHeight, rowSpacing: rowSpacing,
                  indentation: indentation, disclosureWidth: disclosureWidth,
                  showsIndentGuides: showsIndentGuides,
                  disclosureContent: disclosureContent,
                  trailingSlotWidth: trailingSlotWidth,
                  trailingContent: trailingContent,
                  searchQuery: searchQuery,
                  searchText: searchText,
                  searchFilterPolicy: searchFilterPolicy,
                  onKeyCommand: onKeyCommand,
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
    let ancestorHasNextSiblings: [Bool]
    let hasNextSibling: Bool
    let hasChildren: Bool
    let isExpanded: Bool
    let isSearchHit: Bool
    let isSelected: Bool
    let isHovered: Bool
    let rowHeight: Float
    let indentation: Float
    let disclosureWidth: Float
    let showsIndentGuides: Bool
    let disclosureContent: Tree<[Int], Int, EmptyView>.DisclosureContent?
    let trailingSlotWidth: Float?
    let trailingContent: AnyView?
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onMoveSelection: (Int) -> Void
    let onCollapseOrParent: () -> Void
    let onExpandOrChild: () -> Void
    let onKeyEvent: (KeyEvent) -> Bool
    let onHoverChange: (Bool) -> Void
    let content: AnyView

    var body: some View {
        Row(alignment: .center, spacing: 0) {
            if showsIndentGuides {
                for level in 0..<depth {
                    if level == depth - 1 {
                        _TreeGuideCell(width: indentation,
                                       rowHeight: rowHeight,
                                       style: .branch(hasNextSibling: hasNextSibling))
                    } else if level < ancestorHasNextSiblings.count,
                              ancestorHasNextSiblings[level] {
                        _TreeGuideCell(width: indentation,
                                       rowHeight: rowHeight,
                                       style: .vertical)
                    } else {
                        _TreeGuideCell(width: indentation,
                                       rowHeight: rowHeight,
                                       style: .none)
                    }
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
                isSearchHit: isSearchHit,
                isSelected: isSelected,
                isHovered: isHovered,
                rowHeight: rowHeight,
                onSelect: onSelect,
                onMoveSelection: onMoveSelection,
                onCollapseOrParent: onCollapseOrParent,
                onExpandOrChild: onExpandOrChild,
                onKeyEvent: onKeyEvent,
                onHoverChange: onHoverChange,
                content: content
            )
            .flex()

            if let trailingSlotWidth,
               let trailingContent {
                _TreeTrailingSlotHost(width: trailingSlotWidth,
                                      rowHeight: rowHeight,
                                      content: trailingContent)
            }
        }
    }
}

private struct _TreeTrailingSlotHost: View {
    let width: Float
    let rowHeight: Float
    let content: AnyView

    var body: some View {
        Box(direction: .row, alignItems: .center, justifyContent: .flexEnd) {
            content
        }
        .padding(horizontal: 4, vertical: 0)
        .frame(width: width, height: rowHeight)
    }
}

private struct _TreeGuideCell: View {
    enum Style {
        case none
        case vertical
        case branch(hasNextSibling: Bool)
    }

    let width: Float
    let rowHeight: Float
    let style: Style

    private var centerLead: Float {
        let whole = max(2, width.rounded(.down))
        return ((whole - 1) * 0.5).rounded(.down)
    }

    private var trailingWidth: Float {
        max(0, width - centerLead - 1)
    }

    private var centerYLead: Float {
        let whole = max(2, rowHeight.rounded(.down))
        return max(0, ((whole - 1) * 0.5).rounded(.down))
    }

    private var bottomHeight: Float {
        max(0, rowHeight - centerYLead - 1)
    }

    var body: some View {
        switch style {
        case .none:
            return AnyView(
                Box { EmptyView() }
                    .frame(width: width, height: rowHeight)
            )
        case .vertical:
            return AnyView(
                Row(alignment: .center, spacing: 0) {
                    Box { EmptyView() }
                        .frame(width: centerLead, height: rowHeight)

                    Box { EmptyView() }
                        .frame(width: 1, height: rowHeight)
                        .background(.onSurfaceVariant)
                        .opacity(0.52)

                    Box { EmptyView() }
                        .frame(width: trailingWidth, height: rowHeight)
                }
                .frame(width: width, height: rowHeight)
            )
        case .branch(let hasNextSibling):
            return AnyView(
                Row(alignment: .center, spacing: 0) {
                    Box { EmptyView() }
                        .frame(width: centerLead, height: rowHeight)

                    Box(direction: .column, alignItems: .stretch, justifyContent: .flexStart) {
                        Box { EmptyView() }
                            .frame(width: 1,
                                   height: centerYLead + 1 + (hasNextSibling ? bottomHeight : 0))
                            .background(.onSurfaceVariant)
                            .opacity(0.6)
                    }
                    .frame(width: 1, height: rowHeight)

                    Box(direction: .column, alignItems: .stretch, justifyContent: .flexStart) {
                        Box { EmptyView() }
                            .frame(height: centerYLead)

                        Box { EmptyView() }
                            .frame(height: 1)
                            .background(.onSurfaceVariant)
                            .opacity(0.6)

                        Box { EmptyView() }
                            .frame(height: bottomHeight)
                    }
                    .frame(width: trailingWidth, height: rowHeight)
                }
                .frame(width: width, height: rowHeight)
            )
        }
    }
}

struct _TreeRowHost: _PrimitiveView {
    let depth: Int
    let indentation: Float
    let disclosureWidth: Float
    let hasChildren: Bool
    let isExpanded: Bool
    let isSearchHit: Bool
    let isSelected: Bool
    let isHovered: Bool
    let rowHeight: Float
    let onSelect: () -> Void
    let onMoveSelection: (Int) -> Void
    let onCollapseOrParent: () -> Void
    let onExpandOrChild: () -> Void
    let onKeyEvent: (KeyEvent) -> Bool
    let onHoverChange: (Bool) -> Void
    let content: AnyView

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.isFocusable = true
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
                FocusChainHolder.current?.focus(node)
                node.attachments[Self.pressedKey] = true
                return .handled
            case .up:
                let was = (node.attachments[Self.pressedKey] as? Bool) ?? false
                node.attachments[Self.pressedKey] = false
                if was { captured(); return .handled }
                return .ignored
            }
        }
        registry.setKey(node) { event, _ in
            if event.isRepeat { return .ignored }
            if onKeyEvent(event) {
                return .handled
            }
            switch event.scancode {
            case 82: // SDL_SCANCODE_UP
                onMoveSelection(-1)
                return .handled
            case 81: // SDL_SCANCODE_DOWN
                onMoveSelection(1)
                return .handled
            case 80: // SDL_SCANCODE_LEFT
                onCollapseOrParent()
                return .handled
            case 79: // SDL_SCANCODE_RIGHT
                onExpandOrChild()
                return .handled
            case 40, 44, 88: // RETURN, SPACE, KP_ENTER
                captured()
                return .handled
            default:
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
            isSearchHit: isSearchHit,
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
