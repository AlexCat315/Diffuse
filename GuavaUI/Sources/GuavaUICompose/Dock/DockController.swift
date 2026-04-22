import Foundation

/// A drop target description used by drag operations and `DockController.move`.
///
/// `tabSlot` inserts the moved tab into an existing tabs leaf at the given
/// index; `splitEdge` splits the target leaf along the requested edge,
/// placing the moved tab in the new sibling leaf; `replace` merges into the
/// target tabs leaf when one exists, and only truly replaces an `.empty`
/// placeholder on `.center` drops.
public enum DockDropTarget: Sendable, Equatable {
    case tabSlot(parent: DockNodeID, index: Int)
    case splitEdge(target: DockNodeID, edge: DockEdge)
    case replace(target: DockNodeID)
}

/// All mutating intents on a `DockController`. Operations are deterministic
/// and serialisable so they can be replayed for undo / persistence.
public enum DockOperation: Sendable {
    /// Insert a brand-new tab into an existing tabs leaf at `index`. Out-of-
    /// range indices are clamped.
    case insertTab(DockTab, into: DockNodeID, at: Int)
    /// Move an existing tab to a new drop target. Source leaf is collapsed
    /// if it becomes empty as a result.
    case move(tabID: DockTabID, to: DockDropTarget)
    /// Remove a tab. Source leaf is collapsed if it becomes empty.
    case closeTab(DockTabID)
    /// Set the active tab of a tabs leaf. No-op if the tab is not in the leaf.
    case setActive(node: DockNodeID, tab: DockTabID)
    /// Resize a split node. Fraction is clamped to `[0.05, 0.95]`.
    case resizeSplit(node: DockNodeID, fraction: Float)

    /// Detach a tabs leaf from the main tree and store it as a satellite
    /// keyed by the leaf's existing `DockNodeID`. Source split collapses
    /// the same way as `move`. No-op if `leafID` is not a `.tabs` leaf,
    /// is the root, or is already a satellite.
    case detach(leafID: DockNodeID)

    /// Re-insert a previously detached satellite back into the main tree at
    /// `target`. The satellite leaf retains its tabs and `DockNodeID`. When
    /// `target` references a `.tabs` leaf the satellite's tabs are appended
    /// individually starting at the target index. Otherwise the satellite
    /// leaf is grafted whole at the requested edge / replace slot.
    case redock(satelliteID: DockNodeID, to: DockDropTarget)

    /// Drop a satellite from the registry without re-inserting it (e.g. the
    /// user closed the floating window).
    case closeSatellite(DockNodeID)

    /// Move an entire `.tabs` leaf within the main tree to a new drop
    /// target. Source position collapses the same way as `.move` /
    /// `.detach`. No-op if `leafID` is the root, is not a tabs leaf,
    /// is already a satellite, or `target` references the same leaf or
    /// any of its descendants. When `target` is a `.tabSlot` the leaf's
    /// tabs are appended individually starting at the target index.
    case moveLeaf(leafID: DockNodeID, to: DockDropTarget)

    /// Close every tab in `leaf` other than `keep`. Only acts when `leaf`
    /// is a `.tabs` leaf in the main tree (satellites included) and
    /// `keep` is one of its tabs. Closed tabs are pushed onto the
    /// `closedHistory` stack in left-to-right order so a chain of
    /// `.reopenLastClosed` invocations restores them in reverse.
    case closeOthers(in: DockNodeID, keep: DockTabID)

    /// Close every tab to the right of `pivot` in `leaf`. Same constraints
    /// as `.closeOthers`. Pivot tab itself is not closed.
    case closeToTheRight(in: DockNodeID, of: DockTabID)

    /// Pop the most-recently-closed tab off `closedHistory` and re-insert
    /// it. Tries the original leaf at the original index first; if that
    /// leaf no longer exists or no longer accepts tabs, appends to the
    /// first `.tabs` leaf encountered in a depth-first walk of the main
    /// tree. No-op if history is empty or no eligible leaf is found.
    case reopenLastClosed

    /// Set the `isPinned` flag on a tab. Pinned tabs are excluded from
    /// `.closeOthers`. Tab strip rendering (Phase O) reserves a separate
    /// pinned row for them. No-op when `tabID` is not present.
    case setPinned(tabID: DockTabID, isPinned: Bool)
}

/// Owner of a `DockLayoutNode` tree. Reference type; callers (the demo, the
/// editor, …) hold one instance and feed it `DockOperation`s.
///
/// Mutations bump `version` and fire `onChange`. The companion
/// `DockContainer` view subscribes to `onChange` to drive recompose, which
/// keeps the controller free of any view-graph dependency.
public final class DockController: @unchecked Sendable {

    public private(set) var root: DockLayoutNode
    public private(set) var version: UInt64 = 0

    /// Optional host-supplied canonicalisation pass applied to the main
    /// tree after every mutation. Hosts use this to keep a higher-level
    /// workspace shell stable (for example fixed left/center/right/bottom
    /// regions) while still reusing Dock's tab/split operations inside it.
    public var layoutNormalizer: ((DockLayoutNode) -> DockLayoutNode)?

    /// Detached leaves keyed by their original `DockNodeID`. Each entry is
    /// a `.tabs` subtree that has been removed from `root` by `.detach` and
    /// is awaiting either `.redock` or `.closeSatellite`.
    public private(set) var satellites: [DockNodeID: DockLayoutNode] = [:]

    /// Stable ordering for the satellites dictionary. Insertion order is
    /// preserved across encode / decode so callers iterating for UI
    /// (e.g. spawning floating windows) get a deterministic sequence.
    public private(set) var satelliteOrder: [DockNodeID] = []

    /// Token returned by `subscribe` and consumed by `unsubscribe`. Opaque.
    public struct SubscriptionToken: Hashable, Sendable {
        let raw: UInt64
    }

    private var subscribers: [SubscriptionToken: (DockController) -> Void] = [:]
    private var nextSubscriberID: UInt64 = 0

    /// Convenience setter that replaces every subscriber with a single handler.
    /// Equivalent to `unsubscribe`-ing all current handlers and then `subscribe`-ing
    /// the supplied closure (or no-op when `nil`).
    public var onChange: ((DockController) -> Void)? {
        get { nil }
        set {
            subscribers.removeAll()
            if let handler = newValue {
                _ = subscribe(handler)
            }
        }
    }

    /// Right-click on a tab forwards here with the tab id and the global
    /// (window-local) pointer position the click happened at. Hosts wire
    /// this up to whatever menu/popover system they own; the dock layer
    /// has no opinion on how the menu is rendered. `nil` (default) makes
    /// right-click a no-op.
    public var onTabContextMenu: ((_ tabID: DockTabID, _ leafID: DockNodeID, _ x: Float, _ y: Float) -> Void)?

    /// One entry in the recent-closed-tab history, used by `.reopenLastClosed`
    /// and the default tab context menu's "Reopen Closed Tab" item.
    public struct ClosedTabRecord: Sendable {
        /// The tab as it was at close time (id, userKey, title, capability bits).
        public let tab: DockTab
        /// Leaf the tab lived in. Used as the preferred reopen target. May
        /// no longer exist by the time `.reopenLastClosed` runs.
        public let sourceLeafID: DockNodeID
        /// Index inside `sourceLeafID` at close time. Reopen attempts to
        /// honour this; clamped if the leaf is shorter now.
        public let originalIndex: Int
    }

    /// Stack of recently-closed tabs. Newest entry is at the end. Cap is
    /// `closedHistoryLimit` (FIFO eviction). Operations that close one or
    /// more tabs (`.closeTab`, `.closeOthers`, `.closeToTheRight`) push
    /// in left-to-right order so reopen restores in reverse.
    public private(set) var closedHistory: [ClosedTabRecord] = []

    /// Maximum number of entries kept in `closedHistory`. Older entries
    /// are dropped from the head when a new close pushes over the cap.
    public var closedHistoryLimit: Int = 50

    public init(root: DockLayoutNode) {
        self.root = root
        let session = DockDragSession()
        self.dragSession = session
        session.attach(controller: self)
    }

    /// Per-leaf node registry. Populated by `_DockTabsLeaf` /
    /// `_DockEmptyLeaf` as they materialise; used by drag hit-testing.
    /// In multi-window setups the cluster-wide `DockHostCoordinator`
    /// registers its own per-host registries; this field stays for
    /// single-window callers and tests.
    public let hitRegistry = DockHitRegistry()

    /// Active drag interaction. Single instance per controller; reused
    /// across drags by calling `start` / `end`.
    public let dragSession: DockDragSession

    /// Register a change handler. Returns a token that can later be passed to
    /// `unsubscribe(_:)` to detach. Multiple subscribers coexist; each one
    /// receives every mutation in registration order.
    @discardableResult
    public func subscribe(_ handler: @escaping (DockController) -> Void) -> SubscriptionToken {
        nextSubscriberID &+= 1
        let token = SubscriptionToken(raw: nextSubscriberID)
        subscribers[token] = handler
        return token
    }

    public func unsubscribe(_ token: SubscriptionToken) {
        subscribers.removeValue(forKey: token)
    }

    // MARK: - Public mutation

    public func apply(_ op: DockOperation) {
        let next: DockLayoutNode
        switch op {
        case .insertTab(let tab, let parent, let index):
            next = Self.insertTab(tab, into: parent, at: index, in: root)
        case .move(let tabID, let target):
            next = Self.move(tabID: tabID, to: target, in: root)
        case .closeTab(let tabID):
            // Snapshot the leaf + index BEFORE removal so reopen can try
            // the original location.
            if let loc = Self.locateTab(tabID, in: root) {
                pushClosedHistory(ClosedTabRecord(
                    tab: loc.tab,
                    sourceLeafID: loc.leafID,
                    originalIndex: loc.index
                ))
            }
            next = Self.closeTab(tabID, in: root)
        case .setActive(let node, let tab):
            next = Self.setActive(node: node, tab: tab, in: root)
        case .resizeSplit(let node, let fraction):
            next = Self.resizeSplit(node: node, fraction: fraction, in: root)
        case .detach(let leafID):
            applyDetach(leafID: leafID)
            return
        case .redock(let satelliteID, let target):
            applyRedock(satelliteID: satelliteID, to: target)
            return
        case .closeSatellite(let satelliteID):
            applyCloseSatellite(satelliteID: satelliteID)
            return
        case .moveLeaf(let leafID, let target):
            applyMoveLeaf(leafID: leafID, to: target)
            return
        case .closeOthers(let leafID, let keep):
            applyCloseOthers(in: leafID, keep: keep)
            return
        case .closeToTheRight(let leafID, let pivot):
            applyCloseToTheRight(in: leafID, of: pivot)
            return
        case .reopenLastClosed:
            applyReopenLastClosed()
            return
        case .setPinned(let tabID, let isPinned):
            next = Self.setPinned(tabID: tabID, isPinned: isPinned, in: root)
        }
        let normalized = normalizeRoot(next)
        guard normalized != root else { return }
        root = normalized
        version &+= 1
        notifyChange()
    }

    // MARK: - Satellite operations

    private func applyDetach(leafID: DockNodeID) {
        // Already detached — no-op.
        guard satellites[leafID] == nil else { return }
        // Resolve the leaf inside `root` and ensure it's a tabs leaf with
        // at least one tab. Detaching empty placeholders or split nodes is
        // refused (semantics unclear; would create a tab-less floating
        // window).
        guard let found = Self.findNode(leafID, in: root),
              case .tabs(_, let tabs, _) = found, !tabs.isEmpty else {
            return
        }
        guard let removed = Self.removeNode(leafID, from: root) else {
            return
        }
        let stripped = removed.0
        guard let stripped else {
            // `removeNode` refuses to leave an empty root — treat the leaf
            // as the only content; cannot detach the only leaf.
            return
        }
        root = normalizeRoot(stripped)
        satellites[leafID] = found
        satelliteOrder.append(leafID)
        version &+= 1
        notifyChange()
    }

    private func applyRedock(satelliteID: DockNodeID, to target: DockDropTarget) {
        guard let satellite = satellites[satelliteID] else { return }
        guard case .tabs(_, let tabs, let active) = satellite, !tabs.isEmpty else {
            // Drop a malformed satellite silently; closeSatellite is the
            // sanctioned cleanup path.
            return
        }
        var nextRoot = root
        switch target {
        case .tabSlot(let parent, let index):
            // Append tabs into the target leaf in order, preserving
            // satellite order and pinning the formerly-active tab as
            // active in the merged leaf.
            for (offset, tab) in tabs.enumerated() {
                nextRoot = Self.insertAtDropTarget(
                    tab,
                    target: .tabSlot(parent: parent, index: index + offset),
                    in: nextRoot
                )
            }
            if let active {
                nextRoot = Self.setActive(node: parent, tab: active, in: nextRoot)
            }
        case .replace, .splitEdge:
            // Graft the satellite subtree wholesale.
            nextRoot = Self.insertSubtreeAtDropTarget(satellite, target: target, in: nextRoot)
        }
        // Drop the satellite from the registry first so subscribers see a
        // consistent state when they react to the version bump.
        satellites.removeValue(forKey: satelliteID)
        satelliteOrder.removeAll { $0 == satelliteID }
        let normalized = normalizeRoot(nextRoot)
        if normalized != root { root = normalized }
        version &+= 1
        notifyChange()
    }

    private func applyCloseSatellite(satelliteID: DockNodeID) {
        guard satellites.removeValue(forKey: satelliteID) != nil else { return }
        satelliteOrder.removeAll { $0 == satelliteID }
        version &+= 1
        notifyChange()
    }

    /// Move an entire `.tabs` leaf already inside the main tree to a new
    /// drop target. Rejects no-ops (target is the same leaf), cycles
    /// (target is inside the leaf being moved), root moves, satellites
    /// (use `.redock` instead), and non-`.tabs` source nodes. Bumps
    /// `version` only when the tree actually changes.
    private func applyMoveLeaf(leafID: DockNodeID, to target: DockDropTarget) {
        guard satellites[leafID] == nil else { return }
        guard let found = Self.findNode(leafID, in: root) else { return }
        guard case .tabs(_, let tabs, let active) = found, !tabs.isEmpty else { return }
        guard root.id != leafID else { return }

        let targetID: DockNodeID
        switch target {
        case .tabSlot(let parent, _): targetID = parent
        case .replace(let t):         targetID = t
        case .splitEdge(let t, _):    targetID = t
        }
        if targetID == leafID { return }
        // Cycle: target inside the moved subtree (also catches "drop on
        // own children" though leaves don't have layout children).
        if Self.findNode(targetID, in: found) != nil { return }

        guard let removed = Self.removeNode(leafID, from: root),
              let stripped = removed.0 else {
            return
        }
        var nextRoot = stripped
        switch target {
        case .tabSlot(let parent, let index):
            for (offset, tab) in tabs.enumerated() {
                nextRoot = Self.insertAtDropTarget(
                    tab,
                    target: .tabSlot(parent: parent, index: index + offset),
                    in: nextRoot
                )
            }
            if let active {
                nextRoot = Self.setActive(node: parent, tab: active, in: nextRoot)
            }
        case .replace, .splitEdge:
            nextRoot = Self.insertSubtreeAtDropTarget(found, target: target, in: nextRoot)
        }
        let normalized = normalizeRoot(nextRoot)
        guard normalized != root else { return }
        root = normalized
        version &+= 1
        notifyChange()
    }

    // MARK: - Close-others / close-right / reopen

    private func applyCloseOthers(in leafID: DockNodeID, keep: DockTabID) {
        let resolvedLeaf = Self.findNode(leafID, in: root) ?? satellites[leafID]
        guard let leaf = resolvedLeaf,
              case .tabs(_, let tabs, _) = leaf,
              tabs.contains(where: { $0.id == keep }) else {
            return
        }
        // Capture the to-close set with their indices BEFORE we mutate
        // anything so reopen can preserve original positions. Pinned tabs
        // (Phase O) survive `.closeOthers` regardless of `keep` — they
        // are excluded from the victim set.
        let victims = tabs.enumerated()
            .filter { $0.element.id != keep && !$0.element.isPinned }
            .map { ($0.element, $0.offset) }
        guard !victims.isEmpty else { return }
        for (tab, idx) in victims {
            pushClosedHistory(ClosedTabRecord(tab: tab,
                                              sourceLeafID: leafID,
                                              originalIndex: idx))
        }
        if satellites[leafID] != nil {
            applyCloseTabsInSatellite(leafID: leafID,
                                       drop: Set(victims.map(\.0.id)))
        } else {
            var nextRoot = root
            for (tab, _) in victims {
                nextRoot = Self.closeTab(tab.id, in: nextRoot)
            }
            let normalized = normalizeRoot(nextRoot)
            guard normalized != root else { return }
            root = normalized
            version &+= 1
            notifyChange()
        }
    }

    private func applyCloseToTheRight(in leafID: DockNodeID, of pivot: DockTabID) {
        let resolvedLeaf = Self.findNode(leafID, in: root) ?? satellites[leafID]
        guard let leaf = resolvedLeaf,
              case .tabs(_, let tabs, _) = leaf,
              let pivotIndex = tabs.firstIndex(where: { $0.id == pivot }) else {
            return
        }
        let victims = tabs.enumerated()
            .dropFirst(pivotIndex + 1)
            .map { ($0.element, $0.offset) }
        guard !victims.isEmpty else { return }
        for (tab, idx) in victims {
            pushClosedHistory(ClosedTabRecord(tab: tab,
                                              sourceLeafID: leafID,
                                              originalIndex: idx))
        }
        if satellites[leafID] != nil {
            applyCloseTabsInSatellite(leafID: leafID,
                                       drop: Set(victims.map(\.0.id)))
        } else {
            var nextRoot = root
            for (tab, _) in victims {
                nextRoot = Self.closeTab(tab.id, in: nextRoot)
            }
            let normalized = normalizeRoot(nextRoot)
            guard normalized != root else { return }
            root = normalized
            version &+= 1
            notifyChange()
        }
    }

    /// Drop a set of tab IDs from a satellite leaf in place. The satellite
    /// stays alive even if it becomes empty (consistent with `.closeTab`
    /// on a satellite leaf today, which is also a no-op since `closeTab`
    /// only walks the main tree). Hosts that want the floating window
    /// closed when the last tab leaves should observe the satellite
    /// state and dispatch `.closeSatellite` themselves.
    private func applyCloseTabsInSatellite(leafID: DockNodeID,
                                            drop: Set<DockTabID>) {
        guard case .tabs(let id, let tabs, let active) = satellites[leafID] else { return }
        let remaining = tabs.filter { !drop.contains($0.id) }
        if remaining.count == tabs.count { return }
        let nextActive: DockTabID? = {
            if let active, remaining.contains(where: { $0.id == active }) { return active }
            return remaining.first?.id
        }()
        satellites[leafID] = .tabs(id: id, tabs: remaining, activeTabID: nextActive)
        version &+= 1
        notifyChange()
    }

    private func applyReopenLastClosed() {
        guard let record = closedHistory.popLast() else { return }
        // Preferred target: original leaf at original index. Try main tree
        // first, then satellites.
        if Self.findNode(record.sourceLeafID, in: root) != nil {
            apply(.insertTab(record.tab,
                              into: record.sourceLeafID,
                              at: record.originalIndex))
            return
        }
        if let satLeaf = satellites[record.sourceLeafID],
           case .tabs(let id, var tabs, let active) = satLeaf {
            let i = max(0, min(tabs.count, record.originalIndex))
            tabs.insert(record.tab, at: i)
            satellites[record.sourceLeafID] = .tabs(id: id,
                                                     tabs: tabs,
                                                     activeTabID: active ?? record.tab.id)
            version &+= 1
            notifyChange()
            return
        }
        // Fallback: append to the first `.tabs` leaf in the main tree.
        if let fallbackID = Self.firstTabsLeafID(in: root) {
            apply(.insertTab(record.tab, into: fallbackID, at: Int.max))
            return
        }
        // Last resort: replace the empty root with a fresh tabs leaf.
        if case .empty(let id) = root {
            root = normalizeRoot(.tabs(id: id, tabs: [record.tab], activeTabID: record.tab.id))
            version &+= 1
            notifyChange()
        }
    }

    private func pushClosedHistory(_ record: ClosedTabRecord) {
        closedHistory.append(record)
        if closedHistory.count > closedHistoryLimit {
            closedHistory.removeFirst(closedHistory.count - closedHistoryLimit)
        }
    }

    /// Locate `tabID` in the main tree, returning the leaf id, the tab,
    /// and its index within that leaf.
    private static func locateTab(_ tabID: DockTabID,
                                  in tree: DockLayoutNode)
    -> (leafID: DockNodeID, tab: DockTab, index: Int)? {
        switch tree {
        case .empty:
            return nil
        case .tabs(let id, let tabs, _):
            if let idx = tabs.firstIndex(where: { $0.id == tabID }) {
                return (id, tabs[idx], idx)
            }
            return nil
        case .split(_, _, _, let first, let second):
            return locateTab(tabID, in: first) ?? locateTab(tabID, in: second)
        }
    }

    /// First `.tabs` leaf encountered in a depth-first walk of `tree`.
    private static func firstTabsLeafID(in tree: DockLayoutNode) -> DockNodeID? {
        switch tree {
        case .empty: return nil
        case .tabs(let id, _, _): return id
        case .split(_, _, _, let first, let second):
            return firstTabsLeafID(in: first) ?? firstTabsLeafID(in: second)
        }
    }
    /// Optionally restores a satellite map captured by an earlier snapshot.
    public func replace(root newRoot: DockLayoutNode,
                        satellites newSatellites: [DockNodeID: DockLayoutNode] = [:],
                        satelliteOrder newOrder: [DockNodeID] = []) {
        let orderedSatellites = newOrder.isEmpty ? Array(newSatellites.keys) : newOrder
        guard newRoot != root
            || newSatellites != satellites
            || orderedSatellites != satelliteOrder else { return }
        root = normalizeRoot(newRoot)
        satellites = newSatellites
        satelliteOrder = orderedSatellites.filter { newSatellites[$0] != nil }
        version &+= 1
        notifyChange()
    }

    private func normalizeRoot(_ candidate: DockLayoutNode) -> DockLayoutNode {
        layoutNormalizer?(candidate) ?? candidate
    }

    private func notifyChange() {
        // Snapshot to allow handlers to subscribe / unsubscribe during dispatch.
        let snapshot = subscribers
        for (_, handler) in snapshot {
            handler(self)
        }
    }

    // MARK: - Operation implementations

    private static func insertTab(_ tab: DockTab,
                                  into parent: DockNodeID,
                                  at index: Int,
                                  in tree: DockLayoutNode) -> DockLayoutNode {
        return transform(tree) { node in
            guard node.id == parent else { return nil }
            switch node {
            case .tabs(let id, var tabs, let active):
                let i = max(0, min(tabs.count, index))
                tabs.insert(tab, at: i)
                return .tabs(id: id, tabs: tabs, activeTabID: active ?? tab.id)
            case .empty(let id):
                return .tabs(id: id, tabs: [tab], activeTabID: tab.id)
            case .split:
                return nil
            }
        }
    }

    private static func move(tabID: DockTabID,
                             to target: DockDropTarget,
                             in tree: DockLayoutNode) -> DockLayoutNode {
        // 1. Locate and detach the tab from its source leaf.
        guard let (detached, removed) = removeTab(tabID, from: tree) else {
            return tree
        }
        let collapsed = collapseEmpty(detached)
        // 2. Reinsert at the drop target.
        return insertAtDropTarget(removed, target: target, in: collapsed)
    }

    private static func closeTab(_ tabID: DockTabID,
                                 in tree: DockLayoutNode) -> DockLayoutNode {
        guard let (detached, _) = removeTab(tabID, from: tree) else {
            return tree
        }
        return collapseEmpty(detached)
    }

    private static func setActive(node: DockNodeID,
                                  tab: DockTabID,
                                  in tree: DockLayoutNode) -> DockLayoutNode {
        return transform(tree) { n in
            guard n.id == node else { return nil }
            guard case .tabs(let id, let tabs, _) = n else { return nil }
            guard tabs.contains(where: { $0.id == tab }) else { return nil }
            return .tabs(id: id, tabs: tabs, activeTabID: tab)
        }
    }

    private static func resizeSplit(node: DockNodeID,
                                    fraction: Float,
                                    in tree: DockLayoutNode) -> DockLayoutNode {
        return transform(tree) { n in
            guard n.id == node else { return nil }
            guard case .split(let id, let axis, _, let f, let s) = n else { return nil }
            return .split(id: id, axis: axis, fraction: clampFraction(fraction), first: f, second: s)
        }
    }

    /// Toggle the `isPinned` flag of `tabID` wherever the tab lives.
    /// Returns the original tree when the tab is missing or already in
    /// the requested state. Tab order is preserved.
    private static func setPinned(tabID: DockTabID,
                                  isPinned: Bool,
                                  in tree: DockLayoutNode) -> DockLayoutNode {
        return transform(tree) { n in
            guard case .tabs(let id, var tabs, let active) = n,
                  let idx = tabs.firstIndex(where: { $0.id == tabID }),
                  tabs[idx].isPinned != isPinned else {
                return nil
            }
            tabs[idx].isPinned = isPinned
            return .tabs(id: id, tabs: tabs, activeTabID: active)
        }
    }

    // MARK: - Tab removal / drop

    /// Walk the tree, drop the tab if found, and return the new tree plus the
    /// detached `DockTab`. Returns `nil` when the tab is not present.
    private static func removeTab(_ tabID: DockTabID,
                                  from tree: DockLayoutNode)
    -> (DockLayoutNode, DockTab)? {
        switch tree {
        case .empty:
            return nil
        case .tabs(let id, var tabs, let active):
            guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else {
                return nil
            }
            let removed = tabs.remove(at: idx)
            let nextActive: DockTabID?
            if tabs.isEmpty {
                nextActive = nil
            } else if active == tabID {
                let neighbour = tabs[max(0, min(tabs.count - 1, idx))]
                nextActive = neighbour.id
            } else {
                nextActive = active
            }
            return (.tabs(id: id, tabs: tabs, activeTabID: nextActive), removed)
        case .split(let id, let axis, let frac, let first, let second):
            if let (newFirst, removed) = removeTab(tabID, from: first) {
                return (.split(id: id, axis: axis, fraction: frac, first: newFirst, second: second), removed)
            }
            if let (newSecond, removed) = removeTab(tabID, from: second) {
                return (.split(id: id, axis: axis, fraction: frac, first: first, second: newSecond), removed)
            }
            return nil
        }
    }

    /// Collapse `.tabs` leaves with zero tabs into `.empty`, then collapse
    /// any `.split` whose child became `.empty` into the surviving sibling.
    /// Preserves the IDs of surviving nodes.
    private static func collapseEmpty(_ tree: DockLayoutNode) -> DockLayoutNode {
        switch tree {
        case .empty:
            return tree
        case .tabs(let id, let tabs, _):
            if tabs.isEmpty { return .empty(id: id) }
            return tree
        case .split(let id, let axis, let frac, let first, let second):
            let f = collapseEmpty(first)
            let s = collapseEmpty(second)
            // Both empty: collapse the split itself to a single empty leaf,
            // reusing this split's ID so external references stay valid until
            // the caller decides to clean up.
            if case .empty = f, case .empty = s {
                return .empty(id: id)
            }
            // One side empty: collapse to the other side.
            if case .empty = f { return s }
            if case .empty = s { return f }
            return .split(id: id, axis: axis, fraction: frac, first: f, second: s)
        }
    }

    private static func insertAtDropTarget(_ tab: DockTab,
                                           target: DockDropTarget,
                                           in tree: DockLayoutNode) -> DockLayoutNode {
        switch target {
        case .tabSlot(let parent, let index):
            return transform(tree) { n in
                guard n.id == parent else { return nil }
                switch n {
                case .tabs(let id, var tabs, _):
                    let i = max(0, min(tabs.count, index))
                    tabs.insert(tab, at: i)
                    return .tabs(id: id, tabs: tabs, activeTabID: tab.id)
                case .empty(let id):
                    return .tabs(id: id, tabs: [tab], activeTabID: tab.id)
                case .split:
                    return nil
                }
            }
        case .replace(let targetID):
            return transform(tree) { n in
                guard n.id == targetID else { return nil }
                switch n {
                case .tabs(let id, var tabs, _):
                    tabs.append(tab)
                    return .tabs(id: id, tabs: tabs, activeTabID: tab.id)
                case .empty(let id):
                    return .tabs(id: id, tabs: [tab], activeTabID: tab.id)
                case .split:
                    return nil
                }
            }
        case .splitEdge(let targetID, let edge):
            if edge == .center {
                return insertAtDropTarget(tab, target: .replace(target: targetID), in: tree)
            }
            let resolvedTargetID = promotedSplitTargetID(targetID: targetID,
                                                         edge: edge,
                                                         in: tree)
            return transform(tree) { n in
                guard n.id == resolvedTargetID else { return nil }
                let newLeaf = DockLayoutNode.tabs([tab])
                let axis: DockSplitAxis
                let leafFirst: Bool
                switch edge {
                case .left:   axis = .horizontal; leafFirst = true
                case .right:  axis = .horizontal; leafFirst = false
                case .top:    axis = .vertical;   leafFirst = true
                case .bottom: axis = .vertical;   leafFirst = false
                case .center: fatalError("handled above")
                }
                return .split(
                    id: DockNodeID(),
                    axis: axis,
                    fraction: 0.5,
                    first: leafFirst ? newLeaf : n,
                    second: leafFirst ? n : newLeaf
                )
            }
        }
    }

    /// Locate a node by ID anywhere in the tree.
    static func findNode(_ id: DockNodeID, in tree: DockLayoutNode) -> DockLayoutNode? {
        if tree.id == id { return tree }
        if case .split(_, _, _, let first, let second) = tree {
            return findNode(id, in: first) ?? findNode(id, in: second)
        }
        return nil
    }

    /// Remove the node with `id` from the tree and return the resulting tree
    /// alongside the removed subtree. The parent split is collapsed onto the
    /// surviving sibling (so removing a leaf out of an `.hsplit` returns the
    /// other leaf as the new root). Returns `(nil, removed)` if the removed
    /// node WAS the root, since collapsing the root would leave nothing
    /// meaningful for callers; they typically refuse the operation.
    static func removeNode(_ id: DockNodeID,
                           from tree: DockLayoutNode)
    -> (DockLayoutNode?, DockLayoutNode)? {
        if tree.id == id {
            return (nil, tree)
        }
        switch tree {
        case .empty, .tabs:
            return nil
        case .split(let nodeID, let axis, let frac, let first, let second):
            if first.id == id {
                return (second, first)
            }
            if second.id == id {
                return (first, second)
            }
            if let (newFirst, removed) = removeNode(id, from: first) {
                guard let newFirst else {
                    // Should not happen \u2014 shallow `first.id == id` matches
                    // earlier, deeper matches always rebuild a non-nil tree.
                    return (second, removed)
                }
                return (.split(id: nodeID, axis: axis, fraction: frac, first: newFirst, second: second), removed)
            }
            if let (newSecond, removed) = removeNode(id, from: second) {
                guard let newSecond else {
                    return (first, removed)
                }
                return (.split(id: nodeID, axis: axis, fraction: frac, first: first, second: newSecond), removed)
            }
            return nil
        }
    }

    /// Graft an entire subtree at a `.splitEdge` or `.replace` drop target.
    /// `.tabSlot` is not handled here \u2014 callers must explode the satellite
    /// into individual `insertAtDropTarget` calls so each tab is inserted at
    /// the right index.
    private static func insertSubtreeAtDropTarget(_ subtree: DockLayoutNode,
                                                  target: DockDropTarget,
                                                  in tree: DockLayoutNode) -> DockLayoutNode {
        switch target {
        case .tabSlot:
            // Defensive fallback: splice the first tab if the satellite
            // happens to be a tabs leaf. Higher-level callers should never
            // hit this path.
            if case .tabs(_, let tabs, _) = subtree, let first = tabs.first {
                return insertAtDropTarget(first, target: target, in: tree)
            }
            return tree
        case .replace(let targetID):
            return transform(tree) { n in
                guard n.id == targetID else { return nil }
                switch n {
                case .tabs(let id, var tabs, _):
                    guard case .tabs(_, let incomingTabs, let incomingActive) = subtree else {
                        return subtree
                    }
                    tabs.append(contentsOf: incomingTabs)
                    return .tabs(id: id,
                                 tabs: tabs,
                                 activeTabID: incomingActive ?? incomingTabs.last?.id)
                case .empty:
                    return subtree
                case .split:
                    return nil
                }
            }
        case .splitEdge(let targetID, let edge):
            if edge == .center {
                return insertSubtreeAtDropTarget(subtree, target: .replace(target: targetID), in: tree)
            }
            let resolvedTargetID = promotedSplitTargetID(targetID: targetID,
                                                         edge: edge,
                                                         in: tree)
            return transform(tree) { n in
                guard n.id == resolvedTargetID else { return nil }
                let axis: DockSplitAxis
                let leafFirst: Bool
                switch edge {
                case .left:   axis = .horizontal; leafFirst = true
                case .right:  axis = .horizontal; leafFirst = false
                case .top:    axis = .vertical;   leafFirst = true
                case .bottom: axis = .vertical;   leafFirst = false
                case .center: fatalError("handled above")
                }
                return .split(
                    id: DockNodeID(),
                    axis: axis,
                    fraction: 0.5,
                    first: leafFirst ? subtree : n,
                    second: leafFirst ? n : subtree
                )
            }
        }
    }

    private static func promotedSplitTargetID(targetID: DockNodeID,
                                              edge: DockEdge,
                                              in tree: DockLayoutNode) -> DockNodeID {
        guard let parent = findImmediateParent(of: targetID, in: tree) else {
            return targetID
        }
        let edgeAxis: DockSplitAxis
        switch edge {
        case .left, .right:
            edgeAxis = .horizontal
        case .top, .bottom:
            edgeAxis = .vertical
        case .center:
            return targetID
        }
        guard case .split(let id, let axis, _, _, _) = parent,
              axis != edgeAxis else {
            return targetID
        }
        return id
    }

    private static func findImmediateParent(of id: DockNodeID,
                                            in tree: DockLayoutNode) -> DockLayoutNode? {
        guard case .split = tree else { return nil }
        if case .split(_, _, _, let first, let second) = tree {
            if first.id == id || second.id == id {
                return tree
            }
            return findImmediateParent(of: id, in: first)
                ?? findImmediateParent(of: id, in: second)
        }
        return nil
    }

    /// Generic tree transformer: walk the tree, apply `mutate` to every node,
    /// and rebuild any ancestor whose subtree changed. `mutate` returns `nil`
    /// to leave a node alone.
    private static func transform(_ tree: DockLayoutNode,
                                  mutate: (DockLayoutNode) -> DockLayoutNode?)
    -> DockLayoutNode {
        if let replaced = mutate(tree) {
            return replaced
        }
        switch tree {
        case .empty, .tabs:
            return tree
        case .split(let id, let axis, let frac, let first, let second):
            let f = transform(first, mutate: mutate)
            let s = transform(second, mutate: mutate)
            if f == first && s == second { return tree }
            return .split(id: id, axis: axis, fraction: frac, first: f, second: s)
        }
    }
}
