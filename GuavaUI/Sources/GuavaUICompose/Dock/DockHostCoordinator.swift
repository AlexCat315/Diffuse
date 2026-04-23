import EngineKernel
import Foundation
import GuavaUIRuntime

/// Identity of a single dock host (one `DockContainer` mounted in one
/// native window). The coordinator uses this to route cross-window drops
/// and to associate spawned satellite windows with their detached leaves.
public struct DockHostID: Hashable, Sendable {
    public let raw: UInt64
    public init(raw: UInt64) { self.raw = raw }
}

/// Per-host runtime state owned by `DockHostCoordinator`. The host
/// publishes its hit registry, current logical size, and a getter for the
/// window's top-left position in desktop coordinates so the coordinator can
/// translate a global pointer into a leaf hit anywhere across the cluster.
public final class DockHostEntry {
    public let id: DockHostID
    public let windowID: WindowID
    public let hitRegistry: DockHitRegistry
    public let originProvider: () -> (x: Float, y: Float)?
    public let logicalSizeProvider: () -> (width: Float, height: Float)
    /// `true` when this host is the satellite window for a single detached
    /// leaf (so the coordinator can skip self-redock attempts).
    public let satelliteFor: DockNodeID?

    init(id: DockHostID,
         windowID: WindowID,
         hitRegistry: DockHitRegistry,
         originProvider: @escaping () -> (x: Float, y: Float)?,
         logicalSizeProvider: @escaping () -> (width: Float, height: Float),
         satelliteFor: DockNodeID?) {
        self.id = id
        self.windowID = windowID
        self.hitRegistry = hitRegistry
        self.originProvider = originProvider
        self.logicalSizeProvider = logicalSizeProvider
        self.satelliteFor = satelliteFor
    }
}

/// Cluster-wide registry of `DockContainer` instances backed by the same
/// `DockController` across multiple native windows.
///
/// Responsibilities:
/// - Maintain the set of live hosts plus a mapping from satellite leaf
///   `DockNodeID` to its hosting `WindowID`.
/// - Resolve a global pointer position to a `(host, leaf)` pair so the
///   drag session can target leaves in arbitrary windows.
/// - Notify the application when the model wants to spawn or close a
///   satellite (`onSpawnSatellite` / `onCloseSatellite`).
@MainActor
public final class DockHostCoordinator {
    public let controller: DockController

    /// Fired after `.detach` materialises a new satellite. The application
    /// reacts by opening a native window and calling `registerSatelliteHost`.
    /// The `originHint` is the desktop position the new window should
    /// appear at (typically the pointer location at drop time minus an
    /// inset so the title bar lands under the cursor).
    public var onSpawnSatellite: ((_ leafID: DockNodeID,
                                   _ snapshot: DockLayoutNode,
                                   _ originHint: (x: Float, y: Float)) -> Void)?

    /// Fired after `.redock` or `.closeSatellite` removes a satellite.
    /// The application reacts by destroying the corresponding window.
    public var onCloseSatelliteWindow: ((_ leafID: DockNodeID) -> Void)?

    private var hosts: [DockHostID: DockHostEntry] = [:]
    private var satelliteHostByLeaf: [DockNodeID: DockHostID] = [:]
    private var nextHostRaw: UInt64 = 0
    private var lastSatelliteSnapshot: [DockNodeID: DockLayoutNode] = [:]
    private var subscriptionToken: DockController.SubscriptionToken?

    public init(controller: DockController) {
        self.controller = controller
        subscriptionToken = controller.subscribe { [weak self] c in
            self?.reconcileSatellites(controller: c)
        }
    }

    deinit {
        // SubscriptionToken cleanup runs on whatever queue the coordinator
        // is released on; DockController.unsubscribe is thread-safe enough
        // for token removal because it's a dictionary write.
        if let token = subscriptionToken {
            controller.unsubscribe(token)
        }
    }

    // MARK: - Host registration

    @discardableResult
    public func registerMainHost(windowID: WindowID,
                                 hitRegistry: DockHitRegistry,
                                 originProvider: @escaping () -> (x: Float, y: Float)?,
                                 logicalSizeProvider: @escaping () -> (width: Float, height: Float)) -> DockHostID {
        return registerHost(windowID: windowID,
                            hitRegistry: hitRegistry,
                            originProvider: originProvider,
                            logicalSizeProvider: logicalSizeProvider,
                            satelliteFor: nil)
    }

    @discardableResult
    public func registerSatelliteHost(leafID: DockNodeID,
                                      windowID: WindowID,
                                      hitRegistry: DockHitRegistry,
                                      originProvider: @escaping () -> (x: Float, y: Float)?,
                                      logicalSizeProvider: @escaping () -> (width: Float, height: Float)) -> DockHostID {
        let id = registerHost(windowID: windowID,
                              hitRegistry: hitRegistry,
                              originProvider: originProvider,
                              logicalSizeProvider: logicalSizeProvider,
                              satelliteFor: leafID)
        satelliteHostByLeaf[leafID] = id
        return id
    }

    public func unregisterHost(_ id: DockHostID) {
        if let entry = hosts.removeValue(forKey: id),
           let leafID = entry.satelliteFor {
            satelliteHostByLeaf.removeValue(forKey: leafID)
        }
    }

    public func host(for windowID: WindowID) -> DockHostEntry? {
        hosts.values.first(where: { $0.windowID == windowID })
    }

    #if DEBUG
    /// Test-only snapshot of currently registered host entries. Used by
    /// `DockHostBridgeTeardownTests` to assert that releasing a host
    /// `Node` prunes the coordinator entry.
    var hostsSnapshot_forTesting: [DockHostID: DockHostEntry] { hosts }
    #endif

    public func satelliteWindowID(for leafID: DockNodeID) -> WindowID? {
        guard let id = satelliteHostByLeaf[leafID] else { return nil }
        return hosts[id]?.windowID
    }

    private func registerHost(windowID: WindowID,
                              hitRegistry: DockHitRegistry,
                              originProvider: @escaping () -> (x: Float, y: Float)?,
                              logicalSizeProvider: @escaping () -> (width: Float, height: Float),
                              satelliteFor: DockNodeID?) -> DockHostID {
        nextHostRaw &+= 1
        let id = DockHostID(raw: nextHostRaw)
        hosts[id] = DockHostEntry(
            id: id,
            windowID: windowID,
            hitRegistry: hitRegistry,
            originProvider: originProvider,
            logicalSizeProvider: logicalSizeProvider,
            satelliteFor: satelliteFor
        )
        return id
    }

    private func orderedHosts() -> [DockHostEntry] {
        hosts.values.sorted { lhs, rhs in
            lhs.id.raw > rhs.id.raw
        }
    }

    // MARK: - Cross-window hit resolution

    /// Resolve a desktop-global pointer to a leaf hit inside one of the
    /// registered hosts. Returns `nil` when the pointer is not over any
    /// registered window.
    public func resolveGlobalDropHit(globalX: Float,
                                     globalY: Float,
                                     sourceLeafID: DockNodeID?)
    -> (host: DockHostEntry, hit: DockDragSession.LeafHit)? {
        for entry in orderedHosts() {
            guard let origin = entry.originProvider() else { continue }
            let size = entry.logicalSizeProvider()
            let localX = globalX - origin.x
            let localY = globalY - origin.y
            guard localX >= 0, localY >= 0,
                  localX < size.width, localY < size.height else { continue }
            // The pointer is over this window. Try to map it onto a leaf.
            if let hit = DockDragSession.resolveDropHit(x: localX, y: localY,
                                                        sourceLeafID: sourceLeafID,
                                                        registry: entry.hitRegistry) {
                return (entry, hit)
            }
            // Pointer is over the window but not over any leaf (e.g. inside
            // chrome). Stop searching — windows don't overlap meaningfully
            // for our purposes; reporting "no hit" is intentional so the
            // drag indicator hides while hovering chrome.
            return nil
        }
        return nil
    }

    public func resolveGlobalHoverLeaf(globalX: Float,
                                       globalY: Float)
    -> (host: DockHostEntry, leafID: DockNodeID)? {
        for entry in orderedHosts() {
            guard let origin = entry.originProvider() else { continue }
            let size = entry.logicalSizeProvider()
            let localX = globalX - origin.x
            let localY = globalY - origin.y
            guard localX >= 0, localY >= 0,
                  localX < size.width, localY < size.height else { continue }
            guard let hit = entry.hitRegistry.leafAt(x: localX, y: localY) else {
                return nil
            }
            return (entry, hit.id)
        }
        return nil
    }

    // MARK: - Satellite reconciliation

    private func reconcileSatellites(controller: DockController) {
        let current = controller.satellites
        let previous = lastSatelliteSnapshot

        // Spawn newly-detached satellites.
        for leafID in controller.satelliteOrder where previous[leafID] == nil {
            guard let snapshot = current[leafID] else { continue }
            let originHint = pendingDetachOrigin(for: leafID)
            onSpawnSatellite?(leafID, snapshot, originHint)
        }

        // Tear down satellites that the model no longer tracks.
        for leafID in previous.keys where current[leafID] == nil {
            satelliteHostByLeaf.removeValue(forKey: leafID)
            onCloseSatelliteWindow?(leafID)
        }

        lastSatelliteSnapshot = current
    }

    /// Best-effort pointer position used when seeding a satellite window.
    /// Returns the active drag pointer when a drag is in flight, otherwise
    /// `(0, 0)` and lets the application decide where to place the window.
    private func pendingDetachOrigin(for leafID: DockNodeID) -> (x: Float, y: Float) {
        let session = controller.dragSession
        if session.isActive,
           session.tabID != nil || session.sourceLeafID == leafID {
            return (session.globalPointerX, session.globalPointerY)
        }
        return (0, 0)
    }
}
