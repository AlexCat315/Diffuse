import EngineKernel
#if canImport(CoreGraphics)
import CoreGraphics
#endif
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
    public var options = TreeOptions<Element, ID>()
    public let rowContent: (Element, Bool, Bool, Int) -> RowContent
    @State private var session = TreeSession<ID>()

    public init(_ roots: Roots,
                id: KeyPath<Element, ID>,
                children: @escaping (Element) -> [Element],
                configure: (inout TreeOptions<Element, ID>) -> Void = { _ in },
                @ViewBuilder rowContent: @escaping (Element, Bool, Bool, Int) -> RowContent) {
        self.roots = Array(roots)
        self.id = id
        self.children = children
        self.rowContent = rowContent
        configure(&options)
        options.layout.validate()
    }

    public var body: some View {
        let treeState = derivedState()
        let entries = visibleEntries(using: treeState)
        let entriesByToken = Dictionary(uniqueKeysWithValues: entries.map { ($0.nodeKey, $0) })
        let activeDrag = session.dragState
        _TreeKeyboardHost(onKey: { event in
            session.activeModifiers = event.modifiers
            if options.events.onKeyCommand?(event, treeState.selectedIDs) == true { return true }
            let current = entries.first { $0.nodeKey == options.selection.primaryKey.wrappedValue }
                ?? entries.first { $0.id == options.selection.primary.wrappedValue }
                ?? entries.first { treeState.selectedIDs.contains($0.id) }
                ?? entries.first
            guard let current else { return false }
            switch event.scancode {
            case Scancode.arrowDown: moveSelection(from: current.nodeKey, delta: 1, entries: entries)
            case Scancode.arrowUp: moveSelection(from: current.nodeKey, delta: -1, entries: entries)
            case Scancode.arrowLeft: collapseOrSelectParent(current, entries: entries)
            case Scancode.arrowRight: expandOrSelectFirstChild(current, entries: entries)
            default: return false
            }
            return true
        }) {
        _TreeGhostContainer(dragCursorPos: activeDrag != nil ? session.dragCursorPos : nil,
                            rowHeight: options.layout.rowHeight) {
        VirtualStack(entries, id: \.nodeKey, rowHeight: options.layout.rowHeight, spacing: options.layout.rowSpacing,
                     scrollToIndex: entries.firstIndex { $0.nodeKey == options.selection.primaryKey.wrappedValue || $0.id == options.selection.primary.wrappedValue }) { entry in
            _TreeGuideOverlayHost(rows: [_TreeGuideRowSnapshot(depth: entry.depth,
                                  ancestorHasNextSiblings: entry.ancestorHasNextSiblings,
                                  hasNextSibling: entry.hasNextSibling, hasChildren: entry.hasChildren,
                                  isExpanded: entry.isExpanded)],
                                  rowHeight: options.layout.rowHeight, rowSpacing: 0, indentation: options.layout.indentation,
                                  showsIndentGuides: options.layout.showsIndentGuides) {
                        let token = entry.nodeKey
                        let isSel = treeState.usesNodeKeySelection
                            ? treeState.selectedNodeKeys.contains(token)
                            : treeState.selectedIDs.contains(entry.id)
                        _TreeRowComposite(
                            appearance: TreeRowAppearance(hasChildren: entry.hasChildren,
                                isExpanded: entry.isExpanded,
                                isSearchHit: entry.isSearchHit,
                                isSelected: isSel,
                                isHovered: session.hoveredToken == token,
                                propagateHoverState: options.slots.trailing != nil,
                                dropPosition: session.dragState?.targetID == token ? session.dragState?.position : nil),
                            geometry: TreeRowGeometry(depth: entry.depth,
                                rowHeight: options.layout.rowHeight,
                                indentation: options.layout.indentation,
                                disclosureWidth: options.layout.disclosureWidth),
                            slots: TreeRowSlots(disclosureContent: options.slots.disclosure,
                                trailingSlotWidth: options.slots.trailing == nil ? nil : options.layout.trailingSlotWidth,
                                trailingContent: options.slots.trailing.map {
                                $0(entry.element,
                                   isSel,
                                   entry.isExpanded,
                                   entry.isSearchHit,
                                   session.hoveredToken == token,
                                   entry.depth)
                            }),
                            actions: TreeRowActions(onToggle: { toggle(entry.nodeKey, legacyID: entry.id) },
                                onSelect: { modifiers in
                                select(entry, modifiers: modifiers, entries: entries)
                            },
                                onMoveSelection: { delta in
                                moveSelection(from: entry.nodeKey, delta: delta, entries: entries)
                            },
                                onCollapseOrParent: {
                                collapseOrSelectParent(entry, entries: entries)
                            },
                                onExpandOrChild: {
                                expandOrSelectFirstChild(entry, entries: entries)
                            },
                                onKeyEvent: { event in
                                session.activeModifiers = event.modifiers
                                if options.events.onKeyCommand?(event, treeState.selectedIDs) == true {
                                    return true
                                }
                                return false
                            },
                                onHoverChange: { hovered in
                                if hovered {
                                    if session.hoveredToken != token {
                                        session.hoveredToken = token
                                    }
                                } else if session.hoveredToken == token {
                                    session.hoveredToken = nil
                                }
                            }),
                            drag: TreeRowDrag(dragID: AnyHashable(token),
                                dragRegistry: session.dragRegistry,
                                isDragEnabled: options.drag.onDrop != nil,
                                isDragSource: activeDrag?.sourceID == token,
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
                                onDragCancel: cancelDrag),
                            content: AnyView(rowContent(entry.element, isSel, entry.isExpanded, entry.depth))
                        )
                        .id(token)
            }
        }
        } // _TreeGhostContainer
        } // persistent keyboard target
    }

    private var expandedNodeKeys: Set<TreeNodeKey<ID>> {
        options.selection.expandedKeys?.wrappedValue ?? []
    }

    private var expandedIDs: Set<ID> {
        if options.selection.expandedKeys != nil {
            return Set(expandedNodeKeys.map(\.id))
        }
        return options.selection.expanded?.wrappedValue ?? session.localExpanded
    }

    private var selectedIDs: Set<ID> {
        if let multiSelectionKeys = options.selection.multipleKeys {
            return Set(multiSelectionKeys.wrappedValue.map(\.id))
        }
        if let multiSelection = options.selection.multiple {
            return multiSelection.wrappedValue
        }
        if let selected = options.selection.primaryKey.wrappedValue {
            return [selected.id]
        }
        guard let single = options.selection.primary.wrappedValue else { return [] }
        return [single]
    }

    private var selectedNodeKeys: Set<TreeNodeKey<ID>> {
        if let multiSelectionKeys = options.selection.multipleKeys {
            return multiSelectionKeys.wrappedValue
        }
        if let selected = options.selection.primaryKey.wrappedValue {
            return [selected]
        }
        return []
    }

    private var visibleEntries: [VisibleEntry] {
        visibleEntries(using: derivedState())
    }

    private func derivedState() -> DerivedState {
        let expandedNodeKeys = options.selection.expandedKeys?.wrappedValue ?? []
        let expandedIDs: Set<ID>
        if options.selection.expandedKeys != nil {
            expandedIDs = Set(expandedNodeKeys.map(\.id))
        } else {
            expandedIDs = options.selection.expanded?.wrappedValue ?? session.localExpanded
        }

        let selectedNodeKeys: Set<TreeNodeKey<ID>>
        let selectedIDs: Set<ID>
        if let multiSelectionKeys = options.selection.multipleKeys {
            selectedNodeKeys = multiSelectionKeys.wrappedValue
            selectedIDs = Set(selectedNodeKeys.map(\.id))
        } else if let multiSelection = options.selection.multiple {
            selectedNodeKeys = []
            selectedIDs = multiSelection.wrappedValue
        } else if let selected = options.selection.primaryKey.wrappedValue {
            selectedNodeKeys = [selected]
            selectedIDs = [selected.id]
        } else if let single = options.selection.primary.wrappedValue {
            selectedNodeKeys = []
            selectedIDs = [single]
        } else {
            selectedNodeKeys = []
            selectedIDs = []
        }

        let query = normalizedSearchQuery
        let filterActive = !query.isEmpty
            && options.search.text != nil
            && options.search.policy == .filterAndAutoExpand
        return DerivedState(expandedIDs: expandedIDs,
                            expandedNodeKeys: expandedNodeKeys,
                            selectedIDs: selectedIDs,
                            selectedNodeKeys: selectedNodeKeys,
                            usesNodeKeySelection: options.selection.multipleKeys != nil || options.selection.primaryKey.wrappedValue != nil,
                            searchMetadata: buildSearchMetadata(query: query),
                            filterActive: filterActive,
                            autoExpand: filterActive)
    }

    private func visibleEntries(using state: DerivedState) -> [VisibleEntry] {
        var out: [VisibleEntry] = []
        appendVisible(nodes: roots,
                      depth: 0,
                      pathPrefix: [],
                      ancestorHasNextSiblings: [],
                      parentID: nil,
                      parentKey: nil,
                      state: state,
                      into: &out)
        return out
    }

    private func appendVisible(nodes: [Element],
                               depth: Int,
                               pathPrefix: [Int],
                               ancestorHasNextSiblings: [Bool],
                               parentID: ID?,
                               parentKey: TreeNodeKey<ID>?,
                               state: DerivedState,
                               into out: inout [VisibleEntry]) {
        let visibleNodes = nodes.enumerated().compactMap {
            indexedNode -> (originalIndex: Int, element: Element)? in
            let node = indexedNode.element
            guard !state.filterActive
                    || state.searchMetadata?.subtreeMatches[node[keyPath: id]] == true else {
                return nil
            }
            return (originalIndex: indexedNode.offset, element: node)
        }

        for (visibleIndex, indexedNode) in visibleNodes.enumerated() {
            let node = indexedNode.element
            let nodeID = node[keyPath: id]
            // Paths are identity tokens for selection, expansion and drag
            // state. Filtering must not renumber them: callers build keys from
            // the unfiltered scene and expect those keys to remain valid while
            // search merely hides non-matching siblings.
            let path = pathPrefix + [indexedNode.originalIndex]
            let nodeKey = TreeNodeKey(id: nodeID, path: path)
            let childNodes = children(node)

            let selfMatches = state.searchMetadata?.selfMatches[nodeID] ?? false
            let childSubtreeMatches: Bool
            if state.autoExpand {
                childSubtreeMatches = childNodes.contains {
                    let childID = $0[keyPath: id]
                    return state.searchMetadata?.subtreeMatches[childID] ?? false
                }
            } else {
                childSubtreeMatches = false
            }
            let isExpanded = state.expandedIDs.contains(nodeID)
                || state.expandedNodeKeys.contains(nodeKey)
                || (state.autoExpand && childSubtreeMatches)
            let hasNextSibling = visibleIndex < visibleNodes.count - 1
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
                              state: state,
                              into: &out)
            }
        }
    }

    private func select(_ entry: VisibleEntry,
                        modifiers: KeyModifiers) {
        select(entry, modifiers: modifiers, entries: visibleEntries)
    }

    private func select(_ entry: VisibleEntry,
                        modifiers: KeyModifiers,
                        entries: [VisibleEntry]) {
        let targetID = entry.id
        let targetKey = entry.nodeKey

        if let multiSelectionKeys = options.selection.multipleKeys {
            var next = multiSelectionKeys.wrappedValue
            var nextPrimary: TreeNodeKey<ID>? = targetKey
            if modifiers.hasShift,
               let anchor = session.rangeAnchorKey ?? options.selection.primaryKey.wrappedValue {
                let keys = keysBetween(anchor, targetKey, entries: entries)
                next = keys.isEmpty ? [targetKey] : keys
                nextPrimary = targetKey
            } else if modifiers.hasGui || modifiers.hasCtrl {
                if next.contains(targetKey) {
                    next.remove(targetKey)
                } else {
                    next.insert(targetKey)
                }
                if next.isEmpty {
                    session.rangeAnchorKey = nil
                    nextPrimary = nil
                } else {
                    session.rangeAnchorKey = targetKey
                    nextPrimary = next.contains(targetKey) ? targetKey : firstVisibleKey(in: next, entries: entries)
                }
            } else {
                next = [targetKey]
                session.rangeAnchorKey = targetKey
                nextPrimary = targetKey
            }
            multiSelectionKeys.wrappedValue = next
            options.selection.primaryKey.wrappedValue = nextPrimary
            options.selection.primary.wrappedValue = nextPrimary?.id
            if let multiSelection = options.selection.multiple {
                multiSelection.wrappedValue = Set(next.map(\.id))
            }
            options.events.onSelect?(entry.element)
            return
        }

        if let multiSelection = options.selection.multiple {
            var next = multiSelection.wrappedValue
            var nextPrimary: ID? = targetID
            if modifiers.hasShift,
               let anchor = session.rangeAnchorID ?? options.selection.primary.wrappedValue {
                let ids = idsBetween(anchor, targetID, entries: entries)
                if !ids.isEmpty {
                    next = ids
                } else {
                    next = [targetID]
                }
                nextPrimary = targetID
            } else if modifiers.hasGui || modifiers.hasCtrl {
                if next.contains(targetID) {
                    next.remove(targetID)
                } else {
                    next.insert(targetID)
                }
                if next.isEmpty {
                    session.rangeAnchorID = nil
                    nextPrimary = nil
                } else {
                    session.rangeAnchorID = targetID
                    if next.contains(targetID) {
                        nextPrimary = targetID
                    } else {
                        nextPrimary = firstVisibleID(in: next, entries: entries)
                    }
                }
            } else {
                next = [targetID]
                session.rangeAnchorID = targetID
                nextPrimary = targetID
            }
            multiSelection.wrappedValue = next
            options.selection.primary.wrappedValue = nextPrimary
            options.selection.primaryKey.wrappedValue = nextPrimary.flatMap { primary in
                entries.first(where: { $0.id == primary })?.nodeKey
            }
        } else {
            options.selection.primary.wrappedValue = targetID
            options.selection.primaryKey.wrappedValue = targetKey
            session.rangeAnchorID = targetID
        }
        options.events.onSelect?(entry.element)
    }

    private func keysBetween(_ a: TreeNodeKey<ID>, _ b: TreeNodeKey<ID>) -> Set<TreeNodeKey<ID>> {
        keysBetween(a, b, entries: visibleEntries)
    }

    private func keysBetween(_ a: TreeNodeKey<ID>,
                             _ b: TreeNodeKey<ID>,
                             entries: [VisibleEntry]) -> Set<TreeNodeKey<ID>> {
        guard let ia = entries.firstIndex(where: { $0.nodeKey == a }),
              let ib = entries.firstIndex(where: { $0.nodeKey == b }) else {
            return []
        }
        let lower = min(ia, ib)
        let upper = max(ia, ib)
        return Set(entries[lower...upper].map(\.nodeKey))
    }

    private func firstVisibleKey(in candidates: Set<TreeNodeKey<ID>>) -> TreeNodeKey<ID>? {
        firstVisibleKey(in: candidates, entries: visibleEntries)
    }

    private func firstVisibleKey(in candidates: Set<TreeNodeKey<ID>>,
                                 entries: [VisibleEntry]) -> TreeNodeKey<ID>? {
        for entry in entries where candidates.contains(entry.nodeKey) {
            return entry.nodeKey
        }
        return candidates.sorted { $0.path.lexicographicallyPrecedes($1.path) }.first
    }

    private func firstVisibleID(in candidates: Set<ID>) -> ID? {
        firstVisibleID(in: candidates, entries: visibleEntries)
    }

    private func firstVisibleID(in candidates: Set<ID>,
                                entries: [VisibleEntry]) -> ID? {
        for entry in entries where candidates.contains(entry.id) {
            return entry.id
        }
        return candidates.sorted { String(describing: $0) < String(describing: $1) }.first
    }

    private func idsBetween(_ a: ID, _ b: ID) -> Set<ID> {
        idsBetween(a, b, entries: visibleEntries)
    }

    private func idsBetween(_ a: ID,
                            _ b: ID,
                            entries: [VisibleEntry]) -> Set<ID> {
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
        if let expanded = options.selection.expanded { expanded.wrappedValue = next } else { session.localExpanded = next }
    }

    private func toggle(_ nodeKey: TreeNodeKey<ID>, legacyID: ID) {
        if let expandedKeys = options.selection.expandedKeys {
            var next = expandedKeys.wrappedValue
            if next.contains(nodeKey) {
                next.remove(nodeKey)
            } else {
                next.insert(nodeKey)
            }
            expandedKeys.wrappedValue = next
            if let expanded = options.selection.expanded {
                expanded.wrappedValue = Set(next.map(\.id))
            }
            return
        }

        var next = expandedIDs
        if next.contains(legacyID) {
            next.remove(legacyID)
        } else {
            next.insert(legacyID)
        }
        if let expanded = options.selection.expanded {
            expanded.wrappedValue = next
        } else {
            session.localExpanded = next
        }
    }

    private var normalizedSearchQuery: String {
        options.search.query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var isFilterActive: Bool {
        !normalizedSearchQuery.isEmpty
            && options.search.text != nil
            && options.search.policy == .filterAndAutoExpand
    }

    private var isAutoExpandActive: Bool {
        isFilterActive
    }

    private struct SearchMetadata {
        var selfMatches: [ID: Bool]
        var subtreeMatches: [ID: Bool]
    }

    private struct DerivedState {
        let expandedIDs: Set<ID>
        let expandedNodeKeys: Set<TreeNodeKey<ID>>
        let selectedIDs: Set<ID>
        let selectedNodeKeys: Set<TreeNodeKey<ID>>
        let usesNodeKeySelection: Bool
        let searchMetadata: SearchMetadata?
        let filterActive: Bool
        let autoExpand: Bool
    }

    private func buildSearchMetadata() -> SearchMetadata? {
        buildSearchMetadata(query: normalizedSearchQuery)
    }

    private func buildSearchMetadata(query: String) -> SearchMetadata? {
        guard !query.isEmpty, let searchText = options.search.text else {
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
        moveSelection(from: currentKey, delta: delta, entries: visibleEntries)
    }

    private func moveSelection(from currentKey: TreeNodeKey<ID>,
                               delta: Int,
                               entries: [VisibleEntry]) {
        guard let index = entries.firstIndex(where: { $0.nodeKey == currentKey }) else { return }
        let target = max(0, min(entries.count - 1, index + delta))
        guard target != index else { return }
        select(entries[target], modifiers: session.activeModifiers, entries: entries)
    }

    private func collapseOrSelectParent(_ entry: VisibleEntry) {
        collapseOrSelectParent(entry, entries: visibleEntries)
    }

    private func collapseOrSelectParent(_ entry: VisibleEntry, entries: [VisibleEntry]) {
        if entry.hasChildren && entry.isExpanded {
            toggle(entry.nodeKey, legacyID: entry.id)
            return
        }
        guard let parent = entry.parentKey.flatMap({ key in
            entries.first(where: { $0.nodeKey == key })
        }) ?? entry.parentID.flatMap({ id in
            entries.first(where: { $0.id == id })
        }) else {
            return
        }
        select(parent, modifiers: session.activeModifiers, entries: entries)
    }

    private func expandOrSelectFirstChild(_ entry: VisibleEntry) {
        expandOrSelectFirstChild(entry, entries: visibleEntries)
    }

    private func expandOrSelectFirstChild(_ entry: VisibleEntry, entries: [VisibleEntry]) {
        guard entry.hasChildren else { return }
        if !entry.isExpanded {
            toggle(entry.nodeKey, legacyID: entry.id)
            return
        }
        guard let firstChild = entries.first(where: { $0.parentKey == entry.nodeKey }) else {
            return
        }
        select(firstChild, modifiers: session.activeModifiers, entries: entries)
    }

    private func beginDrag(from sourceToken: TreeNodeKey<ID>) {
        guard options.drag.onDrop != nil else { return }
        session.dragState = _TreeDragState(sourceID: sourceToken,
                                   targetID: nil,
                                   position: nil)
    }

    private func updateDrag(from sourceToken: TreeNodeKey<ID>,
                            pointerX: Float,
                            pointerY: Float,
                            entriesByToken: [TreeNodeKey<ID>: VisibleEntry]) {
        guard options.drag.onDrop != nil else { return }
        session.dragCursorPos = CGPoint(x: CGFloat(pointerX), y: CGFloat(pointerY))
        guard let hit = session.dragRegistry.hit(atX: pointerX, y: pointerY),
              let targetToken = hit.id.base as? TreeNodeKey<ID>,
              let sourceEntry = entriesByToken[sourceToken],
              let targetEntry = entriesByToken[targetToken],
              sourceToken != targetToken else {
            session.dragState = _TreeDragState(sourceID: sourceToken, targetID: nil, position: nil)
            return
        }
        let position = dropPosition(for: pointerY, frame: hit.frame)
        if options.drag.canDrop?(sourceEntry.element, targetEntry.element, position) == false {
            session.dragState = _TreeDragState(sourceID: sourceToken, targetID: nil, position: nil)
            return
        }
        session.dragState = _TreeDragState(sourceID: sourceToken,
                                   targetID: targetToken,
                                   position: position)
    }

    private func commitDrag(entriesByToken: [TreeNodeKey<ID>: VisibleEntry]) {
        defer { session.dragState = nil }
        guard let state = session.dragState,
              let targetToken = state.targetID,
              let position = state.position,
              let sourceEntry = entriesByToken[state.sourceID],
              let targetEntry = entriesByToken[targetToken] else {
            return
        }
        options.drag.onDrop?(sourceEntry.element, targetEntry.element, position)
    }

    private func cancelDrag() {
        session.dragState = nil
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
    init(_ roots: Roots, id: KeyPath<Element, ID>, children: KeyPath<Element, [Element]>,
         configure: (inout TreeOptions<Element, ID>) -> Void = { _ in },
         @ViewBuilder rowContent: @escaping (Element, Bool, Bool, Int) -> RowContent) {
        self.init(roots, id: id, children: { $0[keyPath: children] }, configure: configure, rowContent: rowContent)
    }
}

public extension Tree where Element: Identifiable, ID == Element.ID {
    init(_ roots: Roots, children: KeyPath<Element, [Element]>,
         configure: (inout TreeOptions<Element, ID>) -> Void = { _ in },
         @ViewBuilder rowContent: @escaping (Element, Bool, Bool, Int) -> RowContent) {
        self.init(roots, id: \Element.id, children: children, configure: configure, rowContent: rowContent)
    }
}

private struct TreeSession<ID: Hashable> {
    var localExpanded: Set<ID> = []
    var hoveredToken: TreeNodeKey<ID>?
    var activeModifiers: KeyModifiers = []
    var rangeAnchorID: ID?
    var rangeAnchorKey: TreeNodeKey<ID>?
    var dragState: _TreeDragState<TreeNodeKey<ID>>?
    var dragCursorPos: CGPoint = .zero
    var dragRegistry = _TreeRowDragRegistry<AnyHashable>()
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
private struct TreeRowAppearance {
    let hasChildren: Bool
    let isExpanded: Bool
    let isSearchHit: Bool
    let isSelected: Bool
    let isHovered: Bool
    let propagateHoverState: Bool
    let dropPosition: TreeDropPosition?
}

private struct TreeRowGeometry {
    let depth: Int
    let rowHeight: Float
    let indentation: Float
    let disclosureWidth: Float
}

private struct TreeRowSlots {
    let disclosureContent: Tree<[Int], Int, EmptyView>.DisclosureContent?
    let trailingSlotWidth: Float?
    let trailingContent: AnyView?
}

private struct TreeRowActions {
    let onToggle: () -> Void
    let onSelect: (KeyModifiers) -> Void
    let onMoveSelection: (Int) -> Void
    let onCollapseOrParent: () -> Void
    let onExpandOrChild: () -> Void
    let onKeyEvent: (KeyEvent) -> Bool
    let onHoverChange: (Bool) -> Void
}

private struct TreeRowDrag {
    let dragID: AnyHashable
    let dragRegistry: _TreeRowDragRegistry<AnyHashable>
    let isDragEnabled: Bool
    let isDragSource: Bool
    let onDragStart: () -> Void
    let onDragMove: (Float, Float) -> Void
    let onDragEnd: () -> Void
    let onDragCancel: () -> Void
}

private struct _TreeRowComposite: View {
    let appearance: TreeRowAppearance
    let geometry: TreeRowGeometry
    let slots: TreeRowSlots
    let actions: TreeRowActions
    let drag: TreeRowDrag
    let content: AnyView

    var body: some View {
        let indentWidth = max(0, Float(geometry.depth) * geometry.indentation)
        let trailingWidth = slots.trailingSlotWidth ?? 0
        let trailing = slots.trailingContent ?? AnyView(EmptyView())

        Row(alignment: .center, spacing: 0) {
            Box { EmptyView() }
                .frame(width: indentWidth, height: geometry.rowHeight)

            _TreeDisclosureSlotHost(hasChildren: appearance.hasChildren,
                                    isExpanded: appearance.isExpanded,
                                    width: geometry.disclosureWidth,
                                    rowHeight: geometry.rowHeight,
                                    disclosureContent: slots.disclosureContent,
                                    onToggle: actions.onToggle)

            // Row body — delegates visuals to the TreeRowStyle env.
            _TreeRowHost(appearance: appearance, geometry: geometry, actions: actions, drag: drag, content: content)
            .flex()

            _TreeTrailingSlotHost(width: trailingWidth,
                                  rowHeight: geometry.rowHeight,
                                  content: trailing)
        }
        .frame(height: geometry.rowHeight)
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
                        Icon(isExpanded ? UICommonIcons.chevronDown : UICommonIcons.chevronRight, size: 10, color: .onSurfaceVariant)
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

private struct _TreeGuideRowSnapshot: Equatable {
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

    private struct PaintIdentity: Equatable {
        let rows: [_TreeGuideRowSnapshot]
        let rowHeight: Float
        let rowSpacing: Float
        let indentation: Float
        let showsIndentGuides: Bool
    }

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

        node.updateDraw(identity: PaintIdentity(rows: rows,
                                                rowHeight: rowHeight,
                                                rowSpacing: rowSpacing,
                                                indentation: indentation,
                                                showsIndentGuides: showsIndentGuides)) { [weak node] list, origin in
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
    let appearance: TreeRowAppearance
    let geometry: TreeRowGeometry
    let actions: TreeRowActions
    let drag: TreeRowDrag
    let content: AnyView

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.isFocusable = false
        return n
    }

    func _updateNode(_ node: Node) {
        node.accessibility = AccessibilitySemantics(.treeItem) {
            $0.state.isSelected = appearance.isSelected; $0.state.isExpanded = appearance.hasChildren ? appearance.isExpanded : nil
            $0.combinesChildren = true
        }
        node.accessibilityActions.activate = { actions.onSelect([]) }

        guard let registry = InteractionRegistryHolder.current else { return }
        let captured = actions.onSelect
        let hoverChange = actions.onHoverChange
        let style = node.compositionValue(of: TreeRowStyleEnvironment.key)
        let shouldPropagateHover = appearance.propagateHoverState || style.requiresHoverRecompose
        let usesNodeHoverChrome = !style.requiresHoverRecompose
        let dropPosition = appearance.dropPosition
        let depth = geometry.depth
        let indentation = geometry.indentation
        let disclosureWidth = geometry.disclosureWidth
        node.cursor = .pointer
        let effectiveHover: Bool
        if shouldPropagateHover {
            node.attachments[Self.hoveredKey] = appearance.isHovered
            effectiveHover = appearance.isHovered
        } else {
            if node.attachments[Self.hoveredKey] == nil {
                node.attachments[Self.hoveredKey] = false
            }
            effectiveHover = node.attachments[Self.hoveredKey] as? Bool ?? false
        }
        applyHoverChrome(to: node, isHovered: usesNodeHoverChrome && effectiveHover)
        // Dim source row during drag for visual lift feedback.
        node.animatableSet(\.opacity, to: drag.isDragSource ? 0.38 : 1.0)
        // Extend hit zone leftward to cover the indent gutter + disclosure slot
        // so drops over indented areas still resolve a valid target row.
        let extraLeft = CGFloat(depth) * CGFloat(indentation) + CGFloat(disclosureWidth)
        drag.dragRegistry.register(node: node, id: drag.dragID, extraLeft: extraLeft)
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
                node.attachments[Self.hoveredKey] = true
                applyHoverChrome(to: node, isHovered: usesNodeHoverChrome)
                if shouldPropagateHover {
                    hoverChange(true)
                }
            case .leave:
                node.attachments[Self.hoveredKey] = false
                applyHoverChrome(to: node, isHovered: false)
                if shouldPropagateHover {
                    hoverChange(false)
                }
            }
        }
        registry.setPointer(node) { event, phase, eventPhase in
            // Embedded controls get first refusal before selection or dragging.
            guard eventPhase != .capture else { return .ignored }
            guard event.button == .left else { return .ignored }
            switch phase {
            case .down:
                var keyboardTarget = node
                while let parent = keyboardTarget.parent {
                    keyboardTarget = parent
                    if parent.attachments["tree-keyboard-root"] != nil { break }
                }
                FocusChainHolder.current?.focus(keyboardTarget, visible: false)
                node.attachments[Self.pressedKey] = true
                if drag.isDragEnabled {
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
                if drag.isDragEnabled {
                    PointerCaptureHolder.current?.release()
                }
                if pressState?.didDrag == true {
                    drag.onDragEnd()
                    return .handled
                }
                if was { captured(event.modifiers); return .handled }
                return .ignored
            }
        }
        registry.setMotion(node) { event, _ in
            guard drag.isDragEnabled,
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
                drag.onDragStart()
            }
            if state.didDrag {
                drag.onDragMove(event.x, event.y)
            }
            node.attachments[Self.dragStateKey] = state
            return .handled
        }
        registry.setKey(node) { event, _ in
            if event.isRepeat { return .ignored }
            if actions.onKeyEvent(event) {
                return .handled
            }
            switch event.scancode {
            case Scancode.arrowUp:
                actions.onMoveSelection(-1)
                return .handled
            case Scancode.arrowDown:
                actions.onMoveSelection(1)
                return .handled
            case Scancode.arrowLeft:
                actions.onCollapseOrParent()
                return .handled
            case Scancode.arrowRight:
                actions.onExpandOrChild()
                return .handled
            case Scancode.return, Scancode.space, Scancode.keypadEnter:
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
        l.height = geometry.rowHeight
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
            depth: geometry.depth,
            indentation: geometry.indentation,
            disclosureWidth: geometry.disclosureWidth,
            hasChildren: appearance.hasChildren,
            isExpanded: appearance.isExpanded,
            isSearchHit: appearance.isSearchHit,
            isSelected: appearance.isSelected,
            isHovered: appearance.isHovered,
            isEnabled: true,
            theme: node.theme
        )
        return [style.makeBody(cfg)]
    }

    static let pressedKey = "__tree_row_pressed"
    static let hoveredKey = "__tree_row_hovered"
    static let dragStateKey = "__tree_row_drag_state"
    static let dropPositionKey = "__tree_row_drop_position"

    private func applyHoverChrome(to node: Node, isHovered: Bool) {
        node.cornerRadius = node.theme.radius.sm
        node.backgroundColor = isHovered && !appearance.isSelected && !appearance.isSearchHit
            ? node.theme.colors.stateLayerHover
            : nil
    }
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

    private struct PaintIdentity: Equatable {
        let cursorX: CGFloat?
        let cursorY: CGFloat?
        let rowHeight: Float
    }

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
        node.updateOverlayDraw(identity: PaintIdentity(cursorX: cursorPos?.x,
                                                       cursorY: cursorPos?.y,
                                                       rowHeight: rowH)) { [weak node] list, _ in
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
        l.flexGrow = 1
        l.flexShrink = 1
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
    node.absoluteFrame
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

private struct _TreeKeyboardHost<Content: View>: _PrimitiveView {
    let onKey: (KeyEvent) -> Bool; let content: Content
    init(onKey: @escaping (KeyEvent) -> Bool, @ViewBuilder content: () -> Content) { self.onKey = onKey; self.content = content() }
    func _makeNode() -> Node {
        let node = Node(); node.isHitTestable = false; node.isFocusable = true
        node.attachments["tree-keyboard-root"] = true; return node
    }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) { InteractionRegistryHolder.current?.setKey(node) { event, _ in onKey(event) ? .handled : .ignored } }
    var _children: [any View] { [content] }
}
