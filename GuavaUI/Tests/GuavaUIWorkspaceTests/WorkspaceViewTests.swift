import CoreGraphics
import XCTest
import EngineKernel
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIWorkspace

final class WorkspaceViewTests: XCTestCase {
    func testClickingCollapseButtonCollapsesTrailingWithoutLeavingCenterGap() {
        let rig = makeRig(width: 1000, height: 600)
        let beforeCenter = rig.frame(named: "workspace-region-center")
        let collapseButton = rig.frame(named: "workspace-collapse-trailing")

        rig.click(collapseButton.center)

        XCTAssertEqual(rig.controller.document.groups["trailing"]?.isCollapsed, true)
        XCTAssertNil(rig.optionalFrame(named: "workspace-region-trailing"))

        let afterCenter = rig.frame(named: "workspace-region-center")
        let trailingRail = rig.frame(named: "workspace-rail-trailing")
        XCTAssertGreaterThan(afterCenter.width, beforeCenter.width)
        XCTAssertEqual(trailingRail.width, 40, accuracy: 0.5)
        XCTAssertEqual(trailingRail.maxX, 1000, accuracy: 0.5)
        XCTAssertEqual(afterCenter.maxX, trailingRail.minX, accuracy: 1.0)
    }

    func testBottomRailStaysAboveStatusBarAfterCollapse() {
        let rig = makeRigWithStatusBar(width: 1000, height: 640)

        _ = rig.controller.dispatch(.collapse("bottom"))
        rig.pump()

        let bottomRail = rig.frame(named: "workspace-rail-bottom")
        let center = rig.frame(named: "workspace-region-center")
        let statusBar = rig.frame(named: "editor-status-bar")
        XCTAssertEqual(statusBar.maxY, 640, accuracy: 0.5)
        XCTAssertEqual(bottomRail.minX, center.minX, accuracy: 1.0)
        XCTAssertEqual(bottomRail.maxX, center.maxX, accuracy: 1.0)
        XCTAssertEqual(bottomRail.maxY, statusBar.minY, accuracy: 1.0)
        XCTAssertLessThan(bottomRail.minY, statusBar.minY)
    }

    func testCollapsedRailsKeepBottomRailBetweenWorkspaceEdges() {
        let rig = makeRigWithStatusBar(width: 1000, height: 640)

        _ = rig.controller.dispatch(.collapse("leading"))
        _ = rig.controller.dispatch(.collapse("trailing"))
        _ = rig.controller.dispatch(.collapse("bottom"))
        rig.pump()

        let statusBar = rig.frame(named: "editor-status-bar")
        let leadingRail = rig.frame(named: "workspace-rail-leading")
        let trailingRail = rig.frame(named: "workspace-rail-trailing")
        let bottomRail = rig.frame(named: "workspace-rail-bottom")

        XCTAssertNil(rig.optionalFrame(named: "workspace-region-leading"))
        XCTAssertNil(rig.optionalFrame(named: "workspace-region-trailing"))
        XCTAssertNil(rig.optionalFrame(named: "workspace-region-bottom"))
        XCTAssertEqual(leadingRail.minX, 0, accuracy: 0.5)
        XCTAssertEqual(leadingRail.width, 40, accuracy: 0.5)
        XCTAssertEqual(leadingRail.maxY, statusBar.minY, accuracy: 1.0)
        XCTAssertEqual(trailingRail.maxX, 1000, accuracy: 0.5)
        XCTAssertEqual(trailingRail.width, 40, accuracy: 0.5)
        XCTAssertEqual(trailingRail.maxY, statusBar.minY, accuracy: 1.0)
        XCTAssertEqual(bottomRail.minX, leadingRail.maxX, accuracy: 1.0)
        XCTAssertEqual(bottomRail.maxX, trailingRail.minX, accuracy: 1.0)
        XCTAssertEqual(bottomRail.maxY, statusBar.minY, accuracy: 1.0)
    }

    func testClickingBottomCollapseKeepsRailInCenterBottomSlot() {
        let rig = makeRigWithStatusBar(width: 1000, height: 640)
        let collapseButton = rig.frame(named: "workspace-collapse-bottom")

        rig.click(collapseButton.center)

        XCTAssertEqual(rig.controller.document.groups["bottom"]?.isCollapsed, true)
        XCTAssertNil(rig.optionalFrame(named: "workspace-region-bottom"))
        let center = rig.frame(named: "workspace-region-center")
        let bottomRail = rig.frame(named: "workspace-rail-bottom")
        let statusBar = rig.frame(named: "editor-status-bar")
        XCTAssertEqual(bottomRail.minX, center.minX, accuracy: 1.0)
        XCTAssertEqual(bottomRail.maxX, center.maxX, accuracy: 1.0)
        XCTAssertEqual(bottomRail.maxY, statusBar.minY, accuracy: 1.0)
    }

    func testReinstalledWorkspaceWithSameControllerStillReceivesModelUpdates() {
        let controller = WorkspaceController(document: Self.makeDocument())
        var firstRig: WorkspaceViewRig? = WorkspaceViewRig(controller: controller,
                                                          width: 1000,
                                                          height: 600,
                                                          root: Self.makeWorkspaceRoot(controller: controller))
        XCTAssertNotNil(firstRig?.optionalFrame(named: "workspace-region-bottom"))
        firstRig = nil

        let secondRig = WorkspaceViewRig(controller: controller,
                                         width: 1000,
                                         height: 600,
                                         root: Self.makeWorkspaceRoot(controller: controller))

        _ = controller.dispatch(.collapse("bottom"))
        secondRig.pump()

        XCTAssertNil(secondRig.optionalFrame(named: "workspace-region-bottom"))
        XCTAssertNotNil(secondRig.optionalFrame(named: "workspace-rail-bottom"))
    }

    func testCenterGroupDoesNotExposeCollapseAffordance() {
        let rig = makeRig(width: 1000, height: 600)

        XCTAssertNil(rig.optionalFrame(named: "workspace-collapse-center"))
        let result = rig.controller.dispatch(.collapse("center"))

        XCTAssertFalse(result.didChange)
        XCTAssertEqual(rig.controller.document.groups["center"]?.isCollapsed, false)

        _ = rig.controller.dispatch(.movePanel("inspector",
                                               to: WorkspaceTarget(region: .center,
                                                                   groupID: "center",
                                                                   zone: .tabGroup)))
        rig.pump()

        XCTAssertNil(rig.optionalFrame(named: "workspace-collapse-center"))
    }

    private func makeRig(width: Float,
                         height: Float) -> WorkspaceViewRig {
        let controller = WorkspaceController(document: Self.makeDocument())
        return WorkspaceViewRig(controller: controller,
                                width: width,
                                height: height,
                                root: Self.makeWorkspaceRoot(controller: controller))
    }

    private func makeRigWithStatusBar(width: Float,
                                      height: Float) -> WorkspaceViewRig {
        let controller = WorkspaceController(document: Self.makeDocument())
        return WorkspaceViewRig(controller: controller,
                                width: width,
                                height: height,
                                root: AnyView(
                                    Box(direction: .column, alignItems: .stretch, spacing: 0) {
                                        WorkspaceView(controller: controller) { panelID in
                                            AnyView(Box { Text(panelID.rawValue) }
                                                .debugName("content-\(panelID.rawValue)"))
                                        }
                                        .flex()
                                        Box { EmptyView() }
                                            .frame(height: 24)
                                            .debugName("editor-status-bar")
                                    }
                                    .frame(width: width, height: height)
                                ))
    }

    private static func makeDocument() -> WorkspaceDocument {
        WorkspaceDocument(
            panels: [
                "hierarchy": WorkspacePanel(id: "hierarchy", title: "Hierarchy"),
                "viewport": WorkspacePanel(id: "viewport",
                                           title: "Viewport",
                                           isClosable: false,
                                           isCollapsible: false),
                "inspector": WorkspacePanel(id: "inspector", title: "Inspector"),
                "console": WorkspacePanel(id: "console", title: "Console"),
            ],
            groups: [
                "leading": WorkspaceTabGroup(id: "leading", panels: ["hierarchy"], activePanelID: "hierarchy"),
                "center": WorkspaceTabGroup(id: "center", panels: ["viewport"], activePanelID: "viewport"),
                "trailing": WorkspaceTabGroup(id: "trailing", panels: ["inspector"], activePanelID: "inspector"),
                "bottom": WorkspaceTabGroup(id: "bottom", panels: ["console"], activePanelID: "console"),
            ],
            regions: [
                WorkspaceRegion(id: .leading, groupIDs: ["leading"]),
                WorkspaceRegion(id: .center, groupIDs: ["center"]),
                WorkspaceRegion(id: .trailing, groupIDs: ["trailing"]),
                WorkspaceRegion(id: .bottom, groupIDs: ["bottom"]),
            ],
            splitFractions: WorkspaceSplitFractions(leading: 0.22,
                                                    centerTrailing: 0.78,
                                                    topBottom: 0.74)
        )
    }

    private static func makeWorkspaceRoot(controller: WorkspaceController) -> AnyView {
        AnyView(WorkspaceView(controller: controller) { panelID in
            AnyView(Box { Text(panelID.rawValue) }
                .debugName("content-\(panelID.rawValue)"))
        })
    }
}

private final class WorkspaceViewRig {
    let controller: WorkspaceController
    let width: Float
    let height: Float
    let tree = NodeTree()
    let recomposer = Recomposer()
    let registry = InteractionRegistry()
    let capture = PointerCapture()
    let focus = FocusChain()
    let graph: ViewGraph
    let dispatcher: EventDispatcher

    init(controller: WorkspaceController,
         width: Float,
         height: Float,
         root: AnyView) {
        self.controller = controller
        self.width = width
        self.height = height
        graph = ViewGraph(tree: tree, recomposer: recomposer)
        dispatcher = EventDispatcher(tree: tree,
                                     interactions: registry,
                                     capture: capture,
                                     focusChain: focus)

        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = capture
        FocusChainHolder.current = focus
        graph.install(root: root)
        dispatcher.inputScene = graph.inputScene
        graph.computeLayout(width: width, height: height)
    }

    deinit {
        if InteractionRegistryHolder.current === registry {
            InteractionRegistryHolder.current = nil
        }
        if PointerCaptureHolder.current === capture {
            PointerCaptureHolder.current = nil
        }
        if FocusChainHolder.current === focus {
            FocusChainHolder.current = nil
        }
    }

    func click(_ point: CGPoint) {
        dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left,
                                                              x: Float(point.x),
                                                              y: Float(point.y),
                                                              clicks: 1)))
        pump()
        dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left,
                                                            x: Float(point.x),
                                                            y: Float(point.y),
                                                            clicks: 1)))
        pump()
    }

    func pump() {
        recomposer.commitAll()
        graph.computeLayout(width: width, height: height)
    }

    func frame(named debugName: String) -> CGRect {
        guard let frame = optionalFrame(named: debugName) else {
            XCTFail("missing frame named \(debugName)")
            return .zero
        }
        return frame
    }

    func optionalFrame(named debugName: String) -> CGRect? {
        graph.layoutSnapshot()
            .first { $0.debugName == debugName }?
            .absoluteFrame
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
