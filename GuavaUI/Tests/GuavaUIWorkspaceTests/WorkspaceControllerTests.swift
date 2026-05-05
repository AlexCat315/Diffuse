import XCTest
import GuavaUIWorkspace

final class WorkspaceControllerTests: XCTestCase {
    func testCollapseExpandLeftRightBottomInAnyOrderPreservesRegions() {
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
        XCTAssertEqual(controller.document.region(.leading).groupIDs, ["leading"])
        XCTAssertEqual(controller.document.region(.trailing).groupIDs, ["trailing"])
        XCTAssertEqual(controller.document.region(.bottom).groupIDs, ["bottom"])

        _ = controller.dispatch(.expand("bottom"))
        _ = controller.dispatch(.expand("trailing"))
        _ = controller.dispatch(.expand("leading"))

        XCTAssertFalse(controller.document.groups["leading"]?.isCollapsed == true)
        XCTAssertFalse(controller.document.groups["trailing"]?.isCollapsed == true)
        XCTAssertFalse(controller.document.groups["bottom"]?.isCollapsed == true)
        XCTAssertEqual(controller.document.splitFractions.leading, 0.24, accuracy: 0.0001)
        XCTAssertEqual(controller.document.splitFractions.topBottom, 0.68, accuracy: 0.0001)
    }

    func testMovePanelIntoAnotherGroupDoesNotRebuildRegions() {
        let controller = WorkspaceController(document: makeDocument())

        let result = controller.dispatch(.movePanel("inspector",
                                                    to: WorkspaceTarget(region: .center,
                                                                        groupID: "center",
                                                                        zone: .tabGroup)))

        XCTAssertTrue(result.persistenceDirty)
        XCTAssertEqual(controller.document.groups["center"]?.panels, ["viewport", "inspector"])
        XCTAssertEqual(controller.document.groups["center"]?.activePanelID, "inspector")
        XCTAssertNil(controller.document.groups["trailing"])
        XCTAssertEqual(controller.document.region(.trailing).groupIDs, [])
        XCTAssertEqual(controller.document.region(.bottom).groupIDs, ["bottom"])

        _ = controller.dispatch(.movePanel("inspector",
                                           to: WorkspaceTarget(region: .trailing,
                                                               groupID: "trailing",
                                                               zone: .tabGroup)))

        XCTAssertEqual(controller.document.region(.trailing).groupIDs, ["trailing"])
        XCTAssertEqual(controller.document.groups["trailing"]?.panels, ["inspector"])
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
                                           to: WorkspaceTarget(region: .center,
                                                               groupID: "center",
                                                               zone: .tabGroup)))
        let result = controller.dispatch(.collapse("center"))

        XCTAssertFalse(result.didChange)
        XCTAssertEqual(controller.document.groups["center"]?.isCollapsed, false)
        XCTAssertEqual(controller.document.groups["center"]?.panels, ["viewport", "inspector"])
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
            regions: [
                WorkspaceRegion(id: .leading, groupIDs: ["leading"]),
                WorkspaceRegion(id: .center, groupIDs: ["center"]),
                WorkspaceRegion(id: .trailing, groupIDs: ["trailing"]),
                WorkspaceRegion(id: .bottom, groupIDs: ["bottom"]),
            ],
            splitFractions: WorkspaceSplitFractions(leading: 0.24,
                                                    centerTrailing: 0.72,
                                                    topBottom: 0.68)
        )
    }
}
