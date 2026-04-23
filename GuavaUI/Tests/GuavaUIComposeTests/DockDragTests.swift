import Testing
import CoreGraphics
import GuavaUIRuntime
import EngineKernel
@testable import GuavaUICompose

/// Phase D2 — drag activation, drop-zone hit resolution, and the resulting
/// `.move` operation applied to the controller.
@Suite("Phase D2 / Dock drag", .serialized)
struct DockDragTests: GuavaUIComposeSerializedSuite {

    private func makeContent() -> DockContentResolver {
        return { key in AnyView(Text("k:\(key)")) }
    }

    /// Locate every hit-testable node — these correspond to tab items and
    /// resize handles. Tab items always have `.cursor == .pointer`.
    private func findTabItems(_ root: Node) -> [Node] {
        var out: [Node] = []
        func walk(_ n: Node) {
            // The close-X subtree contains its own pointer-cursor node
            // (the inner Button). Stop descending at the marker so it
            // doesn't get counted as a tab item.
            if n.attachments[_DockTabCloseButtonHost.kCloseButtonMarker] != nil {
                return
            }
            if n.isHitTestable, n.cursor == .pointer {
                out.append(n)
            }
            for c in n.children { walk(c) }
        }
        walk(root)
        return out
    }

    private func findLeafHandles(_ root: Node) -> [Node] {
        var out: [Node] = []
        func walk(_ n: Node) {
            if n.isHitTestable, n.cursor == .move {
                out.append(n)
            }
            for c in n.children { walk(c) }
        }
        walk(root)
        return out
    }

    private func absoluteFrame(of node: Node) -> CGRect {
        var origin = node.frame.origin
        var cursor = node.parent
        while let current = cursor {
            origin.x += current.frame.origin.x
            origin.y += current.frame.origin.y
            cursor = current.parent
        }
        return CGRect(origin: origin, size: node.frame.size)
    }

    private func editorLikeTabNodes(_ root: Node) -> (hierarchy: Node, viewport: Node, inspector: Node, console: Node) {
        let items = findTabItems(root)
        let console = items.max(by: { absoluteFrame(of: $0).origin.y < absoluteFrame(of: $1).origin.y })!
        let topItems = items.filter { $0 !== console }
            .sorted(by: { absoluteFrame(of: $0).origin.x < absoluteFrame(of: $1).origin.x })
        return (hierarchy: topItems[0], viewport: topItems[1], inspector: topItems[2], console: console)
    }

    private func dropPoint(for edge: DockEdge,
                           in frame: CGRect) -> (x: Float, y: Float) {
        let band = min(Float(min(frame.width, frame.height)) * 0.25, 64)
        switch edge {
        case .left:
            return (Float(frame.minX) + max(2, band - 2), Float(frame.midY))
        case .right:
            return (Float(frame.maxX) - max(2, band - 2), Float(frame.midY))
        case .top:
            return (Float(frame.midX), Float(frame.minY) + max(2, band - 2))
        case .bottom:
            return (Float(frame.midX), Float(frame.maxY) - max(2, band - 2))
        case .center:
            return (Float(frame.midX), Float(frame.midY))
        }
    }

    private func leafFrame(containing tabNode: Node,
                           controller: DockController) -> CGRect {
        let tabFrame = absoluteFrame(of: tabNode)
        let hit = controller.hitRegistry.leafAt(x: Float(tabFrame.midX),
                                                y: Float(tabFrame.midY))
        #expect(hit != nil)
        guard let hit else { return tabFrame }
        return CGRect(x: CGFloat(hit.frame.x),
                      y: CGFloat(hit.frame.y),
                      width: CGFloat(hit.frame.width),
                      height: CGFloat(hit.frame.height))
    }

    private func installEditorRegionPolicy(on controller: DockController) {
        let regionByKey = [
            "hierarchy": "leading",
            "viewport": "center",
            "inspector": "trailing",
            "console": "bottom",
        ]
        controller.onAllowDrop = { [regionByKey] request in
            guard case .splitEdge(let targetID, let edge) = request.target else {
                return true
            }
            guard let targetRegion = regionOfLeaf(id: targetID,
                                                  in: controller.root,
                                                  regionByKey: regionByKey) else {
                return true
            }
            return allowsEditorSplitEdge(in: targetRegion, edge: edge)
        }
    }

    private func allowsEditorSplitEdge(in region: String,
                                       edge: DockEdge) -> Bool {
        switch region {
        case "center":
            return true
        case "leading", "trailing":
            return edge == .top || edge == .bottom
        case "bottom":
            return edge == .left || edge == .right
        default:
            return true
        }
    }

    @Test("Pointer down + small motion does NOT start a drag (click threshold)")
    func clickThresholdGuardsDrag() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tab = DockTab(userKey: "k", title: "K")
        let controller = DockController(root: .tabs([tab]))
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let items = findTabItems(tree.root!)
        #expect(items.count == 1)
        let tabNode = items[0]

        let pointer = registry.handlers(for: tabNode).pointer!
        let motion  = registry.handlers(for: tabNode).motion!

        _ = pointer(MouseButtonEvent(button: .left, x: 10, y: 10, clicks: 1), .down, .target)
        // Move 2 px — under the 4 px threshold.
        _ = motion(MouseMotionEvent(x: 12, y: 11, deltaX: 2, deltaY: 1), .target)
        #expect(controller.dragSession.isActive == false)
    } }

    @Test("Crossing the threshold starts a drag session with source leaf metadata")
    func crossesThresholdStartsDrag() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tab = DockTab(userKey: "k", title: "K")
        let controller = DockController(root: .tabs([tab]))
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let tabNode = findTabItems(tree.root!)[0]
        let pointer = registry.handlers(for: tabNode).pointer!
        let motion  = registry.handlers(for: tabNode).motion!

        _ = pointer(MouseButtonEvent(button: .left, x: 10, y: 10, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 30, y: 30, deltaX: 20, deltaY: 20), .target)

        #expect(controller.dragSession.isActive)
        #expect(controller.dragSession.tabID == tab.id)
        if case .tabs(let leafID, _, _) = controller.root {
            #expect(controller.dragSession.sourceLeafID == leafID)
        } else {
            Issue.record("expected tabs leaf at root")
        }
    } }

    @Test("Drop on right-edge of a sibling leaf splits horizontally")
    func dropRightEdgeSplits() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let controller = DockController(root:
            .hsplit(fraction: 0.5,
                    first: .tabs([a]),
                    second: .tabs([b]))
        )
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let items = findTabItems(tree.root!)
        // Two tabs total; pick tab A (leftmost on screen by frame).
        let tabA = items.min(by: { $0.frame.origin.x < $1.frame.origin.x })!
        let pointer = registry.handlers(for: tabA).pointer!
        let motion  = registry.handlers(for: tabA).motion!

        _ = pointer(MouseButtonEvent(button: .left, x: 30, y: 12, clicks: 1), .down, .target)
        // Drag past threshold to start.
        _ = motion(MouseMotionEvent(x: 50, y: 30, deltaX: 20, deltaY: 18), .target)
        // Move into the right edge of leaf B (right half of a 600-wide window).
        _ = motion(MouseMotionEvent(x: 580, y: 200, deltaX: 530, deltaY: 170), .target)
        #expect(controller.dragSession.dropHit?.edge == .right)

        _ = pointer(MouseButtonEvent(button: .left, x: 580, y: 200, clicks: 1), .up, .target)

        // After the drop tab A should sit in a new leaf to the right of leaf B.
        // Because removing tab A leaves the source leaf empty, the original
        // outer split collapses and the new split becomes the root.
        guard case .split(_, .horizontal, _, let lhs, let rhs) = controller.root,
              case .tabs(_, let lhsTabs, _) = lhs,
              case .tabs(_, let rhsTabs, _) = rhs else {
            Issue.record("expected horizontal split with two tab leaves, got \(controller.root)")
            return
        }
        #expect(lhsTabs.contains { $0.id == b.id })
        #expect(rhsTabs.contains { $0.id == a.id })
    } }

    @Test("First lift motion resolves the preview target immediately")
    func firstLiftMotionResolvesPreviewTarget() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let controller = DockController(root:
            .hsplit(fraction: 0.5,
                    first: .tabs([a]),
                    second: .tabs([b]))
        )
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let items = findTabItems(tree.root!)
        let tabA = items.min(by: { $0.frame.origin.x < $1.frame.origin.x })!
        let pointer = registry.handlers(for: tabA).pointer!
        let motion = registry.handlers(for: tabA).motion!

        _ = pointer(MouseButtonEvent(button: .left, x: 30, y: 12, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 580, y: 200, deltaX: 550, deltaY: 188), .target)

        #expect(controller.dragSession.isActive)
        #expect(controller.dragSession.intent == .detachOrSplit)
        #expect(controller.dragSession.hoverLeafID != nil)
        #expect(controller.dragSession.dropHit?.edge == .right)
    } }

    @Test("Dragging console to the hierarchy right edge merges it into the hierarchy region")
    func editorLikeConsoleToHierarchyRightMergesIntoHierarchyRegion() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let hierarchy = DockTab(userKey: "hierarchy", title: "Hierarchy")
        let viewport = DockTab(userKey: "viewport", title: "Viewport", isClosable: false)
        let inspector = DockTab(userKey: "inspector", title: "Inspector")
        let console = DockTab(userKey: "console", title: "Console")

        let hierarchyLeaf = DockLayoutNode.tabs([hierarchy])
        let viewportLeaf = DockLayoutNode.tabs([viewport])
        let inspectorLeaf = DockLayoutNode.tabs([inspector])
        let consoleLeaf = DockLayoutNode.tabs([console])
        let topRight = DockLayoutNode.hsplit(fraction: 55.0 / 75.0,
                                             first: viewportLeaf,
                                             second: inspectorLeaf)
        let topRow = DockLayoutNode.hsplit(fraction: 15.0 / 90.0,
                                           first: hierarchyLeaf,
                                           second: topRight)
        let controller = DockController(root: .vsplit(fraction: 0.7,
                                                      first: topRow,
                                                      second: consoleLeaf))
        installEditorRegionPolicy(on: controller)

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let consoleNode = editorLikeTabNodes(tree.root!).console
        let pointer = registry.handlers(for: consoleNode).pointer!
        let motion = registry.handlers(for: consoleNode).motion!
        let hierarchyPoint = dropPoint(for: .right,
                           in: leafFrame(containing: editorLikeTabNodes(tree.root!).hierarchy,
                                 controller: controller))

        _ = pointer(MouseButtonEvent(button: .left, x: 40, y: 300, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 60, y: 278, deltaX: 20, deltaY: -22), .target)
        _ = motion(MouseMotionEvent(x: hierarchyPoint.x,
                        y: hierarchyPoint.y,
                        deltaX: hierarchyPoint.x - 60,
                        deltaY: hierarchyPoint.y - 278), .target)

        #expect(controller.dragSession.dropHit?.leafID == hierarchyLeaf.id)
        #expect(controller.dragSession.dropHit?.edge == .center)

        _ = pointer(MouseButtonEvent(button: .left, x: hierarchyPoint.x, y: hierarchyPoint.y, clicks: 1), .up, .target)

        guard case .split(_, .horizontal, _, let hierarchyNode, let remainder) = controller.root,
              case .tabs(_, let hierarchyTabs, let activeHierarchy) = hierarchyNode,
              case .split(_, .horizontal, _, let viewportNode, let inspectorNode) = remainder,
              case .tabs(_, let viewportTabs, _) = viewportNode,
              case .tabs(_, let inspectorTabs, _) = inspectorNode else {
            Issue.record("expected the bottom tabset to collapse and console to merge into the hierarchy region")
            return
        }

        #expect(hierarchyTabs.map(\.userKey) == ["hierarchy", "console"])
        #expect(activeHierarchy == console.id)
        #expect(viewportTabs.map(\.userKey) == ["viewport"])
        #expect(inspectorTabs.map(\.userKey) == ["inspector"])
    } }

    @Test("Dragging console to the inspector left edge merges it into the inspector region")
    func editorLikeConsoleToInspectorLeftMergesIntoInspectorRegion() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let hierarchy = DockTab(userKey: "hierarchy", title: "Hierarchy")
        let viewport = DockTab(userKey: "viewport", title: "Viewport", isClosable: false)
        let inspector = DockTab(userKey: "inspector", title: "Inspector")
        let console = DockTab(userKey: "console", title: "Console")

        let controller = DockController(root: .vsplit(fraction: 0.7,
                                                      first: .hsplit(fraction: 15.0 / 90.0,
                                                                     first: .tabs([hierarchy]),
                                                                     second: .hsplit(fraction: 55.0 / 75.0,
                                                                                     first: .tabs([viewport]),
                                                                                     second: .tabs([inspector]))),
                                                      second: .tabs([console])))
        installEditorRegionPolicy(on: controller)

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let nodes = editorLikeTabNodes(tree.root!)
        let pointer = registry.handlers(for: nodes.console).pointer!
        let motion = registry.handlers(for: nodes.console).motion!
        let inspectorPoint = dropPoint(for: .left,
                           in: leafFrame(containing: nodes.inspector,
                                 controller: controller))

        _ = pointer(MouseButtonEvent(button: .left, x: 40, y: 300, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 60, y: 278, deltaX: 20, deltaY: -22), .target)
        _ = motion(MouseMotionEvent(x: inspectorPoint.x,
                        y: inspectorPoint.y,
                        deltaX: inspectorPoint.x - 60,
                        deltaY: inspectorPoint.y - 278), .target)

        #expect(controller.dragSession.dropHit?.edge == .center)

        _ = pointer(MouseButtonEvent(button: .left, x: inspectorPoint.x, y: inspectorPoint.y, clicks: 1), .up, .target)

        guard case .split(_, .horizontal, _, let hierarchyNode, let remainder) = controller.root,
              case .tabs(_, let hierarchyTabs, _) = hierarchyNode,
              case .split(_, .horizontal, _, let viewportNode, let inspectorNode) = remainder,
              case .tabs(_, let viewportTabs, _) = viewportNode,
              case .tabs(_, let inspectorTabs, let activeInspector) = inspectorNode else {
            Issue.record("expected console to merge into the inspector region")
            return
        }

        #expect(hierarchyTabs.map(\.userKey) == ["hierarchy"])
        #expect(viewportTabs.map(\.userKey) == ["viewport"])
        #expect(inspectorTabs.map(\.userKey) == ["inspector", "console"])
        #expect(activeInspector == console.id)
    } }

    @Test("Dragging console to the hierarchy left edge merges it into the hierarchy region")
    func editorLikeConsoleToHierarchyLeftMergesIntoHierarchyRegion() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let hierarchy = DockTab(userKey: "hierarchy", title: "Hierarchy")
        let viewport = DockTab(userKey: "viewport", title: "Viewport", isClosable: false)
        let inspector = DockTab(userKey: "inspector", title: "Inspector")
        let console = DockTab(userKey: "console", title: "Console")

        let hierarchyLeaf = DockLayoutNode.tabs([hierarchy])
        let controller = DockController(root: .vsplit(fraction: 0.7,
                                                      first: .hsplit(fraction: 15.0 / 90.0,
                                                                     first: hierarchyLeaf,
                                                                     second: .hsplit(fraction: 55.0 / 75.0,
                                                                                     first: .tabs([viewport]),
                                                                                     second: .tabs([inspector]))),
                                                      second: .tabs([console])))
        installEditorRegionPolicy(on: controller)

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let nodes = editorLikeTabNodes(tree.root!)
        let pointer = registry.handlers(for: nodes.console).pointer!
        let motion = registry.handlers(for: nodes.console).motion!
        let hierarchyPoint = dropPoint(for: .left,
                                       in: leafFrame(containing: nodes.hierarchy,
                                                     controller: controller))

        _ = pointer(MouseButtonEvent(button: .left, x: 40, y: 300, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 60, y: 278, deltaX: 20, deltaY: -22), .target)
        _ = motion(MouseMotionEvent(x: hierarchyPoint.x,
                                    y: hierarchyPoint.y,
                                    deltaX: hierarchyPoint.x - 60,
                                    deltaY: hierarchyPoint.y - 278), .target)

        #expect(controller.dragSession.dropHit?.leafID == hierarchyLeaf.id)
        #expect(controller.dragSession.dropHit?.edge == .center)

        _ = pointer(MouseButtonEvent(button: .left, x: hierarchyPoint.x, y: hierarchyPoint.y, clicks: 1), .up, .target)

        guard case .split(_, .horizontal, _, let hierarchyNode, let remainder) = controller.root,
              case .tabs(_, let hierarchyTabs, let activeHierarchy) = hierarchyNode,
              case .split(_, .horizontal, _, let viewportNode, let inspectorNode) = remainder,
              case .tabs(_, let viewportTabs, _) = viewportNode,
              case .tabs(_, let inspectorTabs, _) = inspectorNode else {
            Issue.record("expected console to merge into the hierarchy region from the outer left edge")
            return
        }

        #expect(hierarchyTabs.map(\.userKey) == ["hierarchy", "console"])
        #expect(activeHierarchy == console.id)
        #expect(viewportTabs.map(\.userKey) == ["viewport"])
        #expect(inspectorTabs.map(\.userKey) == ["inspector"])
    } }

    @Test("Dragging console to the inspector right edge merges it into the inspector region")
    func editorLikeConsoleToInspectorRightMergesIntoInspectorRegion() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let hierarchy = DockTab(userKey: "hierarchy", title: "Hierarchy")
        let viewport = DockTab(userKey: "viewport", title: "Viewport", isClosable: false)
        let inspector = DockTab(userKey: "inspector", title: "Inspector")
        let console = DockTab(userKey: "console", title: "Console")

        let inspectorLeaf = DockLayoutNode.tabs([inspector])
        let controller = DockController(root: .vsplit(fraction: 0.7,
                                                      first: .hsplit(fraction: 15.0 / 90.0,
                                                                     first: .tabs([hierarchy]),
                                                                     second: .hsplit(fraction: 55.0 / 75.0,
                                                                                     first: .tabs([viewport]),
                                                                                     second: inspectorLeaf)),
                                                      second: .tabs([console])))
        installEditorRegionPolicy(on: controller)

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let nodes = editorLikeTabNodes(tree.root!)
        let pointer = registry.handlers(for: nodes.console).pointer!
        let motion = registry.handlers(for: nodes.console).motion!
        let inspectorPoint = dropPoint(for: .right,
                                       in: leafFrame(containing: nodes.inspector,
                                                     controller: controller))

        _ = pointer(MouseButtonEvent(button: .left, x: 40, y: 300, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 60, y: 278, deltaX: 20, deltaY: -22), .target)
        _ = motion(MouseMotionEvent(x: inspectorPoint.x,
                                    y: inspectorPoint.y,
                                    deltaX: inspectorPoint.x - 60,
                                    deltaY: inspectorPoint.y - 278), .target)

        #expect(controller.dragSession.dropHit?.leafID == inspectorLeaf.id)
        #expect(controller.dragSession.dropHit?.edge == .center)

        _ = pointer(MouseButtonEvent(button: .left, x: inspectorPoint.x, y: inspectorPoint.y, clicks: 1), .up, .target)

        guard case .split(_, .horizontal, _, let hierarchyNode, let remainder) = controller.root,
              case .tabs(_, let hierarchyTabs, _) = hierarchyNode,
              case .split(_, .horizontal, _, let viewportNode, let inspectorNode) = remainder,
              case .tabs(_, let viewportTabs, _) = viewportNode,
              case .tabs(_, let inspectorTabs, let activeInspector) = inspectorNode else {
            Issue.record("expected console to merge into the inspector region from the outer right edge")
            return
        }

        #expect(hierarchyTabs.map(\.userKey) == ["hierarchy"])
        #expect(viewportTabs.map(\.userKey) == ["viewport"])
        #expect(inspectorTabs.map(\.userKey) == ["inspector", "console"])
        #expect(activeInspector == console.id)
    } }

    @Test("Dragging console to the inspector bottom edge splits the inspector region vertically")
    func editorLikeConsoleToInspectorBottomSplitsInspectorRegion() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let hierarchy = DockTab(userKey: "hierarchy", title: "Hierarchy")
        let viewport = DockTab(userKey: "viewport", title: "Viewport", isClosable: false)
        let inspector = DockTab(userKey: "inspector", title: "Inspector")
        let console = DockTab(userKey: "console", title: "Console")

        let inspectorLeaf = DockLayoutNode.tabs([inspector])
        let controller = DockController(root: .vsplit(fraction: 0.7,
                                                      first: .hsplit(fraction: 15.0 / 90.0,
                                                                     first: .tabs([hierarchy]),
                                                                     second: .hsplit(fraction: 55.0 / 75.0,
                                                                                     first: .tabs([viewport]),
                                                                                     second: inspectorLeaf)),
                                                      second: .tabs([console])))
        installEditorRegionPolicy(on: controller)

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let nodes = editorLikeTabNodes(tree.root!)
        let pointer = registry.handlers(for: nodes.console).pointer!
        let motion = registry.handlers(for: nodes.console).motion!
        let inspectorPoint = dropPoint(for: .bottom,
                           in: leafFrame(containing: nodes.inspector,
                                 controller: controller))

        _ = pointer(MouseButtonEvent(button: .left, x: 40, y: 300, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 60, y: 278, deltaX: 20, deltaY: -22), .target)
        _ = motion(MouseMotionEvent(x: inspectorPoint.x,
                        y: inspectorPoint.y,
                        deltaX: inspectorPoint.x - 60,
                        deltaY: inspectorPoint.y - 278), .target)

        #expect(controller.dragSession.dropHit?.leafID == inspectorLeaf.id)
        #expect(controller.dragSession.dropHit?.edge == .bottom)

        _ = pointer(MouseButtonEvent(button: .left, x: inspectorPoint.x, y: inspectorPoint.y, clicks: 1), .up, .target)

        guard case .split(_, .horizontal, _, let hierarchyNode, let remainder) = controller.root,
              case .tabs(_, let hierarchyTabs, _) = hierarchyNode,
              case .split(_, .horizontal, _, let viewportNode, let inspectorArea) = remainder,
              case .tabs(_, let viewportTabs, _) = viewportNode,
              case .split(_, .vertical, _, let inspectorNode, let consoleNode) = inspectorArea,
              case .tabs(_, let inspectorTabs, _) = inspectorNode,
              case .tabs(_, let consoleTabs, let activeConsole) = consoleNode else {
            Issue.record("expected inspector region to split vertically")
            return
        }

        #expect(hierarchyTabs.map(\.userKey) == ["hierarchy"])
        #expect(viewportTabs.map(\.userKey) == ["viewport"])
        #expect(inspectorTabs.map(\.userKey) == ["inspector"])
        #expect(consoleTabs.map(\.userKey) == ["console"])
        #expect(activeConsole == console.id)
    } }

    @Test("Dragging hierarchy to the bottom right edge splits the bottom region horizontally")
    func editorLikeHierarchyToBottomRightSplitsBottomRegion() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let hierarchy = DockTab(userKey: "hierarchy", title: "Hierarchy")
        let viewport = DockTab(userKey: "viewport", title: "Viewport", isClosable: false)
        let inspector = DockTab(userKey: "inspector", title: "Inspector")
        let console = DockTab(userKey: "console", title: "Console")

        let consoleLeaf = DockLayoutNode.tabs([console])
        let controller = DockController(root: .vsplit(fraction: 0.7,
                                                      first: .hsplit(fraction: 15.0 / 90.0,
                                                                     first: .tabs([hierarchy]),
                                                                     second: .hsplit(fraction: 55.0 / 75.0,
                                                                                     first: .tabs([viewport]),
                                                                                     second: .tabs([inspector]))),
                                                      second: consoleLeaf))
        installEditorRegionPolicy(on: controller)

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let nodes = editorLikeTabNodes(tree.root!)
        let pointer = registry.handlers(for: nodes.hierarchy).pointer!
        let motion = registry.handlers(for: nodes.hierarchy).motion!
        let bottomPoint = dropPoint(for: .right,
                        in: leafFrame(containing: nodes.console,
                              controller: controller))

        _ = pointer(MouseButtonEvent(button: .left, x: 40, y: 30, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 60, y: 52, deltaX: 20, deltaY: 22), .target)
        _ = motion(MouseMotionEvent(x: bottomPoint.x,
                        y: bottomPoint.y,
                        deltaX: bottomPoint.x - 60,
                        deltaY: bottomPoint.y - 52), .target)

        #expect(controller.dragSession.dropHit?.leafID == consoleLeaf.id)
        #expect(controller.dragSession.dropHit?.edge == .right)

        _ = pointer(MouseButtonEvent(button: .left, x: bottomPoint.x, y: bottomPoint.y, clicks: 1), .up, .target)

        guard case .split(_, .vertical, _, let top, let bottomArea) = controller.root,
              case .split(_, .horizontal, _, let viewportNode, let inspectorNode) = top,
              case .tabs(_, let viewportTabs, _) = viewportNode,
              case .tabs(_, let inspectorTabs, _) = inspectorNode,
              case .split(_, .horizontal, _, let consoleNode, let hierarchyNode) = bottomArea,
              case .tabs(_, let consoleTabs, _) = consoleNode,
              case .tabs(_, let hierarchyTabs, let activeHierarchy) = hierarchyNode else {
            Issue.record("expected bottom region to split horizontally")
            return
        }

        #expect(viewportTabs.map(\.userKey) == ["viewport"])
        #expect(inspectorTabs.map(\.userKey) == ["inspector"])
        #expect(consoleTabs.map(\.userKey) == ["console"])
        #expect(hierarchyTabs.map(\.userKey) == ["hierarchy"])
        #expect(activeHierarchy == hierarchy.id)
    } }

    @Test("Dragging hierarchy to the bottom top edge merges it into the bottom region")
    func editorLikeHierarchyToBottomTopMergesIntoBottomRegion() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let hierarchy = DockTab(userKey: "hierarchy", title: "Hierarchy")
        let viewport = DockTab(userKey: "viewport", title: "Viewport", isClosable: false)
        let inspector = DockTab(userKey: "inspector", title: "Inspector")
        let console = DockTab(userKey: "console", title: "Console")

        let consoleLeaf = DockLayoutNode.tabs([console])
        let controller = DockController(root: .vsplit(fraction: 0.7,
                                                      first: .hsplit(fraction: 15.0 / 90.0,
                                                                     first: .tabs([hierarchy]),
                                                                     second: .hsplit(fraction: 55.0 / 75.0,
                                                                                     first: .tabs([viewport]),
                                                                                     second: .tabs([inspector]))),
                                                      second: consoleLeaf))
        installEditorRegionPolicy(on: controller)

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let nodes = editorLikeTabNodes(tree.root!)
        let pointer = registry.handlers(for: nodes.hierarchy).pointer!
        let motion = registry.handlers(for: nodes.hierarchy).motion!
        let bottomPoint = dropPoint(for: .top,
                        in: leafFrame(containing: nodes.console,
                              controller: controller))

        _ = pointer(MouseButtonEvent(button: .left, x: 40, y: 30, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 60, y: 52, deltaX: 20, deltaY: 22), .target)
        _ = motion(MouseMotionEvent(x: bottomPoint.x,
                        y: bottomPoint.y,
                        deltaX: bottomPoint.x - 60,
                        deltaY: bottomPoint.y - 52), .target)

        #expect(controller.dragSession.dropHit?.leafID == consoleLeaf.id)
        #expect(controller.dragSession.dropHit?.edge == .center)

        _ = pointer(MouseButtonEvent(button: .left, x: bottomPoint.x, y: bottomPoint.y, clicks: 1), .up, .target)

        guard case .split(_, .vertical, _, let top, let bottomNode) = controller.root,
              case .split(_, .horizontal, _, let viewportNode, let inspectorNode) = top,
              case .tabs(_, let viewportTabs, _) = viewportNode,
              case .tabs(_, let inspectorTabs, _) = inspectorNode,
              case .tabs(_, let bottomTabs, let activeBottom) = bottomNode else {
            Issue.record("expected hierarchy to merge into the bottom region")
            return
        }

        #expect(viewportTabs.map(\.userKey) == ["viewport"])
        #expect(inspectorTabs.map(\.userKey) == ["inspector"])
        #expect(bottomTabs.map(\.userKey) == ["console", "hierarchy"])
        #expect(activeBottom == hierarchy.id)
    } }

    @Test("Dragging hierarchy to the bottom bottom edge merges it into the bottom region")
    func editorLikeHierarchyToBottomBottomMergesIntoBottomRegion() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let hierarchy = DockTab(userKey: "hierarchy", title: "Hierarchy")
        let viewport = DockTab(userKey: "viewport", title: "Viewport", isClosable: false)
        let inspector = DockTab(userKey: "inspector", title: "Inspector")
        let console = DockTab(userKey: "console", title: "Console")

        let consoleLeaf = DockLayoutNode.tabs([console])
        let controller = DockController(root: .vsplit(fraction: 0.7,
                                                      first: .hsplit(fraction: 15.0 / 90.0,
                                                                     first: .tabs([hierarchy]),
                                                                     second: .hsplit(fraction: 55.0 / 75.0,
                                                                                     first: .tabs([viewport]),
                                                                                     second: .tabs([inspector]))),
                                                      second: consoleLeaf))
        installEditorRegionPolicy(on: controller)

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let nodes = editorLikeTabNodes(tree.root!)
        let pointer = registry.handlers(for: nodes.hierarchy).pointer!
        let motion = registry.handlers(for: nodes.hierarchy).motion!
        let bottomPoint = dropPoint(for: .bottom,
                                    in: leafFrame(containing: nodes.console,
                                                  controller: controller))

        _ = pointer(MouseButtonEvent(button: .left, x: 40, y: 30, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 60, y: 52, deltaX: 20, deltaY: 22), .target)
        _ = motion(MouseMotionEvent(x: bottomPoint.x,
                                    y: bottomPoint.y,
                                    deltaX: bottomPoint.x - 60,
                                    deltaY: bottomPoint.y - 52), .target)

        #expect(controller.dragSession.dropHit?.leafID == consoleLeaf.id)
        #expect(controller.dragSession.dropHit?.edge == .center)

        _ = pointer(MouseButtonEvent(button: .left, x: bottomPoint.x, y: bottomPoint.y, clicks: 1), .up, .target)

        guard case .split(_, .vertical, _, let top, let bottomNode) = controller.root,
              case .split(_, .horizontal, _, let viewportNode, let inspectorNode) = top,
              case .tabs(_, let viewportTabs, _) = viewportNode,
              case .tabs(_, let inspectorTabs, _) = inspectorNode,
              case .tabs(_, let bottomTabs, let activeBottom) = bottomNode else {
            Issue.record("expected hierarchy to merge into the bottom region from the outer bottom edge")
            return
        }

        #expect(viewportTabs.map(\.userKey) == ["viewport"])
        #expect(inspectorTabs.map(\.userKey) == ["inspector"])
        #expect(bottomTabs.map(\.userKey) == ["console", "hierarchy"])
        #expect(activeBottom == hierarchy.id)
    } }

    private func regionOfLeaf(id: DockNodeID,
                              in node: DockLayoutNode,
                              regionByKey: [String: String]) -> String? {
        guard let found = node.find(id) else { return nil }
        switch found {
        case .empty:
            return "center"
        case .tabs(_, let tabs, _):
            guard let first = tabs.first else { return "center" }
            return regionByKey[first.userKey] ?? "center"
        case .split:
            return nil
        }
    }

    @Test("Drag session subscription mirrors motion version into bound state")
    func dragSessionSubscriptionMirrorsVersion() {
        let tab = DockTab(userKey: "a", title: "A")
        let controller = DockController(root: .tabs([tab]))
        var observedVersion: UInt64 = 0
        let binding = Binding<UInt64>(
            get: { observedVersion },
            set: { observedVersion = $0 }
        )

        let token = ControllerSubscription.acquire(session: controller.dragSession,
                                                   tag: ObjectIdentifier(controller),
                                                   bind: binding,
                                                   extraTag: "test")
        defer { controller.dragSession.unsubscribe(token) }

        guard case .tabs(let leafID, _, _) = controller.root else {
            Issue.record("expected tabs leaf at root")
            return
        }

        controller.dragSession.start(tabID: tab.id,
                                     sourceLeafID: leafID,
                                     ghost: DockDragSession.GhostInfo(title: tab.title),
                                     x: 12,
                                     y: 8,
                                     intent: .detachOrSplit)

        #expect(observedVersion == controller.dragSession.version)
    }

    @Test("Leaving the source strip upgrades a reorder drag into full lift immediately")
    func leavingStripUpgradesToFullLift() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tab = DockTab(userKey: "a", title: "A")
        let controller = DockController(root: .tabs([tab]))
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let tabNode = findTabItems(tree.root!)[0]
        let pointer = registry.handlers(for: tabNode).pointer!
        let motion = registry.handlers(for: tabNode).motion!

        _ = pointer(MouseButtonEvent(button: .left, x: 30, y: 28, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 35, y: 33, deltaX: 5, deltaY: 5), .target)

        #expect(controller.dragSession.isActive)
        #expect(controller.dragSession.intent == .detachOrSplit)
    } }

    @Test("A non-draggable tab still activates on click but never starts a drag")
    func nonDraggableTabNeverStartsDrag() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let viewport = DockTab(userKey: "viewport",
                               title: "Viewport",
                               isDraggable: false,
                               isClosable: false)
        let console = DockTab(userKey: "console", title: "Console")
        let leaf = DockLayoutNode.tabs([viewport, console], active: console.id)
        let controller = DockController(root: leaf)
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let tabNode = findTabItems(tree.root!).min(by: { $0.frame.origin.x < $1.frame.origin.x })!
        let pointer = registry.handlers(for: tabNode).pointer!
        let motion = registry.handlers(for: tabNode).motion!

        _ = pointer(MouseButtonEvent(button: .left, x: 30, y: 12, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 140, y: 44, deltaX: 110, deltaY: 32), .target)

        #expect(controller.dragSession.isActive == false)

        _ = pointer(MouseButtonEvent(button: .left, x: 140, y: 44, clicks: 1), .up, .target)

        guard case .tabs(_, _, let active) = controller.root else {
            Issue.record("expected tabs leaf at root")
            return
        }
        #expect(active == viewport.id)
    } }

    @Test("Drop on the source leaf centre is a no-op (cancelled)")
    func dropOnSelfCentreIsNoOp() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tab = DockTab(userKey: "k", title: "K")
        let controller = DockController(root: .tabs([tab]))
        let initial = controller.root
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let tabNode = findTabItems(tree.root!)[0]
        let pointer = registry.handlers(for: tabNode).pointer!
        let motion  = registry.handlers(for: tabNode).motion!

        _ = pointer(MouseButtonEvent(button: .left, x: 30, y: 12, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 50, y: 30, deltaX: 20, deltaY: 18), .target)
        // Move to the centre of the leaf (300, 200 in a 600x400 window).
        _ = motion(MouseMotionEvent(x: 300, y: 200, deltaX: 250, deltaY: 170), .target)
        #expect(controller.dragSession.dropHit == nil)

        _ = pointer(MouseButtonEvent(button: .left, x: 300, y: 200, clicks: 1), .up, .target)
        #expect(controller.root == initial)
    } }

    @Test("DockHitRegistry resolves the smallest leaf containing the pointer")
    func hitRegistrySmallestLeaf() {
        let registry = DockHitRegistry()
        let outer = Node()
        let inner = Node()
        outer.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        inner.frame = CGRect(x: 50, y: 50, width: 60, height: 60)
        outer.addChild(inner)

        let outerID = DockNodeID()
        let innerID = DockNodeID()
        registry.register(nodeID: outerID, node: outer)
        registry.register(nodeID: innerID, node: inner)

        // (75, 75) is inside both — must return inner.
        let hit = registry.leafAt(x: 75, y: 75)
        #expect(hit?.id == innerID)
    }

    @Test("DragSession.resolveDropHit picks edges by 25% margin band")
    func resolveDropEdgeBands() {
        let registry = DockHitRegistry()
        let n = Node()
        n.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        let id = DockNodeID()
        registry.register(nodeID: id, node: n)

        // 25% of min(400, 400) capped at 64 → band = 64.
        let leftHit = DockDragSession.resolveDropHit(x: 10, y: 200, sourceLeafID: nil, registry: registry)
        #expect(leftHit?.edge == .left)
        let rightHit = DockDragSession.resolveDropHit(x: 390, y: 200, sourceLeafID: nil, registry: registry)
        #expect(rightHit?.edge == .right)
        let topHit = DockDragSession.resolveDropHit(x: 200, y: 10, sourceLeafID: nil, registry: registry)
        #expect(topHit?.edge == .top)
        let bottomHit = DockDragSession.resolveDropHit(x: 200, y: 390, sourceLeafID: nil, registry: registry)
        #expect(bottomHit?.edge == .bottom)
        let centerHit = DockDragSession.resolveDropHit(x: 200, y: 200, sourceLeafID: nil, registry: registry)
        #expect(centerHit?.edge == .center)
    }

    @Test("DragSession.resolveDropHit prefers the workspace bottom edge when the root is registered")
    func resolveDropWorkspaceBottomEdge() {
        let registry = DockHitRegistry()
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        let leaf = Node()
        leaf.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        root.addChild(leaf)

        let rootID = DockNodeID()
        let leafID = DockNodeID()
        registry.registerRoot(nodeID: rootID, node: root)
        registry.register(nodeID: leafID, node: leaf)

        let bottomHit = DockDragSession.resolveDropHit(x: 200,
                                                       y: 390,
                                                       sourceLeafID: nil,
                                                       registry: registry)
        #expect(bottomHit?.leafID == rootID)
        #expect(bottomHit?.edge == .bottom)

        let centerHit = DockDragSession.resolveDropHit(x: 200,
                                                       y: 200,
                                                       sourceLeafID: nil,
                                                       registry: registry)
        #expect(centerHit?.leafID == leafID)
        #expect(centerHit?.edge == .center)
    }

    @Test("DragSession.resolveDropHit snaps to workspace guide hotspots before leaf hits")
    func resolveDropWorkspaceGuideHotspots() {
        let registry = DockHitRegistry()
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        let leaf = Node()
        leaf.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        root.addChild(leaf)

        let rootID = DockNodeID()
        let leafID = DockNodeID()
        registry.registerRoot(nodeID: rootID, node: root)
        registry.register(nodeID: leafID, node: leaf)

        let tiles = makeWorkspaceDropGuideTiles(in: UIRect(x: 0, y: 0, width: 400, height: 400))
        #expect(tiles.count == 4)

        for tile in tiles {
            let px = tile.buttonRect.x + tile.buttonRect.width * 0.5
            let py = tile.buttonRect.y + tile.buttonRect.height * 0.5
            let hit = DockDragSession.resolveDropHit(x: px,
                                                     y: py,
                                                     sourceLeafID: nil,
                                                     registry: registry)
            #expect(hit?.leafID == rootID)
            #expect(hit?.edge == tile.edge)
        }
    }

    @Test("Dragging to the workspace bottom recreates a bottom split after the old bottom leaf collapsed")
    func dragToWorkspaceBottomRecreatesBottomSplit() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let viewport = DockTab(userKey: "viewport", title: "Viewport")
        let console = DockTab(userKey: "console", title: "Console")
        let inspector = DockTab(userKey: "inspector", title: "Inspector")
        let controller = DockController(root: .hsplit(fraction: 0.75,
                                                      first: .tabs([viewport, console], active: console.id),
                                                      second: .tabs([inspector])))
        let previousRootID = controller.root.id

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let items = findTabItems(tree.root!)
            .sorted(by: { absoluteFrame(of: $0).origin.x < absoluteFrame(of: $1).origin.x })
        #expect(items.count == 3)
        let consoleNode = items[1]
        let pointer = registry.handlers(for: consoleNode).pointer!
        let motion = registry.handlers(for: consoleNode).motion!

        _ = pointer(MouseButtonEvent(button: .left, x: 150, y: 12, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 170, y: 34, deltaX: 20, deltaY: 22), .target)
        _ = motion(MouseMotionEvent(x: 300, y: 395, deltaX: 130, deltaY: 361), .target)

        #expect(controller.dragSession.dropHit?.leafID == previousRootID)
        #expect(controller.dragSession.dropHit?.edge == .bottom)

        _ = pointer(MouseButtonEvent(button: .left, x: 300, y: 395, clicks: 1), .up, .target)

        guard case .split(_, .vertical, _, let top, let bottom) = controller.root,
              case .split(let topID, .horizontal, _, let left, let right) = top,
              case .tabs(_, let leftTabs, let activeLeft) = left,
              case .tabs(_, let rightTabs, _) = right,
              case .tabs(_, let bottomTabs, let activeBottom) = bottom else {
            Issue.record("expected a recreated bottom split at the workspace root")
            return
        }

        #expect(topID == previousRootID)
        #expect(leftTabs.map(\.id) == [viewport.id])
        #expect(activeLeft == viewport.id)
        #expect(rightTabs.map(\.id) == [inspector.id])
        #expect(bottomTabs.map(\.id) == [console.id])
        #expect(activeBottom == console.id)
    } }

    @Test("Dragging a leaf handle to the workspace bottom recreates a bottom split")
    func leafHandleToWorkspaceBottomRecreatesBottomSplit() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let viewport = DockTab(userKey: "viewport", title: "Viewport")
        let inspector = DockTab(userKey: "inspector", title: "Inspector")
        let controller = DockController(root: .hsplit(fraction: 0.75,
                                                      first: .tabs([viewport]),
                                                      second: .tabs([inspector])))
        let previousRootID = controller.root.id

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let handles = findLeafHandles(tree.root!)
        #expect(handles.count >= 1)
        let handle = handles[0]
        let pointer = registry.handlers(for: handle).pointer!
        let motion = registry.handlers(for: handle).motion!
        let bottomTile = makeWorkspaceDropGuideTiles(in: UIRect(x: 0, y: 0, width: 600, height: 400))
            .first(where: { $0.edge == .bottom })
        #expect(bottomTile != nil)
        guard let bottomTile else { return }
        let targetX = bottomTile.buttonRect.x + bottomTile.buttonRect.width * 0.5
        let targetY = bottomTile.buttonRect.y + bottomTile.buttonRect.height * 0.5

        _ = pointer(MouseButtonEvent(button: .left, x: 10, y: 10, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 30, y: 10, deltaX: 20, deltaY: 0), .target)
        _ = motion(MouseMotionEvent(x: targetX, y: targetY, deltaX: targetX - 30, deltaY: targetY - 10), .target)

        #expect(controller.dragSession.dropHit?.leafID == previousRootID)
        #expect(controller.dragSession.dropHit?.edge == .bottom)

        _ = pointer(MouseButtonEvent(button: .left, x: targetX, y: targetY, clicks: 1), .up, .target)

        guard case .split(let rootID, .vertical, _, let top, let bottom) = controller.root,
              case .tabs(_, let topTabs, _) = top,
              case .tabs(_, let bottomTabs, _) = bottom else {
            Issue.record("expected a recreated bottom split after leaf-handle drop")
            return
        }

        #expect(rootID == previousRootID)
        #expect(topTabs.map(\.id) == [inspector.id])
        #expect(bottomTabs.map(\.id) == [viewport.id])
    } }

    @Test("DragSession.resolveDropHit snaps to guide-tile hotspots before edge bands")
    func resolveDropGuideHotspots() {
        let registry = DockHitRegistry()
        let n = Node()
        n.frame = CGRect(x: 0, y: 0, width: 220, height: 160)
        let id = DockNodeID()
        registry.register(nodeID: id, node: n)

        let tiles = makeDockDropGuideTiles(in: UIRect(x: 0, y: 0, width: 220, height: 160))
        #expect(tiles.count == 5)

        for tile in tiles {
            let px = tile.buttonRect.x + tile.buttonRect.width * 0.5
            let py = tile.buttonRect.y + tile.buttonRect.height * 0.5
            let hit = DockDragSession.resolveDropHit(x: px, y: py, sourceLeafID: nil, registry: registry)
            #expect(hit?.edge == tile.edge)
        }
    }

    @Test("Source leaf centre guide remains a no-op")
    func sourceLeafCenterGuideNoop() {
        let registry = DockHitRegistry()
        let n = Node()
        n.frame = CGRect(x: 0, y: 0, width: 220, height: 160)
        let id = DockNodeID()
        registry.register(nodeID: id, node: n)

        let centerTile = makeDockDropGuideTiles(in: UIRect(x: 0, y: 0, width: 220, height: 160))
            .first(where: { $0.edge == .center })
        #expect(centerTile != nil)
        guard let centerTile else { return }

        let px = centerTile.buttonRect.x + centerTile.buttonRect.width * 0.5
        let py = centerTile.buttonRect.y + centerTile.buttonRect.height * 0.5
        let hit = DockDragSession.resolveDropHit(x: px, y: py, sourceLeafID: id, registry: registry)
        #expect(hit == nil)
    }

    @Test("DragSession.resolveAllowedDropHit respects controller onAllowDrop veto")
    func resolveAllowedDropHitHonorsPolicy() {
        let registry = DockHitRegistry()
        let n = Node()
        n.frame = CGRect(x: 0, y: 0, width: 220, height: 160)
        let id = DockNodeID()
        registry.register(nodeID: id, node: n)

        let controller = DockController(root: .tabs([DockTab(userKey: "viewport", title: "Viewport")]))
        controller.onAllowDrop = { request in
            switch request.target {
            case .splitEdge:
                return false
            case .tabSlot, .replace:
                return true
            }
        }

        let denied = DockDragSession.resolveAllowedDropHit(x: 10,
                                                           y: 80,
                                                           tabID: DockTabID(),
                                                           sourceLeafID: DockNodeID(),
                                                           origin: .mainTreeTab,
                                                           controller: controller,
                                                           registry: registry)
        #expect(denied == nil)

        let allowed = DockDragSession.resolveAllowedDropHit(x: 110,
                                                            y: 80,
                                                            tabID: DockTabID(),
                                                            sourceLeafID: DockNodeID(),
                                                            origin: .mainTreeTab,
                                                            controller: controller,
                                                            registry: registry)
        #expect(allowed?.edge == .center)
    }
}
