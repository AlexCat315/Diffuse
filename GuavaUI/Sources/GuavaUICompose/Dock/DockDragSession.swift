import EngineKernel
import Foundation
import GuavaUIRuntime

/// Active drag interaction for one `DockController`. One session per
/// controller — the controller owns it so the drag state is reachable from
/// any view subscribed to that controller (tab item, leaf overlay, ghost).
///
/// Lifecycle:
/// 1. Source tab calls `start(...)` after the pointer crosses the activation
///    threshold (avoids accidental drags on plain clicks).
/// 2. Subsequent motion updates `pointerX`/`pointerY` and resolves the
///    current `dropTarget` from the controller's `DockHitRegistry`. When a
///    `DockHostCoordinator` is attached, motion may also resolve a hit in
///    a different window via the cluster-wide registry.
/// 3. Source tab calls `end(commit:)` on pointer up — `commit: true`
///    dispatches `.move`, `.detach`, or `.redock` depending on where the
///    pointer was released; `commit: false` cancels.
public final class DockDragSession {

    public struct GhostInfo: Sendable {
        public let title: String
        public init(title: String) { self.title = title }
    }

    public struct LeafHit: Sendable, Equatable {
        public let leafID: DockNodeID
        public let edge: DockEdge
        /// Insertion index when the drop is into the tab strip itself
        /// (`edge == .center` over a tabs leaf may degrade into this when
        /// the pointer is over the strip area). `nil` means "use edge".
        public let tabSlotIndex: Int?

        public init(leafID: DockNodeID, edge: DockEdge, tabSlotIndex: Int?) {
            self.leafID = leafID
            self.edge = edge
            self.tabSlotIndex = tabSlotIndex
        }
    }

    public private(set) var isActive: Bool = false
    public private(set) var tabID: DockTabID?
    public private(set) var sourceLeafID: DockNodeID?
    public private(set) var ghost: GhostInfo?
    public private(set) var pointerX: Float = 0
    public private(set) var pointerY: Float = 0
    public private(set) var globalPointerX: Float = 0
    public private(set) var globalPointerY: Float = 0
    public private(set) var hoverLeafID: DockNodeID?
    public private(set) var dropHit: LeafHit?
    /// When the active `dropHit` belongs to a different window than the
    /// source leaf, this records the host that should perform the drop.
    /// `nil` means same-window drop or no drop at all.
    public private(set) var dropHostWindowID: WindowID?
    /// `true` when the pointer is currently outside every registered host
    /// in the cluster — a release here triggers `.detach` (when source
    /// was an in-tree leaf) or `.closeSatellite` follow-up.
    public private(set) var isOutsideAllHosts: Bool = false

    /// Global pointer position captured at `start(...)` — used by
    /// `end(commit:)` to gate the detach branch on a minimum drag
    /// distance (`Self.detachDistanceThreshold`). Prevents a stray
    /// click-and-release just outside the host from spawning a
    /// satellite window.
    public private(set) var originGlobalX: Float = 0
    public private(set) var originGlobalY: Float = 0

    /// Minimum global-space distance (in points) from the drag origin
    /// before a release outside all hosts is treated as a detach. A
    /// release closer than this is silently swallowed.
    public static let detachDistanceThreshold: Float = 80

    /// Bumped on every state change so views subscribing for redraws can
    /// observe progress without polling.
    public private(set) var version: UInt64 = 0

    private weak var controller: DockController?
    private var listeners: [UInt64: () -> Void] = [:]
    private var nextListenerID: UInt64 = 0

    /// Drag origin classification — informs which controller op to fire on
    /// release when a same-window drop / detach decision is required.
    public enum Origin: Sendable, Equatable {
        /// Tab dragged from a leaf inside the main dock tree.
        case mainTreeTab
        /// The entire satellite window is being moved (used for redock).
        case satellite(leafID: DockNodeID)
        /// An entire main-tree leaf (its tab strip handle) is being
        /// dragged. Same drop semantics as `.mainTreeTab` but the
        /// release op moves the whole leaf via `.moveLeaf` instead of
        /// `.move`.
        case mainTreeLeaf(leafID: DockNodeID)
    }
    public private(set) var origin: Origin = .mainTreeTab

    /// Phase G — gesture intent ladder. Lets overlays branch their
    /// visualisation between "user is just nudging within the strip"
    /// and "user is detaching / splitting".
    ///
    /// Levels are monotonic: once escalated to a higher rung the session
    /// never falls back. The drop op fired on release is the same for
    /// `.reorderInStrip` and `.detachOrSplit`; only the affordances
    /// (drop overlay, ghost) differ.
    public enum DragIntent: Sendable, Equatable, Comparable {
        /// Pointer is captured but motion has not crossed the reorder
        /// threshold yet. Treated as a still-pending click.
        case pendingClick
        /// Pointer crossed the reorder threshold. Same-leaf reorder
        /// affordance only — no edge indicators yet.
        case reorderInStrip
        /// Pointer crossed the lift threshold (or moved sufficiently
        /// vertically). Full 5-direction drop indicator, full ghost.
        case detachOrSplit

        private var rank: Int {
            switch self {
            case .pendingClick: return 0
            case .reorderInStrip: return 1
            case .detachOrSplit: return 2
            }
        }
        public static func < (lhs: DragIntent, rhs: DragIntent) -> Bool {
            lhs.rank < rhs.rank
        }
    }
    /// Current intent. `.pendingClick` whenever the session is inactive.
    public private(set) var intent: DragIntent = .pendingClick

    /// Escalate the intent if `next > intent`. No-op for downgrades.
    /// Bumps `version` only when the intent actually changes.
    public func escalateIntent(to next: DragIntent) {
        guard isActive, next > intent else { return }
        intent = next
        bumpVersion()
    }

    init() {}

    func attach(controller: DockController) {
        self.controller = controller
    }

    // MARK: - Lifecycle

    func start(tabID: DockTabID? = nil,
               sourceLeafID: DockNodeID,
               ghost: GhostInfo,
               x: Float, y: Float,
               globalX: Float = 0, globalY: Float = 0,
               origin: Origin = .mainTreeTab,
               intent: DragIntent = .detachOrSplit) {
        self.tabID = tabID
        self.sourceLeafID = sourceLeafID
        self.ghost = ghost
        self.pointerX = x
        self.pointerY = y
        self.globalPointerX = globalX
        self.globalPointerY = globalY
        self.originGlobalX = globalX
        self.originGlobalY = globalY
        self.hoverLeafID = nil
        self.dropHit = nil
        self.dropHostWindowID = nil
        self.isOutsideAllHosts = false
        self.origin = origin
        self.intent = intent
        self.isActive = true
        bumpVersion()
    }

    func updatePointer(x: Float, y: Float, registry: DockHitRegistry) {
        guard isActive else { return }
        self.pointerX = x
        self.pointerY = y
        self.hoverLeafID = registry.leafAt(x: x, y: y)?.id
        self.dropHit = Self.resolveAllowedDropHit(x: x,
                                                  y: y,
                                                  tabID: tabID,
                                                  sourceLeafID: sourceLeafID,
                                                  origin: origin,
                                                  controller: controller,
                                                  registry: registry)
        self.dropHostWindowID = nil
        self.isOutsideAllHosts = false
        bumpVersion()
    }

    /// Cross-window pointer update. `windowLocal` is the window-local
    /// position inside the `currentWindowID` (used by overlays in the
    /// active window); `global` is the desktop-global position used to
    /// route the drop across all hosts via `coordinator`.
    @MainActor
    public func updatePointerCrossWindow(currentWindowID: WindowID,
                                         windowLocal: (x: Float, y: Float),
                                         global: (x: Float, y: Float),
                                         coordinator: DockHostCoordinator) {
        guard isActive else { return }
        self.pointerX = windowLocal.x
        self.pointerY = windowLocal.y
        self.globalPointerX = global.x
        self.globalPointerY = global.y
        self.hoverLeafID = coordinator.resolveGlobalHoverLeaf(globalX: global.x,
                                      globalY: global.y)?.leafID
        if let resolved = coordinator.resolveGlobalDropHit(globalX: global.x,
                                                           globalY: global.y,
                                                           sourceLeafID: sourceLeafID),
           let filtered = Self.filterAllowedDropHit(resolved.hit,
                                                    pointerX: windowLocal.x,
                                                    pointerY: windowLocal.y,
                                                    tabID: tabID,
                                                    sourceLeafID: sourceLeafID,
                                                    origin: origin,
                                                    controller: controller,
                                                    registry: resolved.host.hitRegistry) {
            self.dropHit = filtered
            self.dropHostWindowID = resolved.host.windowID
            self.isOutsideAllHosts = false
        } else {
            self.dropHit = nil
            self.dropHostWindowID = nil
            self.isOutsideAllHosts = true
        }
        _ = currentWindowID
        bumpVersion()
    }

    /// Finish the drag. When `commit` is `true`, the controller op fired
    /// depends on `origin` and the current `dropHit`/`isOutsideAllHosts`:
    /// - `.mainTreeTab` + drop on a registered leaf → `.move`
    /// - `.mainTreeTab` + outside all hosts → `.detach(leafID: source)`
    /// - `.satellite(leafID)` + drop on a registered leaf → `.redock`
    /// - `.satellite(leafID)` + outside all hosts → no-op (the satellite
    ///   window stays where it is)
    func end(commit: Bool) {
        defer {
            isActive = false
            tabID = nil
            sourceLeafID = nil
            ghost = nil
            hoverLeafID = nil
            dropHit = nil
            dropHostWindowID = nil
            isOutsideAllHosts = false
            origin = .mainTreeTab
            intent = .pendingClick
            bumpVersion()
        }
        guard commit, let controller else { return }

        switch origin {
        case .mainTreeTab:
            guard let tabID else { return }
            if let hit = dropHit {
                let target = Self.makeDropTarget(from: hit)
                controller.apply(.move(tabID: tabID, to: target))
            } else if isOutsideAllHosts, let sourceLeafID {
                let dx = globalPointerX - originGlobalX
                let dy = globalPointerY - originGlobalY
                let distSq = dx * dx + dy * dy
                let thresholdSq = Self.detachDistanceThreshold * Self.detachDistanceThreshold
                guard distSq >= thresholdSq else { return }
                controller.apply(.detach(leafID: sourceLeafID))
            }
        case .satellite(let leafID):
            if let hit = dropHit {
                let target = Self.makeDropTarget(from: hit)
                controller.apply(.redock(satelliteID: leafID, to: target))
            }
        case .mainTreeLeaf(let leafID):
            if let hit = dropHit {
                let target = Self.makeDropTarget(from: hit)
                controller.apply(.moveLeaf(leafID: leafID, to: target))
            } else if isOutsideAllHosts {
                let dx = globalPointerX - originGlobalX
                let dy = globalPointerY - originGlobalY
                let distSq = dx * dx + dy * dy
                let thresholdSq = Self.detachDistanceThreshold * Self.detachDistanceThreshold
                guard distSq >= thresholdSq else { return }
                controller.apply(.detach(leafID: leafID))
            }
        }
    }

    private static func makeDropTarget(from hit: LeafHit) -> DockDropTarget {
        if let idx = hit.tabSlotIndex {
            return .tabSlot(parent: hit.leafID, index: idx)
        }
        if hit.edge == .center {
            return .replace(target: hit.leafID)
        }
        return .splitEdge(target: hit.leafID, edge: hit.edge)
    }

    func cancel() { end(commit: false) }

    #if DEBUG
    /// Test-only hook: stamp cross-window resolution state without going
    /// through a `DockHostCoordinator`. Mirrors what
    /// `updatePointerCrossWindow` would set when the cluster reports a
    /// hit / no-hit. Used by `DockDetachThresholdTests` to exercise the
    /// distance-threshold gate in isolation.
    func applyCrossWindowState(globalX: Float,
                               globalY: Float,
                               isOutsideAllHosts: Bool) {
        guard isActive else { return }
        self.globalPointerX = globalX
        self.globalPointerY = globalY
        self.hoverLeafID = nil
        self.dropHit = nil
        self.dropHostWindowID = nil
        self.isOutsideAllHosts = isOutsideAllHosts
        bumpVersion()
    }
    #endif

    // MARK: - Listeners (used by overlays that need a redraw on motion)

    public func subscribe(_ handler: @escaping () -> Void) -> UInt64 {
        nextListenerID &+= 1
        let id = nextListenerID
        listeners[id] = handler
        return id
    }

    public func unsubscribe(_ id: UInt64) {
        listeners.removeValue(forKey: id)
    }

    private func bumpVersion() {
        version &+= 1
        for (_, h) in listeners { h() }
    }

    // MARK: - Hit resolution

    /// Pick a drop target from the leaf under `(x, y)`. Splits the leaf
    /// rectangle into 5 zones: a 25%-margin band on each side and a centre
    /// rectangle. Drops onto the source leaf with `.center` are filtered
    /// (no-op move) but still reported as "hit nothing" so the indicator
    /// hides.
    public static func resolveDropHit(x: Float, y: Float,
                                      sourceLeafID: DockNodeID?,
                                      registry: DockHitRegistry) -> LeafHit? {
        let leafHit = resolveLeafDropHit(x: x,
                                         y: y,
                                         sourceLeafID: sourceLeafID,
                                         registry: registry)
        if let rootGuideHit = resolveRootGuideHit(x: x, y: y, registry: registry),
           leafHit == nil || leafHit?.edge == .center {
            return rootGuideHit
        }
        if let rootHit = resolveRootEdgeHit(x: x, y: y, registry: registry),
           leafHit == nil || leafHit?.edge == rootHit.edge {
            return rootHit
        }
        return leafHit
    }

    private static func resolveRootGuideHit(x: Float, y: Float,
                                            registry: DockHitRegistry) -> LeafHit? {
        guard let root = registry.rootAt(x: x, y: y) else { return nil }
        return makeWorkspaceDropGuideTiles(in: UIRect(x: root.frame.x,
                                                      y: root.frame.y,
                                                      width: root.frame.width,
                                                      height: root.frame.height))
            .first(where: { tile in
                let rect = tile.buttonRect
                return x >= rect.x && x < rect.x + rect.width
                    && y >= rect.y && y < rect.y + rect.height
            })
            .map { LeafHit(leafID: root.id, edge: $0.edge, tabSlotIndex: nil) }
    }

    private static func resolveLeafDropHit(x: Float, y: Float,
                                           sourceLeafID: DockNodeID?,
                                           registry: DockHitRegistry) -> LeafHit? {
        guard let hit = registry.leafAt(x: x, y: y) else { return nil }
        let f = hit.frame
        let guideRect = UIRect(x: f.x, y: f.y, width: f.width, height: f.height)
        if let guideEdge = makeDockDropGuideTiles(in: guideRect)
            .first(where: { tile in
                let r = tile.buttonRect
                return x >= r.x && x < r.x + r.width
                    && y >= r.y && y < r.y + r.height
            })?.edge {
            if let src = sourceLeafID, src == hit.id, guideEdge == .center {
                return nil
            }
            return LeafHit(leafID: hit.id, edge: guideEdge, tabSlotIndex: nil)
        }
        // Edge bands: 25% of the smaller dimension on each side, capped at
        // 64 px so very large leaves don't have an absurdly wide drop band.
        let bandRaw = min(f.width, f.height) * 0.25
        let band = min(bandRaw, 64)
        let leftLimit   = f.x + band
        let rightLimit  = f.x + f.width - band
        let topLimit    = f.y + band
        let bottomLimit = f.y + f.height - band

        let edge: DockEdge
        if x < leftLimit {
            edge = .left
        } else if x >= rightLimit {
            edge = .right
        } else if y < topLimit {
            edge = .top
        } else if y >= bottomLimit {
            edge = .bottom
        } else {
            edge = .center
        }

        // Drop on self centre is a no-op — degrade to "no hit" so the
        // user gets visual feedback that the drag is parked.
        if let src = sourceLeafID, src == hit.id, edge == .center {
            return nil
        }

        return LeafHit(leafID: hit.id, edge: edge, tabSlotIndex: nil)
    }

    private static func resolveRootEdgeHit(x: Float, y: Float,
                                           registry: DockHitRegistry) -> LeafHit? {
        guard let root = registry.rootAt(x: x, y: y) else { return nil }
        let f = root.frame
        let band = max(Float(20), min(Float(32), min(f.width, f.height) * 0.06))
        let leftLimit = f.x + band
        let rightLimit = f.x + f.width - band
        let topLimit = f.y + band
        let bottomLimit = f.y + f.height - band

        let edge: DockEdge
        if x < leftLimit {
            edge = .left
        } else if x >= rightLimit {
            edge = .right
        } else if y < topLimit {
            edge = .top
        } else if y >= bottomLimit {
            edge = .bottom
        } else {
            return nil
        }

        return LeafHit(leafID: root.id, edge: edge, tabSlotIndex: nil)
    }

    public static func resolveAllowedDropHit(x: Float, y: Float,
                                             tabID: DockTabID?,
                                             sourceLeafID: DockNodeID?,
                                             origin: Origin,
                                             controller: DockController?,
                                             registry: DockHitRegistry) -> LeafHit? {
        let hit = resolveDropHit(x: x,
                                 y: y,
                                 sourceLeafID: sourceLeafID,
                                 registry: registry)
        return filterAllowedDropHit(hit,
                                    pointerX: x,
                                    pointerY: y,
                                    tabID: tabID,
                                    sourceLeafID: sourceLeafID,
                                    origin: origin,
                                    controller: controller,
                                    registry: registry)
    }

    private static func filterAllowedDropHit(_ hit: LeafHit?,
                                             pointerX: Float,
                                             pointerY: Float,
                                             tabID: DockTabID?,
                                             sourceLeafID: DockNodeID?,
                                             origin: Origin,
                                             controller: DockController?,
                                             registry: DockHitRegistry?) -> LeafHit? {
        guard let hit else { return nil }
        guard let controller else { return hit }
        let request = DockDropRequest(tabID: tabID,
                                      sourceLeafID: sourceLeafID,
                                      origin: origin,
                                      target: makeDropTarget(from: hit))
        if let remappedHit = remapRootHitToLeafFallback(rootHit: hit,
                                                        pointerX: pointerX,
                                                        pointerY: pointerY,
                                                        tabID: tabID,
                                                        sourceLeafID: sourceLeafID,
                                                        origin: origin,
                                                        controller: controller,
                                                        registry: registry) {
            return remappedHit
        }
        if controller.allowsDrop(request) {
            return hit
        }
        guard hit.edge != .center,
              let fallbackHit = fallbackReplaceHit(from: hit, controller: controller) else {
            return nil
        }
        let fallbackRequest = DockDropRequest(tabID: tabID,
                                              sourceLeafID: sourceLeafID,
                                              origin: origin,
                                              target: makeDropTarget(from: fallbackHit))
        return controller.allowsDrop(fallbackRequest) ? fallbackHit : nil
    }

    private static func remapRootHitToLeafFallback(rootHit: LeafHit,
                                                   pointerX: Float,
                                                   pointerY: Float,
                                                   tabID: DockTabID?,
                                                   sourceLeafID: DockNodeID?,
                                                   origin: Origin,
                                                   controller: DockController,
                                                   registry: DockHitRegistry?) -> LeafHit? {
        guard rootHit.leafID == controller.root.id,
              rootHit.edge != .center,
              let registry,
              let underlyingLeaf = registry.leafAt(x: pointerX, y: pointerY) else {
            return nil
        }

        let underlyingEdgeHit = LeafHit(leafID: underlyingLeaf.id,
                                        edge: rootHit.edge,
                                        tabSlotIndex: nil)
        let underlyingRequest = DockDropRequest(tabID: tabID,
                                                sourceLeafID: sourceLeafID,
                                                origin: origin,
                                                target: makeDropTarget(from: underlyingEdgeHit))
        guard controller.allowsDrop(underlyingRequest) == false,
              let fallbackHit = fallbackReplaceHit(from: underlyingEdgeHit,
                                                   controller: controller) else {
            return nil
        }

        let fallbackRequest = DockDropRequest(tabID: tabID,
                                              sourceLeafID: sourceLeafID,
                                              origin: origin,
                                              target: makeDropTarget(from: fallbackHit))
        return controller.allowsDrop(fallbackRequest) ? fallbackHit : nil
    }

    private static func fallbackReplaceHit(from hit: LeafHit,
                                           controller: DockController) -> LeafHit? {
        guard let targetNode = DockController.findNode(hit.leafID, in: controller.root) else {
            return nil
        }
        switch targetNode {
        case .tabs, .empty:
            return LeafHit(leafID: hit.leafID, edge: .center, tabSlotIndex: nil)
        case .split:
            return nil
        }
    }
}
