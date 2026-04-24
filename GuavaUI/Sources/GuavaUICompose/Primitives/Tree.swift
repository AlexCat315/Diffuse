import EngineKernel
import CoreGraphics
import GuavaUIRuntime

public enum TreeSearchFilterPolicy: Sendable {
    case highlightOnly
    case filterAndAutoExpand
}

public enum TreeDropPosition: Sendable, Equatable {
    case before
    case inside
    case after
}

public struct TreeNodeKey<ID: Hashable>: Hashable {
    public let id: ID
    public let path: [Int]

    public init(id: ID, path: [Int]) {
        self.id = id
        self.path = path
    }
}

/// Hierarchical, single-selection tree. Visual chrome (selection fill,
/// indentation, disclosure chevron) is delegated to the active
/// `TreeRowStyle` via `.treeRowStyle(_:)`; defaults to `DefaultTreeRowStyle`.
public struct Tree<Roots: RandomAccessCollection, ID: Hashable, RowContent: View>: View {
    public typealias Element = Roots.Element
    public typealias DisclosureContent = (Bool) -> AnyView
    public typealias TrailingContent = (Element, Bool, Bool, Bool, Bool, Int) -> AnyView
    public typealias CanDrop = (Element, Element, TreeDropPosition) -> Bool
    public typealias OnDrop = (Element, Element, TreeDropPosition) -> Void

    public let roots: [Element]
    public let id: KeyPath<Element, ID>
    public let children: (Element) -> [Element]
    public let selection: Binding<ID?>
    public let multiSelection: Binding<Set<ID>>?
    public let expanded: Binding<Set<ID>>?
    public let selectionKey: Binding<TreeNodeKey<ID>?>
    public let multiSelectionKeys: Binding<Set<TreeNodeKey<ID>>>?
    public let expandedKeys: Binding<Set<TreeNodeKey<ID>>>?
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
    public let canDrop: CanDrop?
    public let onDrop: OnDrop?
    public let rowContent: (Element, Bool, Bool, Int) -> RowContent

    @State private var localExpanded: Set<ID> = []
    @State private var hoveredToken: TreeNodeKey<ID>? = nil
    @State private var activeModifiers: KeyModifiers = []
    @State private var rangeAnchorID: ID? = nil
    @State private var rangeAnchorKey: TreeNodeKey<ID>? = nil
    @State private var dragState: _TreeDragState<TreeNodeKey<ID>>? = nil
    @State private var dragCursorPos: CGPoint = .zero
    @State private var dragRegistry = _TreeRowDragRegistry<AnyHashable>()

    public init(_ roots: Roots,
                id: KeyPath<Element, ID>,
                children: @escaping (Element) -> [Element],
                selection: Binding<ID?> = .constant(nil),
                multiSelection: Binding<Set<ID>>? = nil,
                expanded: Binding<Set<ID>>? = nil,
                selectionKey: Binding<TreeNodeKey<ID>?> = .constant(nil),
                multiSelectionKeys: Binding<Set<TreeNodeKey<ID>>>? = nil,
                expandedKeys: Binding<Set<TreeNodeKey<ID>>>? = nil,
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
                canDrop: CanDrop? = nil,
                onDrop: OnDrop? = nil,
                @ViewBuilder rowContent: @escaping (Element, Bool, Bool, Int) -> RowContent) {
        self.roots = Array(roots)
        self.id = id
        self.children = children
        self.selection = selection
        self.multiSelection = multiSelection
        self.expanded = expanded
        self.selectionKey = selectionKey
        self.multiSelectionKeys = multiSelectionKeys
        self.expandedKeys = expandedKeys
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
        self.canDrop = canDrop
        self.onDrop = onDrop
        self.rowContent = rowContent
    }

    public var body: some View {
        let entries = visibleEntries
        let entriesByToken = Dictionary(uniqueKeysWithValues: entries.map { ($0.nodeKey, $0) })
        let guideRows = entries.map {
            _TreeGuideRowSnapshot(depth: $0.depth,
                                  ancestorHasNextSiblings: $0.ancestorHasNextSiblings,
                                  hasNextSibling: $0.hasNextSibling,
                                  hasChildren: $0.hasChildren,
                                  isExpanded: $0.isExpanded)
        }
        let activeDrag = dragState
        _TreeGhostContainer(dragCursorPos: activeDrag != nil ? dragCursorPos : nil,
                            rowHeight: rowHeight) {
        ScrollView(.vertical) {
            _TreeGuideOverlayHost(rows: guideRows,
                                  rowHeight: rowHeight,
                                  rowSpacing: rowSpacing,
                                  indentation: indentation,
                                  showsIndentGuides: showsIndentGuides) {
                Box(direction: .column, alignItems: .stretch, spacing: rowSpacing) {
                    for entry in entries {
                        let token = entry.nodeKey
                        let isSel: Bool = {
                            if multiSelectionKeys != nil || selectionKey.wrappedValue != nil {
                                return selectedNodeKeys.contains(token)
                            }
                            return selectedIDs.contains(entry.id)
                        }()
                        _TreeRowComposite(
                            depth: entry.depth,
                            hasChildren: entry.hasChildren,
                            isExpanded: entry.isExpanded,
                            isSearchHit: entry.isSearchHit,
                            isSelected: isSel,
                            isHovered: hoveredToken == token,
                            dropPosition: dragState?.targetID == token ? dragState?.position : nil,
                            dragID: AnyHashable(token),
                            rowHeight: rowHeight,
                            indentation: indentation,
                            disclosureWidth: disclosureWidth,
                            disclosureContent: disclosureContent,
                            trailingSlotWidth: trailingContent == nil ? nil : trailingSlotWidth,
                            trailingContent: trailingContent.map {
                                $0(entry.element,
                                   isSel,
                                   entry.isExpanded,
                                   entry.isSearchHit,
                                   hoveredToken == token,
                                   entry.depth)
                            },
                            onToggle: { toggle(entry.nodeKey, legacyID: entry.id) },
                            onSelect: { modifiers in
                                select(entry, modifiers: modifiers)
                            },
                            onMoveSelection: { delta in
                                moveSelection(from: entry.nodeKey, delta: delta)
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
                            onDragStart: {
                                beginDrag(from: token)
                            },
                            onDragMove: { x, y in
                                updateDrag(from: token,
                                           pointerX: x,
                                           pointerY: y,
                                           entriesByToken: entriesByToken)
                            },
                            onDragEnd: {
                                commitDrag(entriesByToken: entriesByToken)
                            },
                            onDragCancel: cancelDrag,
                            dragRegistry: dragRegistry,
                            isDragEnabled: onDrop != nil,
                            isDragSource: activeDrag?.sourceID == token,
                            onHoverChange: { hovered in
                                if hovered {
                                    if hoveredToken != token {
                                        hoveredToken = token
                                    }
                                } else if hoveredToken == token {
                                    hoveredToken = nil
                                }
                            },
                            content: AnyView(rowContent(entry.element, isSel, entry.isExpanded, entry.depth))
                        )
                        .id(token)
                    }
                }
            }
        }
        } // _TreeGhostContainer
    }

    private var expandedNodeKeys: Set<TreeNodeKey<ID>> {
        expandedKeys?.wrappedValue ?? []
    }

    private var expandedIDs: Set<ID> {
        if expandedKeys != nil {
            return Set(expandedNodeKeys.map(\ .id))
        }
        return expanded?.wrappedValue ?? localExpanded
    }

    private var selectedIDs: Set<ID> {
        if let multiSelectionKeys {
            return Set(multiSelectionKeys.wrappedValue.map(\ .id))
        }
        if let multiSelection {
            return multiSelection.wrappedValue
        }
        if let selected = selectionKey.wrappedValue {
            return [selected.id]
        }
        guard let single = selection.wrappedValue else { return [] }
        return [single]
    }

    private var selectedNodeKeys: Set<TreeNodeKey<ID>> {
        if let multiSelectionKeys {
            return multiSelectionKeys.wrappedValue
        }
        if let selected = selectionKey.wrappedValue {
            return [selected]
        }
        return []
    }

    private var visibleEntries: [VisibleEntry] {
        let searchMetadata = buildSearchMetadata()
        let filterActive = isFilterActive
        let autoExpand = isAutoExpandActive
        var out: [VisibleEntry] = []
        appendVisible(nodes: roots,
                      depth: 0,
                      pathPrefix: [],
                      ancestorHasNextSiblings: [],
                      parentID: nil,
                      parentKey: nil,
                      searchMetadata: searchMetadata,
                      filterActive: filterActive,
                      autoExpand: autoExpand,
                      into: &out)
        return out
    }

    private func appendVisible(nodes: [Element],
                               depth: Int,
                               pathPrefix: [Int],
                               ancestorHasNextSiblings: [Bool],
                               parentID: ID?,
                               parentKey: TreeNodeKey<ID>?,
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
            let path = pathPrefix + [index]
            let nodeKey = TreeNodeKey(id: nodeID, path: path)
            let childNodes = children(node)

            let selfMatches = searchMetadata?.selfMatches[nodeID] ?? false
            let childSubtreeMatches = childNodes.contains {
                let childID = $0[keyPath: id]
                return searchMetadata?.subtreeMatches[childID] ?? false
            }
            let isExpanded = expanded.contains(nodeID)
                || expandedNodeKeys.contains(nodeKey)
                || (autoExpand && childSubtreeMatches)
            let hasNextSibling = index < visibleNodes.count - 1
            out.append(VisibleEntry(id: nodeID,
                                    nodeKey: nodeKey,
                                    element: node,
                                    depth: depth,
                                    parentID: parentID,
                                    parentKey: parentKey,
                                    ancestorHasNextSiblings: ancestorHasNextSiblings,
                                    hasNextSibling: hasNextSibling,
                                    isSearchHit: selfMatches,
                                    hasChildren: !childNodes.isEmpty,
                                    isExpanded: isExpanded))
            if isExpanded && !childNodes.isEmpty {
                var childGuide = ancestorHasNextSiblings
                // Guide columns map to depth>=1 path siblings. Root-level
                // sibling state has no dedicated guide column and would shift
                // descendant columns by one, creating depth-2+ breaks.
                if depth > 0 {
                    childGuide.append(hasNextSibling)
                }
                appendVisible(nodes: childNodes,
                              depth: depth + 1,
                              pathPrefix: path,
                              ancestorHasNextSiblings: childGuide,
                              parentID: nodeID,
                              parentKey: nodeKey,
                              searchMetadata: searchMetadata,
                              filterActive: filterActive,
                              autoExpand: autoExpand,
                              into: &out)
            }
        }
    }

    private func select(_ entry: VisibleEntry,
                        modifiers: KeyModifiers) {
        let targetID = entry.id
        let targetKey = entry.nodeKey

        if let multiSelectionKeys {
            var next = multiSelectionKeys.wrappedValue
            var nextPrimary: TreeNodeKey<ID>? = targetKey
            if modifiers.contains(.shift),
               let anchor = rangeAnchorKey ?? selectionKey.wrappedValue {
                let keys = keysBetween(anchor, targetKey)
                next = keys.isEmpty ? [targetKey] : keys
                nextPrimary = targetKey
            } else if modifiers.contains(.gui) || modifiers.contains(.ctrl) {
                if next.contains(targetKey) {
                    next.remove(targetKey)
                } else {
                    next.insert(targetKey)
                }
                if next.isEmpty {
                    rangeAnchorKey = nil
                    nextPrimary = nil
                } else {
                    rangeAnchorKey = targetKey
                    nextPrimary = next.contains(targetKey) ? targetKey : firstVisibleKey(in: next)
                }
            } else {
                next = [targetKey]
                rangeAnchorKey = targetKey
                nextPrimary = targetKey
            }
            multiSelectionKeys.wrappedValue = next
            selectionKey.wrappedValue = nextPrimary
            selection.wrappedValue = nextPrimary?.id
            if let multiSelection {
                multiSelection.wrappedValue = Set(next.map(\ .id))
            }
            onSelect?(entry.element)
            return
        }

        if let multiSelection {
            var next = multiSelection.wrappedValue
            var nextPrimary: ID? = targetID
            if modifiers.contains(.shift),
               let anchor = rangeAnchorID ?? selection.wrappedValue {
                let ids = idsBetween(anchor, targetID)
                if !ids.isEmpty {
                    next = ids
                } else {
                    next = [targetID]
                }
                nextPrimary = targetID
            } else if modifiers.contains(.gui) || modifiers.contains(.ctrl) {
                if next.contains(targetID) {
                    next.remove(targetID)
                } else {
                    next.insert(targetID)
                }
                if next.isEmpty {
                    rangeAnchorID = nil
                    nextPrimary = nil
                } else {
                    rangeAnchorID = targetID
                    if next.contains(targetID) {
                        nextPrimary = targetID
                    } else {
                        nextPrimary = firstVisibleID(in: next)
                    }
                }
            } else {
                next = [targetID]
                rangeAnchorID = targetID
                nextPrimary = targetID
            }
            multiSelection.wrappedValue = next
            selection.wrappedValue = nextPrimary
            selectionKey.wrappedValue = nextPrimary.flatMap { primary in
                visibleEntries.first(where: { $0.id == primary })?.nodeKey
            }
        } else {
            selection.wrappedValue = targetID
            selectionKey.wrappedValue = targetKey
            rangeAnchorID = targetID
        }
        onSelect?(entry.element)
    }

    private func keysBetween(_ a: TreeNodeKey<ID>, _ b: TreeNodeKey<ID>) -> Set<TreeNodeKey<ID>> {
        let entries = visibleEntries
        guard let ia = entries.firstIndex(where: { $0.nodeKey == a }),
              let ib = entries.firstIndex(where: { $0.nodeKey == b }) else {
            return []
        }
        let lower = min(ia, ib)
        let upper = max(ia, ib)
        return Set(entries[lower...upper].map(\ .nodeKey))
    }

    private func firstVisibleKey(in candidates: Set<TreeNodeKey<ID>>) -> TreeNodeKey<ID>? {
        for entry in visibleEntries where candidates.contains(entry.nodeKey) {
            return entry.nodeKey
        }
        return candidates.sorted { $0.path.lexicographicallyPrecedes($1.path) }.first
    }

    private func firstVisibleID(in candidates: Set<ID>) -> ID? {
        for entry in visibleEntries where candidates.contains(entry.id) {
            return entry.id
        }
        return candidates.sorted { String(describing: $0) < String(describing: $1) }.first
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
        if let entry = visibleEntries.first(where: { $0.id == nodeID }) {
            toggle(entry.nodeKey, legacyID: nodeID)
            return
        }
        var next = expandedIDs
        if next.contains(nodeID) { next.remove(nodeID) } else { next.insert(nodeID) }
        if let expanded { expanded.wrappedValue = next } else { localExpanded = next }
    }

    private func toggle(_ nodeKey: TreeNodeKey<ID>, legacyID: ID) {
        if let expandedKeys {
            var next = expandedKeys.wrappedValue
            if next.contains(nodeKey) {
                next.remove(nodeKey)
            } else {
                next.insert(nodeKey)
            }
            expandedKeys.wrappedValue = next
            if let expanded {
                expanded.wrappedValue = Set(next.map(\ .id))
            }
            return
        }

        var next = expandedIDs
        if next.contains(legacyID) {
            next.remove(legacyID)
        } else {
            next.insert(legacyID)
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

    private func moveSelection(from currentKey: TreeNodeKey<ID>, delta: Int) {
        let entries = visibleEntries
        guard let index = entries.firstIndex(where: { $0.nodeKey == currentKey }) else { return }
        let target = max(0, min(entries.count - 1, index + delta))
        guard target != index else { return }
        select(entries[target], modifiers: activeModifiers)
    }

    private func collapseOrSelectParent(_ entry: VisibleEntry) {
        if entry.hasChildren && entry.isExpanded {
            toggle(entry.id)
            return
        }
        guard let parent = entry.parentKey.flatMap({ key in
            visibleEntries.first(where: { $0.nodeKey == key })
        }) ?? entry.parentID.flatMap({ id in
            visibleEntries.first(where: { $0.id == id })
        }) else {
            return
        }
        select(parent, modifiers: activeModifiers)
    }

    private func expandOrSelectFirstChild(_ entry: VisibleEntry) {
        guard entry.hasChildren else { return }
        if !entry.isExpanded {
            toggle(entry.nodeKey, legacyID: entry.id)
            return
        }
        guard let firstChild = visibleEntries.first(where: { $0.parentKey == entry.nodeKey }) else {
            return
        }
        select(firstChild, modifiers: activeModifiers)
    }

    private func beginDrag(from sourceToken: TreeNodeKey<ID>) {
        guard onDrop != nil else { return }
        dragState = _TreeDragState(sourceID: sourceToken,
                                   targetID: nil,
                                   position: nil)
    }

    private func updateDrag(from sourceToken: TreeNodeKey<ID>,
                            pointerX: Float,
                            pointerY: Float,
                            entriesByToken: [TreeNodeKey<ID>: VisibleEntry]) {
        guard onDrop != nil else { return }
        dragCursorPos = CGPoint(x: CGFloat(pointerX), y: CGFloat(pointerY))
        guard let hit = dragRegistry.hit(atX: pointerX, y: pointerY),
              let targetToken = hit.id.base as? TreeNodeKey<ID>,
              let sourceEntry = entriesByToken[sourceToken],
              let targetEntry = entriesByToken[targetToken],
              sourceToken != targetToken else {
            dragState = _TreeDragState(sourceID: sourceToken, targetID: nil, position: nil)
            return
        }
        let position = dropPosition(for: pointerY, frame: hit.frame)
        if canDrop?(sourceEntry.element, targetEntry.element, position) == false {
            dragState = _TreeDragState(sourceID: sourceToken, targetID: nil, position: nil)
            return
        }
        dragState = _TreeDragState(sourceID: sourceToken,
                                   targetID: targetToken,
                                   position: position)
    }

    private func commitDrag(entriesByToken: [TreeNodeKey<ID>: VisibleEntry]) {
        defer { dragState = nil }
        guard let state = dragState,
              let targetToken = state.targetID,
              let position = state.position,
              let sourceEntry = entriesByToken[state.sourceID],
              let targetEntry = entriesByToken[targetToken] else {
            return
        }
        onDrop?(sourceEntry.element, targetEntry.element, position)
    }

    private func cancelDrag() {
        dragState = nil
    }

    private func dropPosition(for pointerY: Float,
                              frame: CGRect) -> TreeDropPosition {
        let localY = CGFloat(pointerY) - frame.minY
        let topBand = max(6, frame.height * 0.28)
        let bottomBandStart = frame.height - topBand
        if localY <= topBand {
            return .before
        }
        if localY >= bottomBandStart {
            return .after
        }
        return .inside
    }

    private struct VisibleEntry {
        let id: ID
        let nodeKey: TreeNodeKey<ID>
        let element: Element
        let depth: Int
        let parentID: ID?
        let parentKey: TreeNodeKey<ID>?
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
            selectionKey: Binding<TreeNodeKey<ID>?> = .constant(nil),
            multiSelectionKeys: Binding<Set<TreeNodeKey<ID>>>? = nil,
            expandedKeys: Binding<Set<TreeNodeKey<ID>>>? = nil,
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
         canDrop: CanDrop? = nil,
         onDrop: OnDrop? = nil,
         @ViewBuilder rowContent: @escaping (Element, Bool, Bool, Int) -> RowContent) {
        self.init(roots, id: id,
                  children: { $0[keyPath: children] },
                  selection: selection,
                  multiSelection: multiSelection,
                  expanded: expanded,
                  selectionKey: selectionKey,
                  multiSelectionKeys: multiSelectionKeys,
                  expandedKeys: expandedKeys,
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
                  onSelect: onSelect,
                  canDrop: canDrop,
                  onDrop: onDrop,
                  rowContent: rowContent)
    }
}

public extension Tree where Element: Identifiable, ID == Element.ID {
    init(_ roots: Roots,
         children: KeyPath<Element, [Element]>,
         selection: Binding<ID?> = .constant(nil),
            multiSelection: Binding<Set<ID>>? = nil,
         expanded: Binding<Set<ID>>? = nil,
            selectionKey: Binding<TreeNodeKey<ID>?> = .constant(nil),
            multiSelectionKeys: Binding<Set<TreeNodeKey<ID>>>? = nil,
            expandedKeys: Binding<Set<TreeNodeKey<ID>>>? = nil,
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
         canDrop: CanDrop? = nil,
         onDrop: OnDrop? = nil,
         @ViewBuilder rowContent: @escaping (Element, Bool, Bool, Int) -> RowContent) {
        self.init(roots, id: \Element.id,
                  children: children,
                  selection: selection,
                  multiSelection: multiSelection,
                  expanded: expanded,
                  selectionKey: selectionKey,
                  multiSelectionKeys: multiSelectionKeys,
                  expandedKeys: expandedKeys,
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
                  onSelect: onSelect,
                  canDrop: canDrop,
                  onDrop: onDrop,
                  rowContent: rowContent)
    }
}

private struct _TreeDragState<ID: Hashable> {
    let sourceID: ID
    let targetID: ID?
    let position: TreeDropPosition?
}

private final class _TreeRowDragRegistry<ID: Hashable>: @unchecked Sendable {
    private final class Entry {
        weak var node: Node?
        let id: ID
        // Extra width extending the hit zone to the left (covers indent gutter
        // + disclosure slot so drags over indented areas still register a hit).
        var extraLeft: CGFloat

        init(node: Node, id: ID, extraLeft: CGFloat = 0) {
            self.node = node
            self.id = id
            self.extraLeft = extraLeft
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func register(node: Node, id: ID, extraLeft: CGFloat = 0) {
        entries[ObjectIdentifier(node)] = Entry(node: node, id: id, extraLeft: extraLeft)
    }

    /// Returns the hit entry and its *expanded* frame (including extraLeft)
    /// so callers can use it for drop-position band calculation.
    func hit(atX x: Float, y: Float) -> (id: ID, frame: CGRect)? {
        pruneReleasedNodes()
        var result: (id: ID, frame: CGRect)?
        for entry in entries.values {
            guard let node = entry.node else { continue }
            let frame = treeAbsoluteFrame(of: node)
            let expanded = CGRect(x: frame.minX - entry.extraLeft,
                                  y: frame.minY,
                                  width: frame.width + entry.extraLeft,
                                  height: frame.height)
            if expanded.contains(x: CGFloat(x), y: CGFloat(y)) {
                result = (entry.id, expanded)
            }
        }
        return result
    }

    private func pruneReleasedNodes() {
        entries = entries.filter { _, entry in entry.node != nil }
    }
}

// MARK: - _TreeRowComposite

/// One visible row in a `Tree`. The disclosure chevron stays a separate
/// `Button` (with `PlainButtonStyle` to avoid accent chrome) so it has its
/// own pointer node, keeping disclosure-vs-row hit testing trivial. The row
/// body itself is hosted by `_TreeRowHost` which delegates to the active
/// `TreeRowStyle`.
private struct _TreeRowComposite: View {
    let depth: Int
    let hasChildren: Bool
    let isExpanded: Bool
    let isSearchHit: Bool
    let isSelected: Bool
    let isHovered: Bool
    let dropPosition: TreeDropPosition?
    let dragID: AnyHashable
    let rowHeight: Float
    let indentation: Float
    let disclosureWidth: Float
    let disclosureContent: Tree<[Int], Int, EmptyView>.DisclosureContent?
    let trailingSlotWidth: Float?
    let trailingContent: AnyView?
    let onToggle: () -> Void
    let onSelect: (KeyModifiers) -> Void
    let onMoveSelection: (Int) -> Void
    let onCollapseOrParent: () -> Void
    let onExpandOrChild: () -> Void
    let onKeyEvent: (KeyEvent) -> Bool
    let onDragStart: () -> Void
    let onDragMove: (Float, Float) -> Void
    let onDragEnd: () -> Void
    let onDragCancel: () -> Void
    let dragRegistry: _TreeRowDragRegistry<AnyHashable>
    let isDragEnabled: Bool
    let isDragSource: Bool
    let onHoverChange: (Bool) -> Void
    let content: AnyView

    var body: some View {
        let indentWidth = max(0, Float(depth) * indentation)
        let trailingWidth = trailingSlotWidth ?? 0
        let trailing = trailingContent ?? AnyView(EmptyView())

        Row(alignment: .center, spacing: 0) {
            Box { EmptyView() }
                .frame(width: indentWidth, height: rowHeight)

            _TreeDisclosureSlotHost(hasChildren: hasChildren,
                                    isExpanded: isExpanded,
                                    width: disclosureWidth,
                                    rowHeight: rowHeight,
                                    disclosureContent: disclosureContent,
                                    onToggle: onToggle)

            // Row body — delegates visuals to the TreeRowStyle env.
            _TreeRowHost(
                dragID: dragID,
                depth: depth,
                indentation: indentation,
                disclosureWidth: disclosureWidth,
                hasChildren: hasChildren,
                isExpanded: isExpanded,
                isSearchHit: isSearchHit,
                isSelected: isSelected,
                isHovered: isHovered,
                dropPosition: dropPosition,
                rowHeight: rowHeight,
                onSelect: onSelect,
                onMoveSelection: onMoveSelection,
                onCollapseOrParent: onCollapseOrParent,
                onExpandOrChild: onExpandOrChild,
                onKeyEvent: onKeyEvent,
                onDragStart: onDragStart,
                onDragMove: onDragMove,
                onDragEnd: onDragEnd,
                onDragCancel: onDragCancel,
                dragRegistry: dragRegistry,
                isDragEnabled: isDragEnabled,
                isDragSource: isDragSource,
                onHoverChange: onHoverChange,
                content: content
            )
            .flex()

            _TreeTrailingSlotHost(width: trailingWidth,
                                  rowHeight: rowHeight,
                                  content: trailing)
        }
        .frame(height: rowHeight)
    }
}

private struct _TreeDisclosureSlotHost: View {
    let hasChildren: Bool
    let isExpanded: Bool
    let width: Float
    let rowHeight: Float
    let disclosureContent: Tree<[Int], Int, EmptyView>.DisclosureContent?
    let onToggle: () -> Void

    var body: some View {
        Box(direction: .row, alignItems: .center, justifyContent: .center) {
            if hasChildren {
                Button(action: onToggle) {
                    if let disclosureContent {
                        disclosureContent(isExpanded)
                            .frame(width: width, height: rowHeight)
                    } else {
                        Text(isExpanded ? "▾" : "▸")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.onSurfaceVariant)
                            .frame(width: width, height: rowHeight)
                    }
                }
                .buttonStyle(.plain)
                .frame(width: width, height: rowHeight)
            }
        }
        .frame(width: width, height: rowHeight)
    }
}

private struct _TreeGuideRowSnapshot {
    let depth: Int
    let ancestorHasNextSiblings: [Bool]
    let hasNextSibling: Bool
    let hasChildren: Bool
    let isExpanded: Bool
}

private struct _TreeGuideOverlayHost<Content: View>: _PrimitiveView {
    let rows: [_TreeGuideRowSnapshot]
    let rowHeight: Float
    let rowSpacing: Float
    let indentation: Float
    let showsIndentGuides: Bool
    let content: Content

    init(rows: [_TreeGuideRowSnapshot],
         rowHeight: Float,
         rowSpacing: Float,
         indentation: Float,
         showsIndentGuides: Bool,
         @ViewBuilder content: () -> Content) {
        self.rows = rows
        self.rowHeight = rowHeight
        self.rowSpacing = rowSpacing
        self.indentation = indentation
        self.showsIndentGuides = showsIndentGuides
        self.content = content()
    }

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _updateNode(_ node: Node) {
        node.attachments["__tree_guide"] = true
        let rows = rows
        let rowHeight = rowHeight
        let rowSpacing = rowSpacing
        let indentation = indentation
        let showsIndentGuides = showsIndentGuides

        node.draw = { [weak node] list, origin in
            guard let node,
                  showsIndentGuides,
                  rowHeight > 0,
                  indentation > 0,
                  !rows.isEmpty else {
                return
            }

            let baseX = Float(origin.x)
            let baseY = Float(origin.y)
            let rowStride = rowHeight + rowSpacing
            let centerLead: Float = {
                let whole = max(2, indentation.rounded(.down))
                return ((whole - 1) * 0.5).rounded(.down)
            }()
            let centerYLead: Float = {
                let whole = max(2, rowHeight.rounded(.down))
                return max(0, ((whole - 1) * 0.5).rounded(.down))
            }()
            let continuationExtension = max(0, rowSpacing.rounded(.up))
            let guideInk = (node.foregroundColor ?? node.theme.colors.onSurfaceVariant)
                .multipliedAlpha(node.opacity)
            let branchColor = guideInk.multipliedAlpha(0.82)
            let ancestorColor = guideInk.multipliedAlpha(0.7)

            for (index, row) in rows.enumerated() {
                guard row.depth > 0 else { continue }

                let rowOriginY = baseY + Float(index) * rowStride
                let rowTop = rowOriginY.rounded(.down)
                let rowBottom = max(rowTop + 1, (rowOriginY + rowHeight).rounded(.up))
                let strokeY = (rowOriginY + centerYLead).rounded(.down)

                for level in 0..<row.depth {
                    let cellX = baseX + Float(level) * indentation
                    let strokeX = (cellX + centerLead).rounded(.down)
                    // Draw horizontal branches to the next guide-column center
                    // so joins remain continuous under rounding.
                    let nextColumnStrokeX = (cellX + indentation + centerLead).rounded(.down)

                    if level == row.depth - 1 {
                        let continuesDownward = row.hasNextSibling || (row.hasChildren && row.isExpanded)
                        let verticalBottom = continuesDownward
                            ? rowBottom + continuationExtension
                            : strokeY + 1
                        list.addRect(UIRect(x: strokeX,
                                            y: rowTop,
                                            width: 1,
                                            height: max(1, verticalBottom - rowTop)),
                                  color: branchColor)
                        // Add one pixel of overlap so horizontal/vertical joins
                        // stay visually continuous after integer rounding.
                        list.addRect(UIRect(x: strokeX,
                                            y: strokeY,
                                            width: max(1, nextColumnStrokeX - strokeX + 1),
                                            height: 1),
                                     color: branchColor)
                        continue
                    }

                    let shouldDrawVertical = level < row.ancestorHasNextSiblings.count
                        && row.ancestorHasNextSiblings[level]
                    if shouldDrawVertical {
                        let verticalBottom = rowBottom + continuationExtension
                        list.addRect(UIRect(x: strokeX,
                                            y: rowTop,
                                            width: 1,
                                            height: max(1, verticalBottom - rowTop)),
                                     color: ancestorColor)
                    }
                }
            }
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexDirection = .column
        layout.alignItems = .stretch
        return layout
    }

    var _children: [any View] {
        [content]
    }
}

private struct _TreeTrailingSlotHost: View {
    let width: Float
    let rowHeight: Float
    let content: AnyView

    var body: some View {
        Box(direction: .row, alignItems: .center, justifyContent: .flexEnd) {
            if width > 0 {
                content
            }
        }
        .padding(horizontal: 4, vertical: 0)
        .frame(width: width, height: rowHeight)
        .clipped()
    }
}

private struct _TreeRowHost: _PrimitiveView {
    let dragID: AnyHashable
    let depth: Int
    let indentation: Float
    let disclosureWidth: Float
    let hasChildren: Bool
    let isExpanded: Bool
    let isSearchHit: Bool
    let isSelected: Bool
    let isHovered: Bool
    let dropPosition: TreeDropPosition?
    let rowHeight: Float
    let onSelect: (KeyModifiers) -> Void
    let onMoveSelection: (Int) -> Void
    let onCollapseOrParent: () -> Void
    let onExpandOrChild: () -> Void
    let onKeyEvent: (KeyEvent) -> Bool
    let onDragStart: () -> Void
    let onDragMove: (Float, Float) -> Void
    let onDragEnd: () -> Void
    let onDragCancel: () -> Void
    let dragRegistry: _TreeRowDragRegistry<AnyHashable>
    let isDragEnabled: Bool
    let isDragSource: Bool
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
        let dropPosition = dropPosition
        let depth = depth
        let indentation = indentation
        let disclosureWidth = disclosureWidth
        node.cursor = .pointer
        node.attachments[Self.hoveredKey] = isHovered
        // Dim source row during drag for visual lift feedback.
        node.opacity = isDragSource ? 0.38 : 1.0
        // Extend hit zone leftward to cover the indent gutter + disclosure slot
        // so drops over indented areas still resolve a valid target row.
        let extraLeft = CGFloat(depth) * CGFloat(indentation) + CGFloat(disclosureWidth)
        dragRegistry.register(node: node, id: dragID, extraLeft: extraLeft)
        // Only reassign overlayDraw when the effective overlay state changes.
        // Node reuse can keep the same dropPosition while depth/indent changes,
        // so geometry must be part of the cache key.
        let nextOverlayState = _TreeRowOverlayState(dropPosition: dropPosition,
                                                    depth: depth,
                                                    indentation: indentation,
                                                    disclosureWidth: disclosureWidth)
        let prevOverlayState = node.attachments[Self.dropPositionKey] as? _TreeRowOverlayState
        if prevOverlayState != nextOverlayState {
            node.attachments[Self.dropPositionKey] = nextOverlayState
            node.overlayDraw = { [weak node] list, origin in
                guard let node, let dropPosition else { return }
                // Expand frame to the full row width (indent + disclosure + body)
                // so before/after lines and inside borders span the whole row.
                let gutter = Float(depth) * indentation + disclosureWidth
                let frame = UIRect(x: Float(origin.x) - gutter,
                                   y: Float(origin.y),
                                   width: Float(node.frame.width) + gutter,
                                   height: Float(node.frame.height))
                drawTreeDropIndicator(position: dropPosition,
                                      frame: frame,
                                      accent: node.theme.colors.accent,
                                      list: list)
            }
        }
        registry.setHover(node) { phase in
            switch phase {
            case .enter:
                hoverChange(true)
            case .leave:
                hoverChange(false)
            }
        }
        registry.setPointer(node) { event, phase, _ in
            switch phase {
            case .down:
                FocusChainHolder.current?.focus(node)
                node.attachments[Self.pressedKey] = true
                if isDragEnabled {
                    node.attachments[Self.dragStateKey] = _TreeRowPressState(downX: event.x,
                                                                            downY: event.y,
                                                                            didDrag: false)
                    PointerCaptureHolder.current?.acquire(node)
                }
                return .handled
            case .up:
                let was = (node.attachments[Self.pressedKey] as? Bool) ?? false
                node.attachments[Self.pressedKey] = false
                let pressState = node.attachments[Self.dragStateKey] as? _TreeRowPressState
                node.attachments[Self.dragStateKey] = nil
                if isDragEnabled {
                    PointerCaptureHolder.current?.release()
                }
                if pressState?.didDrag == true {
                    onDragEnd()
                    return .handled
                }
                if was { captured(event.modifiers); return .handled }
                return .ignored
            }
        }
        registry.setMotion(node) { event, _ in
            guard isDragEnabled,
                  PointerCaptureHolder.current?.target === node else {
                return .ignored
            }
            var state = (node.attachments[Self.dragStateKey] as? _TreeRowPressState)
                ?? _TreeRowPressState(downX: event.x, downY: event.y, didDrag: false)
            let dx = event.x - state.downX
            let dy = event.y - state.downY
            if !state.didDrag, max(abs(dx), abs(dy)) >= 4 {
                state.didDrag = true
                node.attachments[Self.pressedKey] = false
                onDragStart()
            }
            if state.didDrag {
                onDragMove(event.x, event.y)
            }
            node.attachments[Self.dragStateKey] = state
            return .handled
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
                captured(event.modifiers)
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
    static let dragStateKey = "__tree_row_drag_state"
    static let dropPositionKey = "__tree_row_drop_position"
}

private struct _TreeRowPressState {
    let downX: Float
    let downY: Float
    var didDrag: Bool
}

private struct _TreeRowOverlayState: Equatable {
    let dropPosition: TreeDropPosition?
    let depth: Int
    let indentation: Float
    let disclosureWidth: Float
}

// MARK: - Drag ghost overlay

/// Outer container that sits above the ScrollView and draws a floating ghost
/// badge following the cursor while a drag session is active. Since it is an
/// ancestor of (not inside) the ScrollView, its overlayDraw is not clipped by
/// the scroll region — the ghost can render freely over any part of the tree.
private struct _TreeGhostContainer<Content: View>: _PrimitiveView {
    /// Non-nil only while a drag is active. Drives both visibility and position.
    let dragCursorPos: CGPoint?
    let rowHeight: Float
    let content: Content

    init(dragCursorPos: CGPoint?,
         rowHeight: Float,
         @ViewBuilder content: () -> Content) {
        self.dragCursorPos = dragCursorPos
        self.rowHeight = rowHeight
        self.content = content()
    }

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = false
        return n
    }

    func _updateNode(_ node: Node) {
        let cursorPos = dragCursorPos
        let rowH = rowHeight
        node.overlayDraw = { [weak node] list, _ in
            guard let node, let pos = cursorPos else { return }
            let cx = Float(pos.x)
            let cy = Float(pos.y)
            let w = min(220, max(120, Float(node.frame.width) * 0.55))
            let h = rowH
            let x = cx + 14
            let y = cy + 2
            let bg = node.theme.colors.surfaceFloating.multipliedAlpha(0.94)
            let border = node.theme.colors.accent.multipliedAlpha(0.45)
            list.addRoundedRect(UIRect(x: x, y: y, width: w, height: h), radius: 4, color: bg)
            addTreeDropBorder(rect: UIRect(x: x, y: y, width: w, height: h),
                              color: border, list: list)
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let l = LayoutNode()
        l.flexDirection = .column
        l.alignItems = .stretch
        l.flex = 1
        return l
    }

    var _children: [any View] { [content] }
}

private func drawTreeDropIndicator(position: TreeDropPosition,
                                   frame: UIRect,
                                   accent: Color,
                                   list: DrawList) {
    switch position {
    case .inside:
        list.addRoundedRect(UIRect(x: frame.x + 1,
                                   y: frame.y + 1,
                                   width: max(2, frame.width - 2),
                                   height: max(2, frame.height - 2)),
                            radius: 4,
                            color: accent.multipliedAlpha(0.12))
        addTreeDropBorder(rect: frame.insetBy(dx: 1, dy: 1),
                          color: accent.multipliedAlpha(0.9),
                          list: list)
    case .before:
        let y = frame.y + 1
        list.addRect(UIRect(x: frame.x, y: y, width: frame.width, height: 2),
                     color: accent.multipliedAlpha(0.95))
        list.addRect(UIRect(x: frame.x, y: y - 1, width: 6, height: 4),
                     color: accent.multipliedAlpha(1))
    case .after:
        let y = frame.maxY - 3
        list.addRect(UIRect(x: frame.x, y: y, width: frame.width, height: 2),
                     color: accent.multipliedAlpha(0.95))
        list.addRect(UIRect(x: frame.x, y: y - 1, width: 6, height: 4),
                     color: accent.multipliedAlpha(1))
    }
}

private func addTreeDropBorder(rect: UIRect,
                               color: Color,
                               list: DrawList) {
    let t: Float = 1
    list.addRect(UIRect(x: rect.minX, y: rect.minY, width: rect.width, height: t), color: color)
    list.addRect(UIRect(x: rect.minX, y: rect.maxY - t, width: rect.width, height: t), color: color)
    list.addRect(UIRect(x: rect.minX, y: rect.minY, width: t, height: rect.height), color: color)
    list.addRect(UIRect(x: rect.maxX - t, y: rect.minY, width: t, height: rect.height), color: color)
}

private func treeAbsoluteFrame(of node: Node) -> CGRect {
    var origin = node.frame.origin
    var parent = node.parent
    while let current = parent {
        origin.x += current.frame.origin.x - current.contentOffset.x
        origin.y += current.frame.origin.y - current.contentOffset.y
        parent = current.parent
    }
    return CGRect(origin: origin, size: node.frame.size)
}

private extension CGRect {
    func contains(x: CGFloat, y: CGFloat) -> Bool {
        x >= minX && x <= maxX && y >= minY && y <= maxY
    }
}

private extension UIRect {
    func insetBy(dx: Float, dy: Float) -> UIRect {
        UIRect(x: x + dx,
               y: y + dy,
               width: max(0, width - dx * 2),
               height: max(0, height - dy * 2))
    }
}
