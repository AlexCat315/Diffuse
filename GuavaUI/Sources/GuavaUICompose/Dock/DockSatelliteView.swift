import EngineKernel
import GuavaUIRuntime

/// Root view for a satellite (floating) window that hosts a single
/// detached dock leaf.
///
/// Mounts the leaf currently stored at `controller.satellites[leafID]` and
/// (when a `hostBridge` is provided) registers its window with the
/// `DockHostCoordinator` so the satellite can be a drop target for tabs
/// dragged from any window in the cluster.
///
/// When the leaf disappears from the satellite map (because of a `.redock`
/// or `.closeSatellite` op) the view falls back to an empty placeholder.
/// The application is expected to listen on
/// `coordinator.onCloseSatelliteWindow` and close the native window.
public struct DockSatelliteView: View {
    public let controller: DockController
    public let leafID: DockNodeID
    public let content: DockContentResolver
    public let hostBridge: DockHostBridge?

    public init(controller: DockController,
                leafID: DockNodeID,
                hostBridge: DockHostBridge? = nil,
                content: @escaping DockContentResolver) {
        self.controller = controller
        self.leafID = leafID
        self.hostBridge = hostBridge
        self.content = content
    }

    public var body: some View {
        _StatefulDockSatellite(controller: controller,
                               leafID: leafID,
                               hostBridge: hostBridge,
                               content: content)
    }
}

struct _StatefulDockSatellite: View {
    let controller: DockController
    let leafID: DockNodeID
    let hostBridge: DockHostBridge?
    let content: DockContentResolver

    @State private var version: UInt64 = 0

    var body: some View {
        let _ = version
        let bind = $version
        // Reuse the same dedupe registry but key it by the satellite leaf
        // so it doesn't collide with the main `DockContainer`'s subscription.
        let _ = ControllerSubscription.acquire(
            controller: controller,
            tag: ObjectIdentifier(controller),
            bind: bind,
            extraTag: leafID.raw.uuidString
        )

        return _DockSatelliteHost(controller: controller,
                                  leafID: leafID,
                                  hostBridge: hostBridge) {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                _DockSatelliteTitleBar(controller: controller,
                                       leafID: leafID)
                _DockNodeView(node: controller.satellites[leafID]
                                    ?? .empty(id: DockNodeID()),
                              controller: controller,
                              content: content)
                    .flex()
            }
        }
    }
}

struct _DockSatelliteHost<Content: View>: _PrimitiveView {
    let controller: DockController
    let leafID: DockNodeID
    let hostBridge: DockHostBridge?
    let content: Content

    init(controller: DockController,
         leafID: DockNodeID,
         hostBridge: DockHostBridge?,
         @ViewBuilder content: () -> Content) {
        self.controller = controller
        self.leafID = leafID
        self.hostBridge = hostBridge
        self.content = content()
    }

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = false
        return n
    }

    func _updateNode(_ node: Node) {
        let registry = hostBridge?.hitRegistry ?? controller.hitRegistry
        let rootID = controller.satellites[leafID]?.id ?? leafID
        installDragGhostOverlay(node: node,
                                controller: controller,
                                rootNodeID: rootID)
        registry.registerRoot(nodeID: rootID, node: node)
        node.setCompositionValue(DockHostBridgeLocal, hostBridge)
        node.setCompositionValue(DockHitRegistryLocal, hostBridge?.hitRegistry)
        node.setCompositionValue(DockRootDropTargetIDLocal, rootID)
        if let bridge = hostBridge {
            MainActor.assumeIsolated {
                node.registerDockHostBridge(bridge)
            }
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let l = LayoutNode()
        l.flexDirection = .column
        l.alignItems = .stretch
        l.flexGrow = 1
        return l
    }

    var _children: [any View] { [content] }
}
