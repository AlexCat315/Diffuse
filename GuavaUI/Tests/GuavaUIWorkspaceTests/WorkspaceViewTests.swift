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
        let leadingRestore = rig.frame(named: "workspace-restore-leading")
        let trailingRestore = rig.frame(named: "workspace-restore-trailing")
        let bottomRestore = rig.frame(named: "workspace-restore-bottom")

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
        XCTAssertGreaterThanOrEqual(leadingRestore.minX, leadingRail.minX)
        XCTAssertLessThanOrEqual(leadingRestore.maxX, leadingRail.maxX)
        XCTAssertGreaterThanOrEqual(trailingRestore.minX, trailingRail.minX)
        XCTAssertLessThanOrEqual(trailingRestore.maxX, trailingRail.maxX)
        XCTAssertGreaterThanOrEqual(bottomRestore.minX, bottomRail.minX)
        XCTAssertLessThanOrEqual(bottomRestore.maxX, bottomRail.maxX)
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

    func testClickingLeftRightThenBottomCanCollapseAndRestoreInPlace() {
        let rig = makeRigWithStatusBar(width: 1000, height: 640)

        rig.click(rig.frame(named: "workspace-collapse-leading").center)
        rig.click(rig.frame(named: "workspace-collapse-trailing").center)
        rig.click(rig.frame(named: "workspace-collapse-bottom").center)

        XCTAssertEqual(rig.controller.document.groups["leading"]?.isCollapsed, true)
        XCTAssertEqual(rig.controller.document.groups["trailing"]?.isCollapsed, true)
        XCTAssertEqual(rig.controller.document.groups["bottom"]?.isCollapsed, true)
        XCTAssertNil(rig.optionalFrame(named: "workspace-region-leading"))
        XCTAssertNil(rig.optionalFrame(named: "workspace-region-trailing"))
        XCTAssertNil(rig.optionalFrame(named: "workspace-region-bottom"))

        let collapsedStatusBar = rig.frame(named: "editor-status-bar")
        let leadingRail = rig.frame(named: "workspace-rail-leading")
        let trailingRail = rig.frame(named: "workspace-rail-trailing")
        let bottomRail = rig.frame(named: "workspace-rail-bottom")
        XCTAssertEqual(leadingRail.minX, 0, accuracy: 0.5)
        XCTAssertEqual(trailingRail.maxX, 1000, accuracy: 0.5)
        XCTAssertEqual(bottomRail.minX, leadingRail.maxX, accuracy: 1.0)
        XCTAssertEqual(bottomRail.maxX, trailingRail.minX, accuracy: 1.0)
        XCTAssertEqual(bottomRail.maxY, collapsedStatusBar.minY, accuracy: 1.0)

        rig.click(rig.frame(named: "workspace-restore-leading").center)
        rig.click(rig.frame(named: "workspace-restore-trailing").center)
        rig.click(rig.frame(named: "workspace-restore-bottom").center)

        let leadingRegion = rig.frame(named: "workspace-region-leading")
        let centerRegion = rig.frame(named: "workspace-region-center")
        let leadingSplit = rig.frame(named: "workspace-split-leading")
        let trailingRegion = rig.frame(named: "workspace-region-trailing")
        let trailingSplit = rig.frame(named: "workspace-split-centerTrailing")
        let bottomRegion = rig.frame(named: "workspace-region-bottom")
        let restoredStatusBar = rig.frame(named: "editor-status-bar")

        XCTAssertNil(rig.optionalFrame(named: "workspace-rail-leading"))
        XCTAssertNil(rig.optionalFrame(named: "workspace-rail-trailing"))
        XCTAssertNil(rig.optionalFrame(named: "workspace-rail-bottom"))
        XCTAssertEqual(leadingRegion.minX, 0, accuracy: 0.5)
        XCTAssertEqual(leadingRegion.maxX, leadingSplit.minX, accuracy: 1.0)
        XCTAssertEqual(leadingSplit.maxX, centerRegion.minX, accuracy: 1.0)
        XCTAssertEqual(centerRegion.maxX, trailingSplit.minX, accuracy: 1.0)
        XCTAssertEqual(trailingSplit.maxX, trailingRegion.minX, accuracy: 1.0)
        XCTAssertEqual(bottomRegion.minX, centerRegion.minX, accuracy: 1.0)
        XCTAssertEqual(bottomRegion.maxX, centerRegion.maxX, accuracy: 1.0)
        XCTAssertEqual(restoredStatusBar.maxY, 640, accuracy: 0.5)
        XCTAssertEqual(bottomRegion.maxY, restoredStatusBar.minY, accuracy: 1.0)
    }

    func testDraggingTabIntoAnotherGroupMovesPanel() {
        let rig = makeRigWithStatusBar(width: 1000, height: 640)

        let source = rig.frame(named: "workspace-tab-hierarchy").center
        let target = rig.frame(named: "workspace-group-trailing").center
        rig.drag(from: source, to: target)

        XCTAssertFalse(rig.controller.document.groups.values.contains { group in
            group.id != "trailing" && group.panels.contains("hierarchy")
        })
        XCTAssertEqual(rig.controller.document.region(.leading).groupIDs, [])
        XCTAssertEqual(rig.controller.document.groups["trailing"]?.panels.contains("hierarchy"), true)
        XCTAssertEqual(rig.controller.document.groups["trailing"]?.activePanelID, "hierarchy")
        let hierarchyPanel = rig.frame(named: "workspace-panel-hierarchy")
        let trailingRegion = rig.frame(named: "workspace-region-trailing")
        XCTAssertGreaterThanOrEqual(hierarchyPanel.minX, trailingRegion.minX)
        XCTAssertLessThanOrEqual(hierarchyPanel.maxX, trailingRegion.maxX)
        XCTAssertEqual(rig.frame(named: "workspace-region-trailing").maxX, 1000, accuracy: 0.5)
    }

    func testDraggingTabWithinSameGroupReordersPanel() {
        let controller = WorkspaceController(document: Self.makeMultiTabDocument())
        let rig = WorkspaceViewRig(controller: controller,
                                   width: 1000,
                                   height: 640,
                                   root: Self.makeWorkspaceRoot(controller: controller))

        let source = rig.frame(named: "workspace-tab-console").center
        let assets = rig.frame(named: "workspace-tab-assets")
        let target = CGPoint(x: assets.maxX + 8, y: assets.midY)
        rig.drag(from: source, to: target)

        XCTAssertEqual(rig.controller.document.groups["bottom"]?.panels, ["assets", "console"])
        XCTAssertEqual(rig.controller.document.groups["bottom"]?.activePanelID, "console")
    }

    func testClickingTabCloseButtonRemovesPanelWithoutMovingRegions() {
        let controller = WorkspaceController(document: Self.makeMultiTabDocument())
        let rig = WorkspaceViewRig(controller: controller,
                                   width: 1000,
                                   height: 640,
                                   root: Self.makeWorkspaceRoot(controller: controller))

        rig.click(rig.frame(named: "workspace-tab-close-console").center)

        XCTAssertEqual(rig.controller.document.groups["bottom"]?.panels, ["assets"])
        XCTAssertEqual(rig.controller.document.groups["bottom"]?.activePanelID, "assets")
        XCTAssertEqual(rig.controller.document.region(.bottom).groupIDs, ["bottom"])
        XCTAssertNil(rig.optionalFrame(named: "workspace-tab-console"))
        XCTAssertNotNil(rig.optionalFrame(named: "workspace-region-bottom"))
    }

    func testDraggingWorkspaceSplitDividersUpdatesFractions() {
        let rig = makeRigWithStatusBar(width: 1000, height: 640)

        let leadingBefore = rig.controller.document.splitFractions.leading
        let leadingSplit = rig.frame(named: "workspace-split-leading")
        rig.drag(from: leadingSplit.center,
                 to: CGPoint(x: leadingSplit.center.x + 70, y: leadingSplit.center.y))
        XCTAssertGreaterThan(rig.controller.document.splitFractions.leading, leadingBefore)

        let centerTrailingBefore = rig.controller.document.splitFractions.centerTrailing
        let centerTrailingSplit = rig.frame(named: "workspace-split-centerTrailing")
        rig.drag(from: centerTrailingSplit.center,
                 to: CGPoint(x: centerTrailingSplit.center.x - 60, y: centerTrailingSplit.center.y))
        XCTAssertLessThan(rig.controller.document.splitFractions.centerTrailing, centerTrailingBefore)

        let topBottomBefore = rig.controller.document.splitFractions.topBottom
        let bottomSplit = rig.frame(named: "workspace-split-topBottom")
        rig.drag(from: bottomSplit.center,
                 to: CGPoint(x: bottomSplit.center.x, y: bottomSplit.center.y - 50))
        XCTAssertLessThan(rig.controller.document.splitFractions.topBottom, topBottomBefore)
    }

    func testDraggingTabToGroupEdgeCreatesAdjacentGroup() {
        let rig = makeRigWithStatusBar(width: 1000, height: 640)

        let source = rig.frame(named: "workspace-tab-hierarchy").center
        let trailingGroup = rig.frame(named: "workspace-group-trailing")
        let target = CGPoint(x: trailingGroup.minX + 8, y: trailingGroup.midY)
        rig.drag(from: source, to: target)

        let trailingRegion = rig.controller.document.region(.trailing)
        XCTAssertEqual(trailingRegion.groupIDs.count, 2)
        let movedGroupID = trailingRegion.groupIDs.first
        XCTAssertNotEqual(movedGroupID, "trailing")
        XCTAssertEqual(rig.controller.document.groups[movedGroupID ?? ""]?.panels, ["hierarchy"])
        XCTAssertEqual(rig.controller.document.groups[movedGroupID ?? ""]?.activePanelID, "hierarchy")
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

    private static func makeMultiTabDocument() -> WorkspaceDocument {
        var document = makeDocument()
        document.panels["assets"] = WorkspacePanel(id: "assets", title: "Assets")
        document.groups["bottom"]?.panels = ["console", "assets"]
        document.groups["bottom"]?.activePanelID = "console"
        return document
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

    func drag(from start: CGPoint, to end: CGPoint) {
        dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left,
                                                              x: Float(start.x),
                                                              y: Float(start.y),
                                                              clicks: 1)))
        pump()
        let mid = CGPoint(x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5)
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: Float(mid.x),
                                                          y: Float(mid.y),
                                                          deltaX: Float(mid.x - start.x),
                                                          deltaY: Float(mid.y - start.y))))
        pump()
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: Float(end.x),
                                                          y: Float(end.y),
                                                          deltaX: Float(end.x - mid.x),
                                                          deltaY: Float(end.y - mid.y))))
        pump()
        dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left,
                                                            x: Float(end.x),
                                                            y: Float(end.y),
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
