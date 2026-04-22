import EngineKernel
import GuavaUIRuntime

/// Convenience modifier that registers a `DockContainer` (or a
/// `DockSatelliteView`) with a `DockHostCoordinator` so cross-window drags
/// can resolve drops onto this window's leaves.
///
/// Geometry providers run on the main actor every time the coordinator
/// resolves a global pointer. They are expected to read the current
/// platform window position / logical size — wire them up to your
/// `PlatformWindowSession` (`session.logicalSize`, `shell.windowPosition`).
///
/// The modifier registers on first materialise and never unregisters —
/// this is intentional for the v1 wiring: most windows are long-lived and
/// the coordinator tolerates stale entries (their providers will simply
/// stop returning useful values when the window dies). A future iteration
/// will tie unregister to a real teardown hook.
public struct DockHostBridge: @unchecked Sendable {
    public let coordinator: DockHostCoordinator
    public let windowID: WindowID
    public let hitRegistry: DockHitRegistry
    public let originProvider: () -> (x: Float, y: Float)?
    public let logicalSizeProvider: () -> (width: Float, height: Float)
    /// `nil` registers as a main host; non-nil registers as a satellite
    /// host scoped to the given leaf.
    public let satelliteFor: DockNodeID?

    public init(coordinator: DockHostCoordinator,
                windowID: WindowID,
                hitRegistry: DockHitRegistry = DockHitRegistry(),
                satelliteFor: DockNodeID? = nil,
                originProvider: @escaping () -> (x: Float, y: Float)?,
                logicalSizeProvider: @escaping () -> (width: Float, height: Float)) {
        self.coordinator = coordinator
        self.windowID = windowID
        self.hitRegistry = hitRegistry
        self.satelliteFor = satelliteFor
        self.originProvider = originProvider
        self.logicalSizeProvider = logicalSizeProvider
    }
}

/// Composition local that publishes the current host's bridge to descendant
/// dock primitives (e.g. `DockTabBar`) so they can switch from single-window
/// pointer updates to cross-window ones without per-call plumbing.
public let DockHostBridgeLocal = CompositionLocal<DockHostBridge?>(defaultValue: nil)
let DockHitRegistryLocal = CompositionLocal<DockHitRegistry?>(defaultValue: nil)

/// Attachment slot used by `_DockContainerRoot` / `_DockSatelliteHost` to
/// remember whether they already registered with the coordinator. The
/// stored value is the returned `DockHostID` so future work can tear it
/// down when the host node dies.
enum DockHostBridgeAttachment {
    static let key = "__guavaui_dock_host_bridge_id"
}

extension Node {
    /// Idempotently register `self` with the bridge's coordinator. Subsequent
    /// calls are no-ops (the host stays registered; geometry providers are
    /// the original closures).
    @MainActor
    func registerDockHostBridge(_ bridge: DockHostBridge) {
        if attachments[DockHostBridgeAttachment.key] is DockHostID { return }

        let id: DockHostID
        if let leafID = bridge.satelliteFor {
            id = bridge.coordinator.registerSatelliteHost(
                leafID: leafID,
                windowID: bridge.windowID,
                hitRegistry: bridge.hitRegistry,
                originProvider: bridge.originProvider,
                logicalSizeProvider: bridge.logicalSizeProvider
            )
        } else {
            id = bridge.coordinator.registerMainHost(
                windowID: bridge.windowID,
                hitRegistry: bridge.hitRegistry,
                originProvider: bridge.originProvider,
                logicalSizeProvider: bridge.logicalSizeProvider
            )
        }
        attachments[DockHostBridgeAttachment.key] = id
    }

    /// The `DockHostID` previously stamped onto this node by
    /// `registerDockHostBridge`, if any. The application is responsible
    /// for calling `coordinator.unregisterHost(_:)` with this ID when
    /// the host window is destroyed (the framework cannot reliably
    /// observe Node teardown across actor boundaries — see commit log
    /// for the rejected `Node.deinit` approach).
    @MainActor
    public func dockHostID() -> DockHostID? {
        attachments[DockHostBridgeAttachment.key] as? DockHostID
    }
}

func resolveDockHitRegistry(on node: Node,
                            fallback: DockHitRegistry) -> DockHitRegistry {
    node.compositionValue(of: DockHitRegistryLocal) ?? fallback
}
