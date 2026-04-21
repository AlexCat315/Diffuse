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
    }
    public private(set) var origin: Origin = .mainTreeTab

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
               origin: Origin = .mainTreeTab) {
        self.tabID = tabID
        self.sourceLeafID = sourceLeafID
        self.ghost = ghost
        self.pointerX = x
        self.pointerY = y
        self.globalPointerX = globalX
        self.globalPointerY = globalY
        self.originGlobalX = globalX
        self.originGlobalY = globalY
        self.dropHit = nil
        self.dropHostWindowID = nil
        self.isOutsideAllHosts = false
        self.origin = origin
        self.isActive = true
        bumpVersion()
    }

    func updatePointer(x: Float, y: Float, registry: DockHitRegistry) {
        guard isActive else { return }
        self.pointerX = x
        self.pointerY = y
        self.dropHit = Self.resolveDropHit(x: x, y: y,
                                           sourceLeafID: sourceLeafID,
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
        if let resolved = coordinator.resolveGlobalDropHit(globalX: global.x,
                                                           globalY: global.y,
                                                           sourceLeafID: sourceLeafID) {
            self.dropHit = resolved.hit
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
            dropHit = nil
            dropHostWindowID = nil
            isOutsideAllHosts = false
            origin = .mainTreeTab
            bumpVersion()
        }
        guard commit, let controller else { return }

        switch origin {
        case .mainTreeTab:
            guard let tabID else { return }
            if let hit = dropHit {
                let target = makeDropTarget(from: hit)
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
                let target = makeDropTarget(from: hit)
                controller.apply(.redock(satelliteID: leafID, to: target))
            }
        }
    }

    private func makeDropTarget(from hit: LeafHit) -> DockDropTarget {
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
        guard let hit = registry.leafAt(x: x, y: y) else { return nil }
        let f = hit.frame
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
}
