#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import XCTest
import EngineKernel
import GuavaUICompose
import GuavaUIRuntime
@testable import GuavaUIWorkspace

final class WorkspaceViewTests: XCTestCase {
    func testInternalDockSplitResizesWithPointerAndKeyboardAndRestores() throws {
        let rig = makeRigWithStatusBar(width: 1000, height: 640)
        _ = rig.controller.dispatch(.movePanel("hierarchy", to: .split(slot: .center, anchorGroupID: "center", edge: .trailing)))
        for _ in 0..<4 { rig.pump() }
        let saved = try JSONEncoder().encode(rig.controller.document)
        guard case let .split(_, original, first, second) = rig.controller.document.slot(.center).layout,
              let firstID = first.leafGroupIDs.first, let secondID = second.leafGroupIDs.first else {
            return XCTFail("Move must create a dock split")
        }
        let split = rig.node(named: "workspace-layout-split-center-\(firstID.rawValue)-\(secondID.rawValue)")
        func handle(in node: Node) -> Node? {
            if node.isFocusable, node.cursor == .resizeHorizontal { return node }
            return node.children.lazy.compactMap { handle(in: $0) }.first
        }
        let divider = try XCTUnwrap(handle(in: split))
        let point = divider.absoluteFrame.center
        rig.drag(from: point, to: CGPoint(x: point.x + 40, y: point.y))
        guard case let .split(_, dragged, _, _) = rig.controller.document.slot(.center).layout else {
            return XCTFail("Drag must preserve split")
        }
        XCTAssertGreaterThan(dragged, original)
        rig.focus.focus(divider)
        rig.dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.arrowLeft, keycode: 0, modifiers: [], isRepeat: false)))
        for _ in 0..<4 { rig.pump() }
        guard case let .split(_, keyed, _, _) = rig.controller.document.slot(.center).layout else {
            return XCTFail("Keyboard must preserve split")
        }
        XCTAssertLessThan(keyed, dragged)
        rig.controller.replace(try JSONDecoder().decode(WorkspaceDocument.self, from: saved))
        for _ in 0..<4 { rig.pump() }
        guard case let .split(_, restored, _, _) = rig.controller.document.slot(.center).layout else {
            return XCTFail("Restore must preserve split")
        }
        XCTAssertEqual(restored, original)
    }

    func testClosingLastPanelAnimatesTheVacatedRegionAndKeepsTheDocumentClosed() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let controller = WorkspaceController(document: Self.makeDocument())
            let root = AnyView(Self.makeWorkspaceRoot(controller: controller)
                .workspaceTheme(WorkspaceTheme(animatesLayout: true)))
            let rig = WorkspaceViewRig(controller: controller, width: 1000, height: 600, root: root)
            let inspector = rig.node(named: "content-inspector")
            _ = controller.dispatch(.closePanel("inspector")); rig.pump()
            XCTAssertNil(controller.document.groupContaining(panelID: "inspector"))
            XCTAssertTrue(rig.optionalNode(named: "content-inspector") === inspector)
            XCTAssertFalse(inspector.acceptsSubtreeInput)
            scheduler.tick(deltaTime: 1); rig.pump()
            XCTAssertNil(rig.optionalNode(named: "content-inspector"))
            XCTAssertEqual(rig.frame(named: "workspace-region-center").maxX, 1000, accuracy: 1)
            XCTAssertEqual(scheduler.activeCount, 0)
        }
    }

    func testAnimatedCollapseRetainsPaintDisablesInputAndReclaimsSpace() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let controller = WorkspaceController(document: Self.makeDocument())
            let root = AnyView(Self.makeWorkspaceRoot(controller: controller)
                .workspaceTheme(WorkspaceTheme(animatesLayout: true)))
            let rig = WorkspaceViewRig(controller: controller, width: 1000, height: 600, root: root)
            let inspector = rig.node(named: "content-inspector")
            let initial = rig.frame(named: "workspace-region-trailing").width
            let center = rig.frame(named: "workspace-region-center").width
            _ = controller.dispatch(.collapse("trailing"))
            rig.pump()
            XCTAssertTrue(rig.optionalNode(named: "content-inspector") === inspector)
            XCTAssertFalse(inspector.acceptsSubtreeInput)
            XCTAssertEqual(rig.frame(named: "workspace-region-trailing").width, initial, accuracy: 1)
            scheduler.tick(deltaTime: 0.08)
            rig.pump()
            let intermediate = rig.frame(named: "workspace-region-trailing").width
            XCTAssertGreaterThan(intermediate, 0)
            XCTAssertLessThan(intermediate, initial)
            XCTAssertGreaterThan(rig.frame(named: "workspace-region-center").width, center)
            scheduler.tick(deltaTime: 1)
            rig.pump()
            XCTAssertNil(rig.optionalNode(named: "content-inspector"))
            let rail = rig.frame(named: "workspace-rail-trailing")
            XCTAssertEqual(rig.frame(named: "workspace-region-center").maxX, rail.minX, accuracy: 1)
            XCTAssertEqual(scheduler.activeCount, 0)
        }
    }

    func testAnimatedCollapseReversalKeepsTheSamePanelAndRestoresLayout() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let controller = WorkspaceController(document: Self.makeDocument())
            let root = AnyView(Self.makeWorkspaceRoot(controller: controller)
                .workspaceTheme(WorkspaceTheme(animatesLayout: true)))
            let rig = WorkspaceViewRig(controller: controller, width: 1000, height: 600, root: root)
            let inspector = rig.node(named: "content-inspector")
            let initial = rig.frame(named: "workspace-region-trailing")
            _ = controller.dispatch(.collapse("trailing")); rig.pump()
            scheduler.tick(deltaTime: 0.06); rig.pump()
            let current = rig.frame(named: "workspace-region-trailing")
            _ = controller.dispatch(.expand("trailing")); rig.pump()
            XCTAssertEqual(rig.frame(named: "workspace-region-trailing").width, current.width, accuracy: 1)
            scheduler.tick(deltaTime: 1); rig.pump()
            XCTAssertTrue(rig.optionalNode(named: "content-inspector") === inspector)
            XCTAssertTrue(inspector.acceptsSubtreeInput)
            XCTAssertEqual(rig.frame(named: "workspace-region-trailing").width, initial.width, accuracy: 1)
            XCTAssertNil(rig.optionalNode(named: "workspace-rail-trailing"))
            XCTAssertEqual(scheduler.activeCount, 0)
        }
    }

    func testCollapsedRailActivatesTheClickedPanel() {
        let controller = WorkspaceController(document: Self.makeMultiTabDocument())
        let rig = WorkspaceViewRig(controller: controller, width: 1000, height: 600,
                                   root: Self.makeWorkspaceRoot(controller: controller))
        _ = controller.dispatch(.collapse("bottom"))
        rig.pump()
        rig.click(rig.frame(named: "workspace-restore-bottom-assets").center)
        XCTAssertEqual(controller.document.groups["bottom"]?.activePanelID, "assets")
        XCTAssertEqual(controller.document.groups["bottom"]?.isCollapsed, false)
        XCTAssertNotNil(rig.optionalFrame(named: "content-assets"))
        _ = controller.dispatch(.collapse("bottom"))
        rig.pump()
        rig.click(rig.frame(named: "workspace-restore-bottom-console").center)
        XCTAssertEqual(controller.document.groups["bottom"]?.activePanelID, "console")
        XCTAssertNotNil(rig.optionalFrame(named: "content-console"))
    }

    func testWorkspaceThemeControlsTabBarHeight() {
        let controller = WorkspaceController(document: Self.makeDocument())
        let root = AnyView(Self.makeWorkspaceRoot(controller: controller)
            .workspaceTheme(WorkspaceTheme(tabBarHeight: 38)))
        let rig = WorkspaceViewRig(controller: controller, width: 1000, height: 600, root: root)
        let group = rig.frame(named: "workspace-group-center")
        let content = rig.frame(named: "workspace-panel-viewport")
        XCTAssertEqual(content.minY - group.minY, 38, accuracy: 0.5)
    }

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
        let statusBar = rig.frame(named: "editor-status-bar")
        let chrome = rig.frame(named: "workspace-chrome-chrome.bottom.rail")
        let center = rig.frame(named: "workspace-region-center")
        XCTAssertEqual(statusBar.maxY, 640, accuracy: 0.5)
        XCTAssertEqual(bottomRail.minX, center.minX, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxX, center.maxX, accuracy: 0.5)
        XCTAssertEqual(chrome.height, 40, accuracy: 0.5)
        XCTAssertEqual(chrome.minX, center.minX, accuracy: 0.5)
        XCTAssertEqual(chrome.maxX, center.maxX, accuracy: 0.5)
        XCTAssertEqual(bottomRail.minY, chrome.minY, accuracy: 1.0)
        XCTAssertEqual(bottomRail.maxY, statusBar.minY, accuracy: 1.0)
        XCTAssertLessThan(bottomRail.minY, statusBar.minY)
    }

    func testTopSlotUsesPreferredContentHeightAndBottomChromeRemainsFixed() {
        var document = Self.makeDocument()
        document.panels["timeline"] = WorkspacePanel(id: "timeline", title: "Timeline",
            sizing: .init(height: .init(preferred: 126)))
        document.groups["timeline"] = WorkspaceTabGroup(id: "timeline",
                                                        panels: ["timeline"],
                                                        activePanelID: "timeline")
        document.slots[.top] = WorkspaceSlot(id: .top,
                                             kind: .content,
                                             layout: .group("timeline"))
        let toolbarID = WorkspaceSlotID(rawValue: "chrome.bottom.toolbar")
        document.slots[toolbarID] = WorkspaceSlot(id: toolbarID,
                                                  kind: .chrome(edge: .bottom, size: .fixed(28)),
                                                  layout: .group("timeline"))
        let controller = WorkspaceController(document: document)
        let rig = WorkspaceViewRig(controller: controller,
                                   width: 1000,
                                   height: 640,
                                   root: Self.makeWorkspaceRoot(controller: controller))

        for _ in 0..<4 { rig.pump() }
        let topSlot = rig.frame(named: "workspace-region-top")
        let bottomChrome = rig.frame(named: "workspace-chrome-\(toolbarID.rawValue)")
        XCTAssertEqual(topSlot.minY, 0, accuracy: 0.5)
        XCTAssertEqual(topSlot.height, 160, accuracy: 0.5)
        XCTAssertEqual(bottomChrome.height, 28, accuracy: 0.5)
        XCTAssertEqual(bottomChrome.maxY, 640, accuracy: 0.5)
    }

    func testCollapsedRailsKeepBottomRailBetweenSideRails() {
        let rig = makeRigWithStatusBar(width: 1000, height: 640)

        _ = rig.controller.dispatch(.collapse("leading"))
        _ = rig.controller.dispatch(.collapse("trailing"))
        _ = rig.controller.dispatch(.collapse("bottom"))
        rig.pump()

        let statusBar = rig.frame(named: "editor-status-bar")
        let leadingRail = rig.frame(named: "workspace-rail-leading")
        let trailingRail = rig.frame(named: "workspace-rail-trailing")
        let bottomRail = rig.frame(named: "workspace-rail-bottom")
        let centerColumn = rig.frame(named: "workspace-center-column")
        let leadingRestore = rig.frame(named: "workspace-restore-leading-hierarchy")
        let trailingRestore = rig.frame(named: "workspace-restore-trailing-inspector")
        let bottomRestore = rig.frame(named: "workspace-restore-bottom-console")

        XCTAssertNil(rig.optionalFrame(named: "workspace-region-leading"))
        XCTAssertNil(rig.optionalFrame(named: "workspace-region-trailing"))
        XCTAssertNil(rig.optionalFrame(named: "workspace-region-bottom"))
        XCTAssertEqual(leadingRail.minX, 0, accuracy: 0.5)
        XCTAssertEqual(leadingRail.width, 40, accuracy: 0.5)
        XCTAssertEqual(trailingRail.maxX, 1000, accuracy: 0.5)
        XCTAssertEqual(trailingRail.width, 40, accuracy: 0.5)
        XCTAssertEqual(bottomRail.minX, centerColumn.minX, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxX, centerColumn.maxX, accuracy: 0.5)
        XCTAssertEqual(leadingRail.maxX, bottomRail.minX, accuracy: 1.0)
        XCTAssertEqual(bottomRail.maxX, trailingRail.minX, accuracy: 1.0)
        XCTAssertEqual(bottomRail.maxY, statusBar.minY, accuracy: 1.0)
        XCTAssertGreaterThanOrEqual(leadingRestore.minX, leadingRail.minX)
        XCTAssertLessThanOrEqual(leadingRestore.maxX, leadingRail.maxX)
        XCTAssertGreaterThanOrEqual(trailingRestore.minX, trailingRail.minX)
        XCTAssertLessThanOrEqual(trailingRestore.maxX, trailingRail.maxX)
        XCTAssertGreaterThanOrEqual(bottomRestore.minX, bottomRail.minX)
        XCTAssertLessThanOrEqual(bottomRestore.maxX, bottomRail.maxX)
    }

    func testClickingBottomCollapseKeepsRailOnBottomEdge() {
        let rig = makeRigWithStatusBar(width: 1000, height: 640)
        let collapseButton = rig.frame(named: "workspace-collapse-bottom")

        rig.click(collapseButton.center)

        XCTAssertEqual(rig.controller.document.groups["bottom"]?.isCollapsed, true)
        XCTAssertNil(rig.optionalFrame(named: "workspace-region-bottom"))
        XCTAssertNotNil(rig.optionalFrame(named: "workspace-region-leading"))
        XCTAssertNotNil(rig.optionalFrame(named: "workspace-region-trailing"))
        let bottomRail = rig.frame(named: "workspace-rail-bottom")
        let chrome = rig.frame(named: "workspace-chrome-chrome.bottom.rail")
        let statusBar = rig.frame(named: "editor-status-bar")
        let center = rig.frame(named: "workspace-region-center")
        XCTAssertNil(rig.optionalFrame(named: "workspace-bottom-slot"))
        XCTAssertEqual(chrome.height, 40, accuracy: 0.5)
        XCTAssertEqual(bottomRail.height, 40, accuracy: 0.5)
        XCTAssertEqual(bottomRail.minX, center.minX, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxX, center.maxX, accuracy: 0.5)
        XCTAssertEqual(chrome.minX, center.minX, accuracy: 0.5)
        XCTAssertEqual(chrome.maxX, center.maxX, accuracy: 0.5)
        XCTAssertEqual(bottomRail.minY, chrome.minY, accuracy: 1.0)
        XCTAssertEqual(bottomRail.maxY, statusBar.minY, accuracy: 1.0)
    }

    func testBottomRailRemainsAllocatedWhenBottomCollapsesBeforeSideRails() {
        let rig = makeRigWithStatusBar(width: 1998, height: 1246)

        rig.click(rig.frame(named: "workspace-collapse-bottom").center)

        let bottomRail = rig.frame(named: "workspace-rail-bottom")
        let chrome = rig.frame(named: "workspace-chrome-chrome.bottom.rail")
        let statusBar = rig.frame(named: "editor-status-bar")
        let center = rig.frame(named: "workspace-region-center")
        XCTAssertNil(rig.optionalFrame(named: "workspace-bottom-slot"))
        XCTAssertEqual(chrome.height, 40, accuracy: 0.5)
        XCTAssertEqual(bottomRail.height, 40, accuracy: 0.5)
        XCTAssertEqual(bottomRail.minX, center.minX, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxX, center.maxX, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxY, statusBar.minY, accuracy: 1.0)
        XCTAssertNotNil(rig.optionalFrame(named: "workspace-region-leading"))
        XCTAssertNotNil(rig.optionalFrame(named: "workspace-region-trailing"))

        let beforeSideCollapseRail = bottomRail
        rig.click(rig.frame(named: "workspace-collapse-leading").center)

        let afterSideCollapseRail = rig.frame(named: "workspace-rail-bottom")
        XCTAssertEqual(afterSideCollapseRail.height, beforeSideCollapseRail.height, accuracy: 0.5)
        XCTAssertEqual(afterSideCollapseRail.maxY, statusBar.minY, accuracy: 1.0)
    }

    func testBottomRailStaysVisibleWhenExpandedSidePanelsHaveTallContent() {
        let controller = WorkspaceController(document: Self.makeDocument())
        let root = AnyView(
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                WorkspaceView(controller: controller) { panelID in
                    AnyView(Box(direction: .column, alignItems: .stretch, spacing: 0) {
                        Text(panelID.rawValue)
                        Box { EmptyView() }
                            .frame(height: 900)
                            .background(.surfaceVariant)
                    }
                    .debugName("tall-content-\(panelID.rawValue)"))
                }
                .flex()
                .frame(minWidth: 0, minHeight: 0)
                Box { EmptyView() }
                    .frame(height: 24)
                    .debugName("editor-status-bar")
            }
            .frame(width: 1280, height: 720)
        )
        let rig = WorkspaceViewRig(controller: controller,
                                   width: 1280,
                                   height: 720,
                                   root: root)

        rig.click(rig.frame(named: "workspace-collapse-bottom").center)

        let workspace = rig.frame(named: "workspace")
        let statusBar = rig.frame(named: "editor-status-bar")
        let bottomRail = rig.frame(named: "workspace-rail-bottom")
        let bottomRestore = rig.frame(named: "workspace-restore-bottom-console")
        let center = rig.frame(named: "workspace-region-center")
        XCTAssertEqual(workspace.maxY, statusBar.minY, accuracy: 1.0)
        XCTAssertEqual(bottomRail.minX, center.minX, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxX, center.maxX, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxY, statusBar.minY, accuracy: 1.0)
        XCTAssertLessThanOrEqual(bottomRail.maxY, 720.5)
        XCTAssertLessThan(bottomRail.minY, 720)
        XCTAssertGreaterThanOrEqual(bottomRestore.minX, bottomRail.minX)
        XCTAssertLessThanOrEqual(bottomRestore.maxX, bottomRail.maxX)
        XCTAssertNotNil(rig.optionalFrame(named: "workspace-region-leading"))
        XCTAssertNotNil(rig.optionalFrame(named: "workspace-region-trailing"))
    }

    func testBottomRailRendersForLegacyDocumentWithoutChromeRailSlot() {
        var document = Self.makeDocument()
        document.slots.removeValue(forKey: .chromeBottomRail)
        let controller = WorkspaceController(document: document)
        let rig = WorkspaceViewRig(controller: controller,
                                   width: 1000,
                                   height: 640,
                                   root: Self.makeWorkspaceRootWithStatusBar(controller: controller,
                                                                             width: 1000,
                                                                             height: 640))

        rig.click(rig.frame(named: "workspace-collapse-bottom").center)

        let bottomRail = rig.frame(named: "workspace-rail-bottom")
        let chrome = rig.frame(named: "workspace-chrome-\(WorkspaceSlotID.chromeBottomRail.rawValue)")
        let statusBar = rig.frame(named: "editor-status-bar")
        let center = rig.frame(named: "workspace-region-center")
        XCTAssertNil(rig.optionalFrame(named: "workspace-region-bottom"))
        XCTAssertNil(rig.controller.document.slots[.chromeBottomRail])
        XCTAssertEqual(chrome.height, 40, accuracy: 0.5)
        XCTAssertEqual(bottomRail.minX, center.minX, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxX, center.maxX, accuracy: 0.5)
        XCTAssertEqual(chrome.minX, center.minX, accuracy: 0.5)
        XCTAssertEqual(chrome.maxX, center.maxX, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxY, statusBar.minY, accuracy: 1.0)
        XCTAssertNotNil(rig.optionalFrame(named: "workspace-region-leading"))
        XCTAssertNotNil(rig.optionalFrame(named: "workspace-region-trailing"))
    }

    func testBottomRailUsesCollapsedEdgeWhenPersistedSlotIDIsStale() {
        var document = Self.makeDocument()
        document.groups["bottom"]?.isCollapsed = true
        document.collapsed = [
            WorkspaceCollapsedItem(groupID: "bottom",
                                   slotID: .chromeBottomRail,
                                   edge: .bottom),
        ]
        let controller = WorkspaceController(document: document)
        let rig = WorkspaceViewRig(controller: controller,
                                   width: 1000,
                                   height: 640,
                                   root: Self.makeWorkspaceRootWithStatusBar(controller: controller,
                                                                             width: 1000,
                                                                             height: 640))

        let bottomRail = rig.frame(named: "workspace-rail-bottom")
        let bottomRestore = rig.frame(named: "workspace-restore-bottom-console")
        let statusBar = rig.frame(named: "editor-status-bar")
        let center = rig.frame(named: "workspace-region-center")
        XCTAssertNil(rig.optionalFrame(named: "workspace-region-bottom"))
        XCTAssertEqual(bottomRail.minX, center.minX, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxX, center.maxX, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxY, statusBar.minY, accuracy: 1.0)
        XCTAssertGreaterThanOrEqual(bottomRestore.minX, bottomRail.minX)
        XCTAssertLessThanOrEqual(bottomRestore.maxX, bottomRail.maxX)
        XCTAssertNotNil(rig.optionalFrame(named: "workspace-region-leading"))
        XCTAssertNotNil(rig.optionalFrame(named: "workspace-region-trailing"))
    }

    func testWorkspacePanelContentIsClippedToItsRegion() {
        let controller = WorkspaceController(document: Self.makeDocument())
        let root = AnyView(
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                WorkspaceView(controller: controller) { panelID in
                    AnyView(Box {
                        Box { EmptyView() }
                            .frame(width: 2000, height: 2000)
                            .background(Color.white)
                            .absolutePosition(left: 0, top: 0)
                    }
                    .debugName("oversized-\(panelID.rawValue)"))
                }
                .flex()
                Box { EmptyView() }
                    .frame(height: 24)
                    .debugName("editor-status-bar")
            }
            .frame(width: 1000, height: 640)
        )
        let rig = WorkspaceViewRig(controller: controller,
                                   width: 1000,
                                   height: 640,
                                   root: root)

        let panelNode = rig.node(named: "workspace-panel-viewport")
        let panelFrame = rig.frame(named: "workspace-panel-viewport")
        let statusBar = rig.frame(named: "editor-status-bar")
        XCTAssertTrue(panelNode.clipsToBounds)
        XCTAssertLessThanOrEqual(panelFrame.maxY, statusBar.minY + 1.0)

        let list = DrawList()
        guard let rootNode = rig.tree.root else {
            XCTFail("missing root node")
            return
        }
        NodeRenderer().render(root: rootNode, into: list)
        let clippedBatch = list.batches.first { batch in
            guard let scissor = batch.scissor else { return false }
            return abs(scissor.x - Float(panelFrame.minX)) <= 0.5
                && abs(scissor.y - Float(panelFrame.minY)) <= 0.5
                && abs(scissor.width - Float(panelFrame.width)) <= 0.5
                && abs(scissor.height - Float(panelFrame.height)) <= 0.5
        }
        XCTAssertNotNil(clippedBatch)
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
        let centerColumn = rig.frame(named: "workspace-center-column")
        XCTAssertEqual(leadingRail.minX, 0, accuracy: 0.5)
        XCTAssertEqual(trailingRail.maxX, 1000, accuracy: 0.5)
        XCTAssertEqual(bottomRail.minX, centerColumn.minX, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxX, centerColumn.maxX, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxY, collapsedStatusBar.minY, accuracy: 1.0)

        rig.click(rig.frame(named: "workspace-restore-leading-hierarchy").center)
        rig.click(rig.frame(named: "workspace-restore-trailing-inspector").center)
        rig.click(rig.frame(named: "workspace-restore-bottom-console").center)

        let leadingSlot = rig.frame(named: "workspace-region-leading")
        let centerSlot = rig.frame(named: "workspace-region-center")
        let leadingSplit = rig.frame(named: "workspace-split-leading")
        let trailingSlot = rig.frame(named: "workspace-region-trailing")
        let trailingSplit = rig.frame(named: "workspace-split-centerTrailing")
        let bottomSlot = rig.frame(named: "workspace-region-bottom")
        let restoredStatusBar = rig.frame(named: "editor-status-bar")

        XCTAssertNil(rig.optionalFrame(named: "workspace-rail-leading"))
        XCTAssertNil(rig.optionalFrame(named: "workspace-rail-trailing"))
        XCTAssertNil(rig.optionalFrame(named: "workspace-rail-bottom"))
        XCTAssertEqual(leadingSlot.minX, 0, accuracy: 0.5)
        // Two cards sit adjacent across a single hairline; the splitter's grab
        // area overhangs both of them, so it straddles that seam rather than
        // sitting between them.
        XCTAssertEqual(centerSlot.minX - leadingSlot.maxX, 1, accuracy: 0.5)
        XCTAssertEqual(trailingSlot.minX - centerSlot.maxX, 1, accuracy: 0.5)
        XCTAssertEqual(leadingSlot.maxX, leadingSplit.midX, accuracy: 1.0)
        XCTAssertEqual(centerSlot.maxX, trailingSplit.midX, accuracy: 1.0)
        XCTAssertEqual(bottomSlot.minX, centerSlot.minX, accuracy: 1.0)
        XCTAssertEqual(bottomSlot.maxX, centerSlot.maxX, accuracy: 1.0)
        XCTAssertEqual(restoredStatusBar.maxY, 640, accuracy: 0.5)
        XCTAssertEqual(bottomSlot.maxY, restoredStatusBar.minY, accuracy: 1.0)
    }

    func testDraggingTabIntoAnotherGroupMovesPanel() {
        let rig = makeRigWithStatusBar(width: 1000, height: 640)

        let source = rig.frame(named: "workspace-tab-hierarchy").center
        let target = rig.frame(named: "workspace-group-trailing").center
        rig.drag(from: source, to: target)

        XCTAssertFalse(rig.controller.document.groups.values.contains { group in
            group.id != "trailing" && group.panels.contains("hierarchy")
        })
        XCTAssertEqual(rig.controller.document.slot(.leading).layout?.leafGroupIDs ?? [], [])
        XCTAssertEqual(rig.controller.document.groups["trailing"]?.panels.contains("hierarchy"), true)
        XCTAssertEqual(rig.controller.document.groups["trailing"]?.activePanelID, "hierarchy")
        let hierarchyPanel = rig.frame(named: "workspace-panel-hierarchy")
        let trailingSlot = rig.frame(named: "workspace-region-trailing")
        XCTAssertGreaterThanOrEqual(hierarchyPanel.minX, trailingSlot.minX)
        XCTAssertLessThanOrEqual(hierarchyPanel.maxX, trailingSlot.maxX)
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

    func testTabsRenderWithoutCloseButtons() {
        // Tabs are plain title buttons — panels hide via collapse, and the
        // per-tab close affordance was removed deliberately (modern tab strips
        // don't carry resting close icons).
        let controller = WorkspaceController(document: Self.makeMultiTabDocument())
        let rig = WorkspaceViewRig(controller: controller,
                                   width: 1000,
                                   height: 640,
                                   root: Self.makeWorkspaceRoot(controller: controller))

        XCTAssertNotNil(rig.optionalFrame(named: "workspace-tab-console"))
        XCTAssertNil(rig.optionalFrame(named: "workspace-tab-close-console"))
        XCTAssertNil(rig.optionalFrame(named: "workspace-tab-close-assets"))
    }

    func testPanelWithOwnTabsHidesGroupTabBarOnlyWhileAlone() {
        var document = Self.makeMultiTabDocument()
        document.panels["viewport"]?.hidesTabBarWhenAlone = true
        document.panels["console"]?.hidesTabBarWhenAlone = true
        let controller = WorkspaceController(document: document)
        let rig = WorkspaceViewRig(controller: controller, width: 1000, height: 640,
                                   root: Self.makeWorkspaceRoot(controller: controller))

        XCTAssertNil(rig.optionalFrame(named: "workspace-tab-viewport"))
        XCTAssertEqual(rig.frame(named: "workspace-panel-viewport").minY,
                       rig.frame(named: "workspace-group-center").minY)
        // Sharing a group brings the tab strip back so either panel stays reachable.
        XCTAssertNotNil(rig.optionalFrame(named: "workspace-tab-console"))
        XCTAssertNotNil(rig.optionalFrame(named: "workspace-tab-assets"))
    }

    func testPanelRegionsScrollOnlyContentThatOverflows() {
        let controller = WorkspaceController(document: Self.makeDocument())
        let root = AnyView(WorkspaceView(controller: controller) { panelID in
            if panelID == "inspector" {
                // Rigid rows taller than any region: they must scroll, not clip.
                return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    for index in 0..<30 { AnyView(Text("Row \(index)").frame(height: 40)) }
                })
            }
            return AnyView(Box { Text(panelID.rawValue) }.flex().debugName("content-\(panelID.rawValue)"))
        })
        let rig = WorkspaceViewRig(controller: controller, width: 1000, height: 640, root: root)

        let inspector = rig.frame(named: "workspace-panel-scroll-inspector")
        rig.wheel(at: CGPoint(x: inspector.midX, y: inspector.midY), deltaY: -120)
        XCTAssertGreaterThan(rig.node(named: "workspace-panel-scroll-inspector").contentOffset.y, 0)

        // Flexible content fills its region exactly and never scrolls.
        let viewport = rig.frame(named: "workspace-panel-scroll-viewport")
        XCTAssertEqual(rig.frame(named: "content-viewport").height, viewport.height)
        rig.wheel(at: CGPoint(x: viewport.midX, y: viewport.midY), deltaY: -120)
        XCTAssertEqual(rig.node(named: "workspace-panel-scroll-viewport").contentOffset.y, 0)
    }

    func testDraggingWorkspaceSplitDividersUpdatesFractions() {
        let rig = makeRigWithStatusBar(width: 1000, height: 640)

        let leadingBefore = rig.controller.document.splitFractions.leading ?? -1
        let leadingSplit = rig.frame(named: "workspace-split-leading")
        rig.drag(from: leadingSplit.center,
                 to: CGPoint(x: leadingSplit.center.x + 70, y: leadingSplit.center.y))
        XCTAssertGreaterThan(rig.controller.document.splitFractions.leading ?? -1, leadingBefore)

        let centerTrailingBefore = rig.controller.document.splitFractions.centerTrailing ?? -1
        let centerTrailingSplit = rig.frame(named: "workspace-split-centerTrailing")
        rig.drag(from: centerTrailingSplit.center,
                 to: CGPoint(x: centerTrailingSplit.center.x - 60, y: centerTrailingSplit.center.y))
        XCTAssertLessThan(rig.controller.document.splitFractions.centerTrailing ?? -1, centerTrailingBefore)

        let topBottomBefore = rig.controller.document.splitFractions.topBottom ?? -1
        let bottomSplit = rig.frame(named: "workspace-split-topBottom")
        rig.drag(from: bottomSplit.center,
                 to: CGPoint(x: bottomSplit.center.x, y: bottomSplit.center.y - 50))
        XCTAssertLessThan(rig.controller.document.splitFractions.topBottom ?? -1, topBottomBefore)
    }

    func testFloatingGroupRendersAboveWorkspaceWithoutChangingMainRegionFrames() {
        let rig = makeRigWithStatusBar(width: 1000, height: 640)

        _ = rig.controller.dispatch(.floatGroup("trailing",
                                                windowID: "inspector-window",
                                                frame: WorkspaceRect(x: 120, y: 88, width: 360, height: 260)))
        rig.pump()

        XCTAssertNil(rig.optionalFrame(named: "workspace-region-trailing"))
        XCTAssertEqual(rig.controller.document.slot(.trailing).layout?.leafGroupIDs ?? [], [])
        XCTAssertEqual(rig.frame(named: "workspace-region-center").maxX, 1000, accuracy: 0.5)
        let floating = rig.frame(named: "workspace-floating-window-inspector-window")
        XCTAssertEqual(floating.minX, 120, accuracy: 0.5)
        XCTAssertEqual(floating.minY, 88, accuracy: 0.5)
        XCTAssertEqual(floating.width, 360, accuracy: 0.5)
        XCTAssertEqual(floating.height, 260, accuracy: 0.5)
        XCTAssertNotNil(rig.optionalFrame(named: "workspace-panel-inspector"))
    }

    func testDraggingFloatingWindowMovesOnlyFloatingFrame() {
        let rig = makeRigWithStatusBar(width: 1000, height: 640)

        _ = rig.controller.dispatch(.floatGroup("trailing",
                                                windowID: "inspector-window",
                                                frame: WorkspaceRect(x: 120, y: 88, width: 360, height: 260)))
        rig.pump()
        let centerBefore = rig.frame(named: "workspace-region-center")
        let handle = rig.frame(named: "workspace-floating-drag-inspector-window")

        rig.drag(from: handle.center,
                 to: CGPoint(x: handle.center.x + 40, y: handle.center.y + 30))

        let moved = rig.controller.document.floatingWindows.first?.frame
        XCTAssertEqual(moved?.x ?? 0, 160, accuracy: 0.5)
        XCTAssertEqual(moved?.y ?? 0, 118, accuracy: 0.5)
        XCTAssertEqual(moved?.width ?? 0, 360, accuracy: 0.5)
        XCTAssertEqual(moved?.height ?? 0, 260, accuracy: 0.5)
        XCTAssertEqual(rig.frame(named: "workspace-region-center"), centerBefore)
    }

    func testRedockingFloatingWindowReturnsGroupToWorkspaceSlot() {
        let rig = makeRigWithStatusBar(width: 1000, height: 640)

        _ = rig.controller.dispatch(.floatGroup("trailing",
                                                windowID: "inspector-window",
                                                frame: WorkspaceRect(x: 120, y: 88, width: 360, height: 260)))
        rig.pump()
        rig.click(rig.frame(named: "workspace-floating-redock-inspector-window").center)

        XCTAssertTrue(rig.controller.document.floatingWindows.isEmpty)
        XCTAssertEqual(rig.controller.document.slot(.center).layout?.leafGroupIDs ?? [], ["center", "trailing"])
        XCTAssertEqual(rig.controller.document.groups["trailing"]?.panels, ["inspector"])
        XCTAssertNotNil(rig.optionalFrame(named: "workspace-region-center"))
        XCTAssertNil(rig.optionalFrame(named: "workspace-floating-window-inspector-window"))
    }

    func testDraggingTabToGroupEdgeCreatesAdjacentGroup() {
        let rig = makeRigWithStatusBar(width: 1000, height: 640)

        let source = rig.frame(named: "workspace-tab-hierarchy").center
        let trailingGroup = rig.frame(named: "workspace-group-trailing")
        let target = CGPoint(x: trailingGroup.minX + 8, y: trailingGroup.midY)
        rig.drag(from: source, to: target)

        let trailingSlot = rig.controller.document.slot(.trailing)
        XCTAssertEqual((trailingSlot.layout?.leafGroupIDs ?? []).count, 2)
        let movedGroupID = (trailingSlot.layout?.leafGroupIDs ?? []).first
        XCTAssertNotEqual(movedGroupID, "trailing")
        XCTAssertEqual(rig.controller.document.groups[movedGroupID ?? ""]?.panels, ["hierarchy"])
        XCTAssertEqual(rig.controller.document.groups[movedGroupID ?? ""]?.activePanelID, "hierarchy")
    }

    func testDraggingTabShowsDropIndicatorBeforeRelease() {
        let rig = makeRigWithStatusBar(width: 1000, height: 640)

        let source = rig.frame(named: "workspace-tab-hierarchy").center
        let target = rig.frame(named: "workspace-group-trailing").center

        rig.beginDrag(from: source)
        rig.moveDrag(to: target)

        XCTAssertEqual(rig.controller.document.groups["leading"]?.panels, ["hierarchy"])
        let root = rig.node(named: "workspace")
        let dragOverlay = DrawList()
        root.overlayDraw?(dragOverlay, .zero)
        XCTAssertGreaterThan(dragOverlay.vertices.count, 0)

        rig.endDrag(at: target)

        XCTAssertEqual(rig.controller.document.groups["trailing"]?.panels.contains("hierarchy"), true)
        let clearedOverlay = DrawList()
        rig.node(named: "workspace").overlayDraw?(clearedOverlay, .zero)
        XCTAssertEqual(clearedOverlay.vertices.count, 0)
    }

    func testSmallDragInsideSourceTabStripDoesNotSplitPanel() {
        let rig = makeRigWithStatusBar(width: 1000, height: 640)

        let source = rig.frame(named: "workspace-tab-hierarchy").center
        let target = CGPoint(x: source.x + 6, y: source.y)

        rig.drag(from: source, to: target)

        XCTAssertEqual(rig.controller.document.groups["leading"]?.panels, ["hierarchy"])
        XCTAssertEqual(rig.controller.document.slot(.leading).layout?.leafGroupIDs ?? [], ["leading"])
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
                                               to: WorkspaceTarget(slot: .center,
                                                                   groupID: "center",
                                                                   placement: .tabGroup)))
        rig.pump()

        XCTAssertNil(rig.optionalFrame(named: "workspace-collapse-center"))
    }

    func testTabStripExposesTabListPanelAndPositionAndMirrorsArrowsInRTL() {
        for rtl in [false, true] {
            let controller = WorkspaceController(document: Self.makeMultiTabDocument())
            let root = AnyView(WorkspaceView(controller: controller) { panelID in
                AnyView(Box { Text(panelID.rawValue) }.debugName("content-\(panelID.rawValue)"))
            }.layoutDirection(rtl ? .rtl : .ltr))
            let rig = WorkspaceViewRig(controller: controller, width: 1000, height: 640, root: root)
            for _ in 0..<4 { rig.pump() }
            let console = rig.node(named: "workspace-tab-console"), assets = rig.node(named: "workspace-tab-assets")
            XCTAssertEqual(console.accessibility?.role, .tab)
            XCTAssertEqual(console.accessibility?.help, "Tab 1 of 2")
            XCTAssertEqual(assets.accessibility?.help, "Tab 2 of 2")
            XCTAssertEqual(console.accessibility?.state.isSelected, true)
            var ancestor = console.parent
            while let node = ancestor, node.accessibility?.role != .tabList { ancestor = node.parent }
            XCTAssertEqual(ancestor?.accessibility?.label, "Panel tabs")
            XCTAssertEqual(ancestor?.accessibility?.value, "Console")
            var panel = rig.node(named: "content-console").parent
            while let node = panel, node.accessibility?.role != .tabPanel { panel = node.parent }
            XCTAssertEqual(panel?.accessibility?.label, "Console")
            if rtl { XCTAssertGreaterThan(console.absoluteFrame.minX, assets.absoluteFrame.minX) }
            else { XCTAssertLessThan(console.absoluteFrame.minX, assets.absoluteFrame.minX) }
            rig.focus.focus(console)
            // The next tab is the visual neighbour: right in LTR, left in RTL.
            rig.dispatcher.dispatch(.keyDown(KeyEvent(scancode: rtl ? Scancode.arrowLeft : Scancode.arrowRight,
                                                      keycode: 0, modifiers: [], isRepeat: false)))
            for _ in 0..<4 { rig.pump() }
            XCTAssertEqual(controller.document.groups["bottom"]?.activePanelID, "assets", rtl ? "RTL" : "LTR")
        }
    }

    func testTabArrowCommandMapping() {
        XCTAssertEqual(workspaceTabCommand(for: Scancode.arrowLeft, rightToLeft: false), .previous)
        XCTAssertEqual(workspaceTabCommand(for: Scancode.arrowLeft, rightToLeft: true), .next)
        XCTAssertEqual(workspaceTabCommand(for: Scancode.arrowRight, rightToLeft: true), .previous)
        XCTAssertEqual(workspaceTabCommand(for: Scancode.home, rightToLeft: true), .first)
        XCTAssertNil(workspaceTabCommand(for: Scancode.arrowUp, rightToLeft: false))
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
                                root: Self.makeWorkspaceRootWithStatusBar(controller: controller,
                                                                          width: width,
                                                                          height: height))
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
            slots: WorkspaceSlot.standardEditorSlots(leading: .group("leading"),
                                                     center: .group("center"),
                                                     trailing: .group("trailing"),
                                                     bottom: .group("bottom")),
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

    private static func makeWorkspaceRootWithStatusBar(controller: WorkspaceController,
                                                       width: Float,
                                                       height: Float) -> AnyView {
        AnyView(
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
        )
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
        beginDrag(from: start)
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
        endDrag(at: end)
    }

    func wheel(at point: CGPoint, deltaY: Float) {
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: Float(point.x), y: Float(point.y), deltaX: 0, deltaY: 0)))
        dispatcher.dispatch(.mouseWheel(.init(x: 0, y: deltaY, mouseX: Float(point.x), mouseY: Float(point.y),
                                              input: .init(unit: .points, device: .continuous, phase: .none, momentumPhase: .none))))
        pump()
    }

    func beginDrag(from start: CGPoint) {
        dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left,
                                                              x: Float(start.x),
                                                              y: Float(start.y),
                                                              clicks: 1)))
        pump()
    }

    func moveDrag(to point: CGPoint) {
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: Float(point.x),
                                                          y: Float(point.y),
                                                          deltaX: 0,
                                                          deltaY: 0)))
        pump()
    }

    func endDrag(at point: CGPoint) {
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

    func node(named debugName: String) -> Node {
        guard let node = optionalNode(named: debugName) else {
            XCTFail("missing node named \(debugName)")
            return Node()
        }
        return node
    }

    func optionalNode(named debugName: String) -> Node? {
        firstNode(in: tree.root, named: debugName)
    }

    func optionalFrame(named debugName: String) -> CGRect? {
        graph.layoutSnapshot()
            .first { $0.debugName == debugName }?
            .absoluteFrame
    }

    private func firstNode(in node: Node?, named debugName: String) -> Node? {
        guard let node else { return nil }
        if (node.attachments[LayoutDebugAttachmentKey.debugName] as? String) == debugName {
            return node
        }
        for child in node.children {
            if let found = firstNode(in: child, named: debugName) {
                return found
            }
        }
        return nil
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

extension WorkspaceViewTests {
    func testPanelSizingAppliesToOuterPointerKeyboardAndAccessibilityAndRestores() throws {
        var document = Self.makeDocument()
        document.panels["hierarchy"]?.sizing.width = .init(minimum: 160, preferred: 200, maximum: 240)
        document.panels["viewport"]?.sizing.width = .init(minimum: 300)
        document.panels["inspector"]?.sizing.width = .init(minimum: 180, preferred: 220, maximum: 280)
        document.panels["console"]?.sizing.height = .init(minimum: 90, preferred: 150, maximum: 200)
        document.splitFractions = .init()
        let controller = WorkspaceController(document: document)
        let rig = WorkspaceViewRig(controller: controller, width: 1000, height: 600,
                                   root: Self.makeWorkspaceRoot(controller: controller))
        for _ in 0..<5 { rig.pump() }
        XCTAssertEqual(rig.frame(named: "workspace-region-leading").width, 200, accuracy: 1)
        XCTAssertEqual(rig.frame(named: "workspace-region-trailing").width, 220, accuracy: 1)
        XCTAssertEqual(rig.frame(named: "workspace-region-bottom").height, 184, accuracy: 1)
        XCTAssertEqual(controller.document, document, "Measurement must not persist viewport state")
        let divider = rig.node(named: "workspace-split-leading")
        XCTAssertEqual(divider.accessibility?.role, .slider)
        rig.click(divider.absoluteFrame.center)
        XCTAssertTrue(rig.focus.focused === divider)
        rig.dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.end, keycode: 0, modifiers: [], isRepeat: false)))
        for _ in 0..<3 { rig.pump() }
        XCTAssertEqual(rig.frame(named: "workspace-region-leading").width, 240, accuracy: 1)
        divider.accessibilityActions.decrement?()
        for _ in 0..<3 { rig.pump() }
        XCTAssertLessThan(rig.frame(named: "workspace-region-leading").width, 240)
        rig.drag(from: rig.frame(named: "workspace-split-leading").center, to: CGPoint(x: -500, y: 100))
        XCTAssertEqual(rig.frame(named: "workspace-region-leading").width, 160, accuracy: 1)
        let saved = try JSONEncoder().encode(controller.document)
        let restored = try JSONDecoder().decode(WorkspaceDocument.self, from: saved)
        controller.replace(restored)
        for _ in 0..<3 { rig.pump() }
        XCTAssertEqual(rig.frame(named: "workspace-region-leading").width, 160, accuracy: 1)
        XCTAssertEqual(controller.document.panels["hierarchy"]?.sizing.width,
                       .init(minimum: 160, preferred: 200, maximum: 240))
    }

    func testCrampedWorkspaceSharesMinimumsWithoutHorizontalOverflow() {
        var document = Self.makeDocument()
        document.panels["hierarchy"]?.sizing.width = .init(minimum: 160)
        document.panels["viewport"]?.sizing.width = .init(minimum: 300)
        document.panels["inspector"]?.sizing.width = .init(minimum: 180)
        let controller = WorkspaceController(document: document)
        let rig = WorkspaceViewRig(controller: controller, width: 380, height: 320,
                                   root: Self.makeWorkspaceRoot(controller: controller))
        for _ in 0..<5 { rig.pump() }
        let leading = rig.frame(named: "workspace-region-leading")
        let center = rig.frame(named: "workspace-region-center")
        let trailing = rig.frame(named: "workspace-region-trailing")
        XCTAssertGreaterThan(leading.width, 0)
        XCTAssertGreaterThan(center.width, 0)
        XCTAssertGreaterThan(trailing.width, 0)
        XCTAssertGreaterThanOrEqual(leading.minX, 0)
        XCTAssertLessThanOrEqual(trailing.maxX, 380.5)
        XCTAssertEqual(leading.width / (center.width + trailing.width), 160 / 480, accuracy: 0.01)
        XCTAssertEqual(controller.document, document)
    }

    func testTopRegionUsesTheSharedHeightContractAndKeyboard() {
        var document = Self.makeDocument()
        document.panels["top-panel"] = .init(id: "top-panel", title: "Top", sizing: .init(
            height: .init(minimum: 80, preferred: 100, maximum: 160)))
        document.groups["top-group"] = .init(id: "top-group", panels: ["top-panel"])
        document.setSlot(.init(id: .top, layout: .group("top-group")))
        let controller = WorkspaceController(document: document)
        let rig = WorkspaceViewRig(controller: controller, width: 1000, height: 800,
                                   root: Self.makeWorkspaceRoot(controller: controller))
        for _ in 0..<5 { rig.pump() }
        XCTAssertEqual(rig.frame(named: "workspace-region-top").height, 134, accuracy: 1)
        let divider = rig.node(named: "workspace-split-top")
        rig.focus.focus(divider)
        rig.dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.end, keycode: 0, modifiers: [], isRepeat: false)))
        for _ in 0..<3 { rig.pump() }
        XCTAssertEqual(rig.frame(named: "workspace-region-top").height, 194, accuracy: 1)
        XCTAssertNotNil(controller.document.splitFractions.top)
    }

    func testTwoHundredPercentTabsKeepControlsReachableAndRevealKeyboardSelection() {
        var document = Self.makeDocument()
        for id in [WorkspaceSlotID.leading, .trailing, .bottom] { document.slots[id]?.layout = nil }
        let panels = (0..<32).map { WorkspacePanelID(rawValue: "tab-\($0)") }
        for panelID in panels {
            document.panels[panelID] = .init(id: panelID, title: "A long translated panel title \(panelID.rawValue)")
        }
        document.groups["center"] = .init(id: "center", panels: panels, activePanelID: panels.first)
        let controller = WorkspaceController(document: document)
        let root = AnyView(Self.makeWorkspaceRoot(controller: controller).textScaler(.init(2)))
        let rig = WorkspaceViewRig(controller: controller, width: 420, height: 400, root: root)
        for _ in 0..<5 { rig.pump() }
        let group = rig.frame(named: "workspace-group-center")
        let content = rig.frame(named: "workspace-panel-tab-0")
        XCTAssertEqual(content.minY - group.minY, 68, accuracy: 0.5)
        let overflow = rig.frame(named: "workspace-tabs-overflow-center")
        let maximize = rig.frame(named: "workspace-maximize-center")
        XCTAssertGreaterThan(overflow.width, 0)
        XCTAssertLessThanOrEqual(maximize.maxX, group.maxX)
        let first = rig.node(named: "workspace-tab-tab-0")
        XCTAssertTrue(first.isTabStop)
        XCTAssertFalse(rig.node(named: "workspace-tab-tab-1").isTabStop)
        let initialScroll = rig.node(named: "workspace-tabs-scroll-center")
        let initialLast = rig.node(named: "workspace-tab-tab-31")
        XCTAssertGreaterThan(initialLast.absoluteFrame.maxX, initialScroll.absoluteFrame.maxX,
            "The overflow fixture must exceed the viewport even without a native font atlas")
        rig.click(first.absoluteFrame.center)
        XCTAssertTrue(rig.focus.focused === first)
        rig.dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.end, keycode: 0, modifiers: [], isRepeat: false)))
        for _ in 0..<4 { rig.pump() }
        XCTAssertEqual(controller.document.groups["center"]?.activePanelID, panels.last)
        let scroll = rig.node(named: "workspace-tabs-scroll-center")
        let last = rig.node(named: "workspace-tab-tab-31")
        XCTAssertGreaterThan(scroll.contentOffset.x, 0)
        XCTAssertTrue(last.isTabStop)
        XCTAssertEqual(last.accessibility?.state.isSelected, true)
        XCTAssertGreaterThanOrEqual(last.absoluteFrame.minX, scroll.absoluteFrame.minX - 1)
    }
}
