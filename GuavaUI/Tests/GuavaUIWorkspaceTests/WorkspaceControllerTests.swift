import XCTest
import GuavaUIWorkspace

final class WorkspaceControllerTests: XCTestCase {
    func testCollapseExpandLeftRightBottomInAnyOrderPreservesSlots() {
        let controller = WorkspaceController(document: makeDocument())

        let left = controller.dispatch(.collapse("leading"))
        let right = controller.dispatch(.collapse("trailing"))
        let bottom = controller.dispatch(.collapse("bottom"))

        XCTAssertTrue(left.persistenceDirty)
        XCTAssertTrue(right.persistenceDirty)
        XCTAssertTrue(bottom.persistenceDirty)
        XCTAssertTrue(controller.document.groups["leading"]?.isCollapsed == true)
        XCTAssertTrue(controller.document.groups["trailing"]?.isCollapsed == true)
        XCTAssertTrue(controller.document.groups["bottom"]?.isCollapsed == true)
        XCTAssertEqual(controller.document.slot(.leading).layout?.leafGroupIDs ?? [], ["leading"])
        XCTAssertEqual(controller.document.slot(.trailing).layout?.leafGroupIDs ?? [], ["trailing"])
        XCTAssertEqual(controller.document.slot(.bottom).layout?.leafGroupIDs ?? [], ["bottom"])

        _ = controller.dispatch(.expand("bottom"))
        _ = controller.dispatch(.expand("trailing"))
        _ = controller.dispatch(.expand("leading"))

        XCTAssertFalse(controller.document.groups["leading"]?.isCollapsed == true)
        XCTAssertFalse(controller.document.groups["trailing"]?.isCollapsed == true)
        XCTAssertFalse(controller.document.groups["bottom"]?.isCollapsed == true)
        XCTAssertEqual(controller.document.splitFractions.leading, 0.24, accuracy: 0.0001)
        XCTAssertEqual(controller.document.splitFractions.topBottom, 0.68, accuracy: 0.0001)
        XCTAssertTrue(controller.document.collapsed.isEmpty)
    }

    func testDocumentSupportsApplicationDefinedSlotsAndChromePolicies() {
        let drawerSlot = WorkspaceSlotID(rawValue: "drawer.properties")
        let bottomToolbar = WorkspaceSlotID(rawValue: "chrome.bottom.timeline-toolbar")
        var document = makeDocument()
        document.panels["properties"] = WorkspacePanel(id: "properties", title: "Properties")
        document.groups["properties"] = WorkspaceTabGroup(id: "properties",
                                                          panels: ["properties"],
                                                          activePanelID: "properties")
        document.slots[drawerSlot] = WorkspaceSlot(id: drawerSlot,
                                                   kind: .content,
                                                   layout: .group("properties"))
        document.slots[bottomToolbar] = WorkspaceSlot(id: bottomToolbar,
                                                      kind: .chrome(edge: .bottom, size: .fixed(28)))

        let controller = WorkspaceController(document: document)

        XCTAssertEqual(controller.document.slot(drawerSlot).layout?.leafGroupIDs ?? [], ["properties"])
        XCTAssertEqual(controller.document.slot(bottomToolbar).kind,
                       .chrome(edge: .bottom, size: .fixed(28)))

        _ = controller.dispatch(.movePanel("properties",
                                           to: .split(slot: .center,
                                                      anchorGroupID: "center",
                                                      edge: .trailing,
                                                      fraction: 0.35)))

        XCTAssertEqual(controller.document.slot(drawerSlot).layout?.leafGroupIDs ?? [], [])
        XCTAssertTrue((controller.document.slot(.center).layout?.leafGroupIDs ?? []).contains { groupID in
            controller.document.groups[groupID]?.panels == ["properties"]
        })
    }

    func testStandardEditorSlotSchemaBackfillsMissingRailChromeSlots() {
        var document = makeDocument()
        document.slots.removeValue(forKey: .chromeBottomRail)
        document.slots.removeValue(forKey: .chromeTrailingRail)

        document.ensureStandardEditorSlotSchema()

        XCTAssertEqual(document.slot(.chromeBottomRail).kind,
                       .chrome(edge: .bottom, size: .fixed(40)))
        XCTAssertEqual(document.slot(.chromeTrailingRail).kind,
                       .chrome(edge: .trailing, size: .fixed(40)))
        XCTAssertEqual(document.slot(.leading).layout?.leafGroupIDs ?? [], ["leading"])
        XCTAssertEqual(document.slot(.bottom).layout?.leafGroupIDs ?? [], ["bottom"])
    }

    func testMovePanelIntoAnotherGroupDoesNotRebuildSlots() {
        let controller = WorkspaceController(document: makeDocument())

        let result = controller.dispatch(.movePanel("inspector",
                                                    to: WorkspaceTarget(slot: .center,
                                                                        groupID: "center",
                                                                        placement: .tabGroup)))

        XCTAssertTrue(result.persistenceDirty)
        XCTAssertEqual(controller.document.groups["center"]?.panels, ["viewport", "inspector"])
        XCTAssertEqual(controller.document.groups["center"]?.activePanelID, "inspector")
        XCTAssertNil(controller.document.groups["trailing"])
        XCTAssertEqual(controller.document.slot(.trailing).layout?.leafGroupIDs ?? [], [])
        XCTAssertEqual(controller.document.slot(.bottom).layout?.leafGroupIDs ?? [], ["bottom"])

        _ = controller.dispatch(.movePanel("inspector",
                                           to: WorkspaceTarget(slot: .trailing,
                                                               groupID: "trailing",
                                                               placement: .tabGroup)))

        XCTAssertEqual(controller.document.slot(.trailing).layout?.leafGroupIDs ?? [], ["trailing"])
        XCTAssertEqual(controller.document.groups["trailing"]?.panels, ["inspector"])
    }

    func testCenterEdgeDropsCreateNestedSplitsInCenterRegion() {
        let controller = WorkspaceController(document: makeDocument())

        _ = controller.dispatch(.movePanel("inspector",
                                           to: WorkspaceTarget(slot: .center,
                                                               groupID: "center",
                                                               placement: .split,
                                                               edge: .trailing)))
        XCTAssertEqual(controller.document.slot(.trailing).layout?.leafGroupIDs ?? [], [])
        XCTAssertEqual(controller.document.groups["center"]?.panels, ["viewport"])
        let inspectorGroupID = (controller.document.slot(.center).layout?.leafGroupIDs ?? []).last
        XCTAssertNotNil(inspectorGroupID)
        XCTAssertEqual(controller.document.groups[inspectorGroupID!]?.panels, ["inspector"])

        _ = controller.dispatch(.movePanel("hierarchy",
                                           to: WorkspaceTarget(slot: .center,
                                                               groupID: "center",
                                                               placement: .split,
                                                               edge: .leading)))
        XCTAssertEqual(controller.document.slot(.leading).layout?.leafGroupIDs ?? [], [])
        XCTAssertEqual((controller.document.slot(.center).layout?.leafGroupIDs ?? []).count, 3)
        XCTAssertEqual(controller.document.groups["center"]?.panels, ["viewport"])

        _ = controller.dispatch(.movePanel("console",
                                           to: WorkspaceTarget(slot: .center,
                                                               groupID: "center",
                                                               placement: .split,
                                                               edge: .bottom)))
        XCTAssertEqual(controller.document.slot(.bottom).layout?.leafGroupIDs ?? [], [])
        XCTAssertEqual((controller.document.slot(.center).layout?.leafGroupIDs ?? []).count, 4)
        XCTAssertEqual(controller.document.groups["center"]?.panels, ["viewport"])
    }

    func testEdgeDropInsideRegionCreatesAdjacentGroupInsteadOfMerging() {
        let controller = WorkspaceController(document: makeDocument())

        _ = controller.dispatch(.movePanel("inspector",
                                           to: WorkspaceTarget(slot: .leading,
                                                               groupID: "leading",
                                                               placement: .split,
                                                               edge: .trailing)))

        let leadingGroupIDs = controller.document.slot(.leading).layout?.leafGroupIDs ?? []
        XCTAssertEqual(leadingGroupIDs.count, 2)
        XCTAssertEqual(leadingGroupIDs.first, "leading")
        let insertedGroupID = leadingGroupIDs[1]
        XCTAssertEqual(controller.document.groups["leading"]?.panels, ["hierarchy"])
        XCTAssertEqual(controller.document.groups[insertedGroupID]?.panels, ["inspector"])
        XCTAssertEqual(controller.document.slot(.trailing).layout?.leafGroupIDs ?? [], [])
    }

    func testNestedSplitTreePreservesArbitraryPanelPlacement() {
        var document = makeDocument()
        document.panels["timeline"] = WorkspacePanel(id: "timeline", title: "Timeline")
        document.groups["bottom"]?.panels = ["console", "timeline"]
        let controller = WorkspaceController(document: document)

        _ = controller.dispatch(.movePanel("inspector",
                                           to: .split(slot: .center,
                                                      anchorGroupID: "center",
                                                      edge: .trailing,
                                                      fraction: 0.35)))
        let inspectorGroupID = (controller.document.slot(.center).layout?.leafGroupIDs ?? []).last!
        _ = controller.dispatch(.movePanel("console",
                                           to: .split(slot: .center,
                                                      anchorGroupID: inspectorGroupID,
                                                      edge: .bottom,
                                                      fraction: 0.4)))
        _ = controller.dispatch(.movePanel("hierarchy",
                                           to: .split(slot: .center,
                                                      anchorGroupID: "center",
                                                      edge: .top,
                                                      fraction: 0.3)))

        guard case .split(let outerAxis, _, let first, let second) = controller.document.slot(.center).layout else {
            XCTFail("Expected center region to be backed by a split tree")
            return
        }
        XCTAssertEqual(outerAxis, .horizontal)
        XCTAssertEqual((controller.document.slot(.center).layout?.leafGroupIDs ?? []).count, 4)
        XCTAssertTrue(first.leafGroupIDs.contains("center"))
        XCTAssertTrue(first.leafGroupIDs.contains { controller.document.groups[$0]?.panels == ["hierarchy"] })
        XCTAssertTrue(second.leafGroupIDs.contains(inspectorGroupID))
        XCTAssertTrue(second.leafGroupIDs.contains { controller.document.groups[$0]?.panels == ["console"] })
        XCTAssertEqual(controller.document.slot(.leading).layout?.leafGroupIDs ?? [], [])
        XCTAssertEqual(controller.document.slot(.bottom).layout?.leafGroupIDs ?? [], ["bottom"])
    }

    func testDocumentRejectsUnattachedGroupsFromObsoletePersistedShape() {
        let obsolete = WorkspaceDocument(
            panels: [
                "viewport": WorkspacePanel(id: "viewport", title: "Viewport", isClosable: false),
                "inspector": WorkspacePanel(id: "inspector", title: "Inspector"),
            ],
            groups: [
                "center": WorkspaceTabGroup(id: "center", panels: ["viewport"], activePanelID: "viewport"),
                "trailing": WorkspaceTabGroup(id: "trailing", panels: ["inspector"], activePanelID: "inspector"),
            ],
            slots: WorkspaceSlot.standardEditorSlots()
        )

        XCTAssertFalse(obsolete.hasValidLayoutReferences)
        XCTAssertTrue(makeDocument().hasValidLayoutReferences)
    }

    func testCollapseRestoreKeepsActiveTabAndOrder() {
        var document = makeDocument()
        document.groups["bottom"]?.panels = ["console", "assets"]
        document.groups["bottom"]?.activePanelID = "assets"
        document.panels["assets"] = WorkspacePanel(id: "assets", title: "Assets")
        let controller = WorkspaceController(document: document)

        _ = controller.dispatch(.collapse("bottom"))
        _ = controller.dispatch(.expand("bottom"))

        XCTAssertEqual(controller.document.groups["bottom"]?.panels, ["console", "assets"])
        XCTAssertEqual(controller.document.groups["bottom"]?.activePanelID, "assets")
        XCTAssertEqual(controller.document.splitFractions.topBottom, 0.68, accuracy: 0.0001)
    }

    func testCenterRegionCannotCollapseEvenWithCollapsiblePanels() {
        let controller = WorkspaceController(document: makeDocument())

        _ = controller.dispatch(.movePanel("inspector",
                                           to: WorkspaceTarget(slot: .center,
                                                               groupID: "center",
                                                               placement: .tabGroup)))
        let result = controller.dispatch(.collapse("center"))

        XCTAssertFalse(result.didChange)
        XCTAssertEqual(controller.document.groups["center"]?.isCollapsed, false)
        XCTAssertEqual(controller.document.groups["center"]?.panels, ["viewport", "inspector"])
    }

    func testReorderPanelKeepsPinnedBoundary() {
        var document = makeDocument()
        document.panels["assets"] = WorkspacePanel(id: "assets", title: "Assets")
        document.groups["bottom"]?.panels = ["console", "assets"]
        document.groups["bottom"]?.activePanelID = "console"
        let controller = WorkspaceController(document: document)

        _ = controller.dispatch(.setPinned(panelID: "assets", isPinned: true))
        _ = controller.dispatch(.reorderPanel("console", in: "bottom", toIndex: 0))

        XCTAssertEqual(controller.document.groups["bottom"]?.pinnedPanelIDs, ["assets"])
        XCTAssertEqual(controller.document.groups["bottom"]?.panels, ["assets", "console"])

        _ = controller.dispatch(.reorderPanel("assets", in: "bottom", toIndex: 2))
        XCTAssertEqual(controller.document.groups["bottom"]?.panels, ["assets", "console"])
    }

    func testCloseReopenRestoresPanelAtOriginalGroupAndIndex() {
        var document = makeDocument()
        document.panels["assets"] = WorkspacePanel(id: "assets", title: "Assets")
        document.groups["bottom"]?.panels = ["console", "assets"]
        document.groups["bottom"]?.activePanelID = "assets"
        let controller = WorkspaceController(document: document)

        _ = controller.dispatch(.closePanel("console"))

        XCTAssertEqual(controller.document.groups["bottom"]?.panels, ["assets"])
        XCTAssertEqual(controller.document.closedHistory.last?.panelID, "console")

        _ = controller.dispatch(.reopenLastClosed)

        XCTAssertEqual(controller.document.groups["bottom"]?.panels, ["console", "assets"])
        XCTAssertEqual(controller.document.groups["bottom"]?.activePanelID, "console")
        XCTAssertTrue(controller.document.closedHistory.isEmpty)
    }

    func testCloseOthersKeepsPinnedTabsAndSelectedTab() {
        var document = makeDocument()
        document.panels["assets"] = WorkspacePanel(id: "assets", title: "Assets")
        document.groups["bottom"]?.panels = ["console", "assets"]
        document.groups["bottom"]?.pinnedPanelIDs = ["assets"]
        let controller = WorkspaceController(document: document)

        _ = controller.dispatch(.closeOthers(groupID: "bottom", keeping: "console"))

        XCTAssertEqual(controller.document.groups["bottom"]?.panels, ["console", "assets"])
        XCTAssertEqual(controller.document.groups["bottom"]?.activePanelID, "console")
        XCTAssertTrue(controller.document.closedHistory.isEmpty)
    }

    func testCloseToRightSkipsPinnedTabs() {
        var document = makeDocument()
        document.panels["assets"] = WorkspacePanel(id: "assets", title: "Assets")
        document.panels["timeline"] = WorkspacePanel(id: "timeline", title: "Timeline")
        document.groups["bottom"]?.panels = ["console", "assets", "timeline"]
        document.groups["bottom"]?.pinnedPanelIDs = ["timeline"]
        let controller = WorkspaceController(document: document)

        _ = controller.dispatch(.closeToTheRight(groupID: "bottom", of: "console"))

        XCTAssertEqual(controller.document.groups["bottom"]?.panels, ["console", "timeline"])
        XCTAssertEqual(controller.document.closedHistory.map(\.panelID), ["assets"])
    }

    func testUnclosablePanelCannotClose() {
        let controller = WorkspaceController(document: makeDocument())

        let result = controller.dispatch(.closePanel("viewport"))

        XCTAssertFalse(result.didChange)
        XCTAssertEqual(controller.document.groups["center"]?.panels, ["viewport"])
    }

    func testFloatGroupRemovesItFromRegionWithoutDestroyingTabs() {
        let controller = WorkspaceController(document: makeDocument())

        let result = controller.dispatch(.floatGroup("trailing",
                                                     windowID: "inspector-window",
                                                     frame: WorkspaceRect(x: 160, y: 120, width: 420, height: 320)))

        XCTAssertTrue(result.didChange)
        XCTAssertEqual(controller.document.slot(.trailing).layout?.leafGroupIDs ?? [], [])
        XCTAssertEqual(controller.document.groups["trailing"]?.panels, ["inspector"])
        XCTAssertEqual(controller.document.floatingWindows.first?.id, "inspector-window")
        XCTAssertEqual(controller.document.floatingWindows.first?.groupID, "trailing")
        XCTAssertEqual(controller.document.floatingWindows.first?.frame, WorkspaceRect(x: 160, y: 120, width: 420, height: 320))
    }

    func testRedockFloatingWindowRestoresGroupToTargetRegion() {
        let controller = WorkspaceController(document: makeDocument())

        _ = controller.dispatch(.floatGroup("trailing",
                                            windowID: "inspector-window",
                                            frame: WorkspaceRect(x: 160, y: 120, width: 420, height: 320)))
        let result = controller.dispatch(.redockFloatingWindow("inspector-window",
                                                               to: WorkspaceTarget(slot: .leading,
                                                                                   groupID: "leading",
                                                                                   placement: .split,
                                                               edge: .trailing)))

        XCTAssertTrue(result.persistenceDirty)
        XCTAssertTrue(controller.document.floatingWindows.isEmpty)
        XCTAssertEqual((controller.document.slot(.leading).layout?.leafGroupIDs ?? []).count, 2)
        XCTAssertEqual((controller.document.slot(.leading).layout?.leafGroupIDs ?? []).last, "trailing")
        XCTAssertEqual(controller.document.groups["trailing"]?.panels, ["inspector"])
    }

    func testMovePanelOutOfFloatingGroupDoesNotDuplicatePanel() {
        var document = makeDocument()
        document.panels["debugger"] = WorkspacePanel(id: "debugger", title: "Debugger")
        document.groups["trailing"]?.panels = ["inspector", "debugger"]
        let controller = WorkspaceController(document: document)

        _ = controller.dispatch(.floatGroup("trailing",
                                            windowID: "inspector-window",
                                            frame: WorkspaceRect()))
        _ = controller.dispatch(.movePanel("inspector",
                                           to: WorkspaceTarget(slot: .center,
                                                               groupID: "center",
                                                               placement: .tabGroup)))

        XCTAssertEqual(controller.document.groups["center"]?.panels, ["viewport", "inspector"])
        XCTAssertEqual(controller.document.groups["trailing"]?.panels, ["debugger"])
        XCTAssertEqual(controller.document.floatingWindows.first?.groupID, "trailing")
        XCTAssertEqual(controller.document.groups.values.filter { $0.panels.contains("inspector") }.count, 1)
    }

    func testMovingLastPanelOutOfFloatingWindowClosesTheWindowRecord() {
        let controller = WorkspaceController(document: makeDocument())

        _ = controller.dispatch(.floatGroup("trailing",
                                            windowID: "inspector-window",
                                            frame: WorkspaceRect()))
        _ = controller.dispatch(.movePanel("inspector",
                                           to: WorkspaceTarget(slot: .center,
                                                               groupID: "center",
                                                               placement: .tabGroup)))

        XCTAssertTrue(controller.document.floatingWindows.isEmpty)
        XCTAssertNil(controller.document.groups["trailing"])
        XCTAssertEqual(controller.document.groups["center"]?.panels, ["viewport", "inspector"])
    }

    func testFloatingWindowMoveAndFocusUpdateFrameAndZOrder() {
        let controller = WorkspaceController(document: makeDocument())

        _ = controller.dispatch(.floatGroup("leading",
                                            windowID: "hierarchy-window",
                                            frame: WorkspaceRect(x: 20, y: 20, width: 300, height: 240)))
        _ = controller.dispatch(.floatGroup("trailing",
                                            windowID: "inspector-window",
                                            frame: WorkspaceRect(x: 40, y: 40, width: 320, height: 260)))
        _ = controller.dispatch(.moveFloatingWindow("hierarchy-window",
                                                    frame: WorkspaceRect(x: 80, y: 90, width: 300, height: 240)))
        _ = controller.dispatch(.focusFloatingWindow("hierarchy-window"))

        let hierarchy = controller.document.floatingWindows.first { $0.id == "hierarchy-window" }
        let inspector = controller.document.floatingWindows.first { $0.id == "inspector-window" }
        XCTAssertEqual(hierarchy?.frame, WorkspaceRect(x: 80, y: 90, width: 300, height: 240))
        XCTAssertGreaterThan(hierarchy?.zIndex ?? 0, inspector?.zIndex ?? 0)
    }

    private func makeDocument() -> WorkspaceDocument {
        WorkspaceDocument(
            panels: [
                "hierarchy": WorkspacePanel(id: "hierarchy", title: "Hierarchy"),
                "viewport": WorkspacePanel(id: "viewport", title: "Viewport", isClosable: false),
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
            splitFractions: WorkspaceSplitFractions(leading: 0.24,
                                                    centerTrailing: 0.72,
                                                    topBottom: 0.68)
        )
    }
}
