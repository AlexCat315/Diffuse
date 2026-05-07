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
        let statusBar = rig.frame(named: "editor-status-bar")
        let chrome = rig.frame(named: "workspace-chrome-chrome.bottom.rail")
        XCTAssertEqual(statusBar.maxY, 640, accuracy: 0.5)
        XCTAssertEqual(bottomRail.minX, 0, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxX, 1000, accuracy: 0.5)
        XCTAssertEqual(chrome.height, 40, accuracy: 0.5)
        XCTAssertEqual(bottomRail.minY, chrome.minY, accuracy: 1.0)
        XCTAssertEqual(bottomRail.maxY, statusBar.minY, accuracy: 1.0)
        XCTAssertLessThan(bottomRail.minY, statusBar.minY)
    }

    func testTopSlotAndBottomChromeSlotUseFixedWorkspaceSlots() {
        var document = Self.makeDocument()
        document.panels["timeline"] = WorkspacePanel(id: "timeline", title: "Timeline")
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

        let topSlot = rig.frame(named: "workspace-slot-top")
        let bottomChrome = rig.frame(named: "workspace-chrome-\(toolbarID.rawValue)")
        XCTAssertEqual(topSlot.minY, 0, accuracy: 0.5)
        XCTAssertEqual(topSlot.height, 160, accuracy: 0.5)
        XCTAssertEqual(bottomChrome.height, 28, accuracy: 0.5)
        XCTAssertEqual(bottomChrome.maxY, 640, accuracy: 0.5)
    }

    func testCollapsedRailsKeepBottomRailOnGlobalBottomEdge() {
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
        XCTAssertLessThanOrEqual(leadingRail.maxY, bottomRail.minY)
        XCTAssertLessThanOrEqual(bottomRail.minY - leadingRail.maxY, 1.5)
        XCTAssertEqual(trailingRail.maxX, 1000, accuracy: 0.5)
        XCTAssertEqual(trailingRail.width, 40, accuracy: 0.5)
        XCTAssertLessThanOrEqual(trailingRail.maxY, bottomRail.minY)
        XCTAssertLessThanOrEqual(bottomRail.minY - trailingRail.maxY, 1.5)
        XCTAssertEqual(bottomRail.minX, 0, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxX, 1000, accuracy: 0.5)
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
        XCTAssertNil(rig.optionalFrame(named: "workspace-bottom-slot"))
        XCTAssertEqual(chrome.height, 40, accuracy: 0.5)
        XCTAssertEqual(bottomRail.height, 40, accuracy: 0.5)
        XCTAssertEqual(bottomRail.minX, 0, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxX, 1000, accuracy: 0.5)
        XCTAssertEqual(bottomRail.minY, chrome.minY, accuracy: 1.0)
        XCTAssertEqual(bottomRail.maxY, statusBar.minY, accuracy: 1.0)
    }

    func testBottomRailRemainsAllocatedWhenBottomCollapsesBeforeSideRails() {
        let rig = makeRigWithStatusBar(width: 1998, height: 1246)

        rig.click(rig.frame(named: "workspace-collapse-bottom").center)

        let bottomRail = rig.frame(named: "workspace-rail-bottom")
        let chrome = rig.frame(named: "workspace-chrome-chrome.bottom.rail")
        let statusBar = rig.frame(named: "editor-status-bar")
        XCTAssertNil(rig.optionalFrame(named: "workspace-bottom-slot"))
        XCTAssertEqual(chrome.height, 40, accuracy: 0.5)
        XCTAssertEqual(bottomRail.height, 40, accuracy: 0.5)
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
        let bottomRestore = rig.frame(named: "workspace-restore-bottom")
        XCTAssertEqual(workspace.maxY, statusBar.minY, accuracy: 1.0)
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
        XCTAssertNil(rig.optionalFrame(named: "workspace-region-bottom"))
        XCTAssertNil(rig.controller.document.slots[.chromeBottomRail])
        XCTAssertEqual(chrome.height, 40, accuracy: 0.5)
        XCTAssertEqual(bottomRail.minX, 0, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxX, 1000, accuracy: 0.5)
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
        let bottomRestore = rig.frame(named: "workspace-restore-bottom")
        let statusBar = rig.frame(named: "editor-status-bar")
        XCTAssertNil(rig.optionalFrame(named: "workspace-region-bottom"))
        XCTAssertEqual(bottomRail.minX, 0, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxX, 1000, accuracy: 0.5)
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
        XCTAssertEqual(leadingRail.minX, 0, accuracy: 0.5)
        XCTAssertEqual(trailingRail.maxX, 1000, accuracy: 0.5)
        XCTAssertEqual(bottomRail.minX, 0, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxX, 1000, accuracy: 0.5)
        XCTAssertEqual(bottomRail.maxY, collapsedStatusBar.minY, accuracy: 1.0)

        rig.click(rig.frame(named: "workspace-restore-leading").center)
        rig.click(rig.frame(named: "workspace-restore-trailing").center)
        rig.click(rig.frame(named: "workspace-restore-bottom").center)

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
        XCTAssertEqual(leadingSlot.maxX, leadingSplit.minX, accuracy: 1.0)
        XCTAssertEqual(leadingSplit.maxX, centerSlot.minX, accuracy: 1.0)
        XCTAssertEqual(centerSlot.maxX, trailingSplit.minX, accuracy: 1.0)
        XCTAssertEqual(trailingSplit.maxX, trailingSlot.minX, accuracy: 1.0)
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

    func testClickingTabCloseButtonRemovesPanelWithoutMovingSlots() {
        let controller = WorkspaceController(document: Self.makeMultiTabDocument())
        let rig = WorkspaceViewRig(controller: controller,
                                   width: 1000,
                                   height: 640,
                                   root: Self.makeWorkspaceRoot(controller: controller))

        rig.click(rig.frame(named: "workspace-tab-close-console").center)

        XCTAssertEqual(rig.controller.document.groups["bottom"]?.panels, ["assets"])
        XCTAssertEqual(rig.controller.document.groups["bottom"]?.activePanelID, "assets")
        XCTAssertEqual(rig.controller.document.slot(.bottom).layout?.leafGroupIDs ?? [], ["bottom"])
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
            layoutTree: .group("center"),
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
