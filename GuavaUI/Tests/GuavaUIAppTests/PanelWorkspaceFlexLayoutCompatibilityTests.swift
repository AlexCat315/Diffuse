import XCTest
@testable import GuavaUICompose

@MainActor
final class PanelWorkspaceFlexLayoutCompatibilityTests: XCTestCase {
    func testMovingConsoleIntoViewportCollapsesBottomTabset() {
        let tabs = makeTabs()
        let controller = makeEditorLikeController(tabs: tabs)

        guard let viewportLeafID = leafID(containing: tabs.viewport.id, in: controller.root) else {
            XCTFail("missing viewport leaf")
            return
        }

        controller.apply(.move(tabID: tabs.console.id,
                               to: .replace(target: viewportLeafID)))

        guard case .split(_, .horizontal, _, let left, let remainder) = controller.root,
              case .tabs(_, let leftTabs, _) = left,
              case .split(_, .horizontal, _, let viewportAndConsole, let right) = remainder,
              case .tabs(_, let mergedTabs, let activeMerged) = viewportAndConsole,
              case .tabs(_, let rightTabs, _) = right else {
            XCTFail("expected bottom tabset to collapse after moving its only tab")
            return
        }

        XCTAssertEqual(leftTabs.map(\.userKey), ["hierarchy"])
        XCTAssertEqual(mergedTabs.map(\.userKey), ["viewport", "console"])
        XCTAssertEqual(activeMerged, tabs.console.id)
        XCTAssertEqual(rightTabs.map(\.userKey), ["inspector"])
    }

    func testMovingHierarchyIntoBottomCollapsesLeftTabset() {
        let tabs = makeTabs()
        let controller = makeEditorLikeController(tabs: tabs)

        guard let bottomLeafID = leafID(containing: tabs.console.id, in: controller.root) else {
            XCTFail("missing bottom leaf")
            return
        }

        controller.apply(.move(tabID: tabs.hierarchy.id,
                               to: .replace(target: bottomLeafID)))

        guard case .split(_, .vertical, _, let topRow, let bottom) = controller.root,
              case .split(_, .horizontal, _, let viewport, let right) = topRow,
              case .tabs(_, let viewportTabs, _) = viewport,
              case .tabs(_, let bottomTabs, let bottomActive) = bottom,
              case .tabs(_, let rightTabs, _) = right else {
            XCTFail("expected left tabset to collapse after moving its only tab")
            return
        }

        XCTAssertEqual(viewportTabs.map(\.userKey), ["viewport"])
        XCTAssertEqual(bottomTabs.map(\.userKey), ["console", "hierarchy"])
        XCTAssertEqual(bottomActive, tabs.hierarchy.id)
        XCTAssertEqual(rightTabs.map(\.userKey), ["inspector"])
    }

    func testMovingInspectorIntoViewportCollapsesRightTabset() {
        let tabs = makeTabs()
        let controller = makeEditorLikeController(tabs: tabs)

        guard let viewportLeafID = leafID(containing: tabs.viewport.id, in: controller.root) else {
            XCTFail("missing viewport leaf")
            return
        }

        controller.apply(.move(tabID: tabs.inspector.id,
                               to: .replace(target: viewportLeafID)))

        guard case .split(_, .vertical, _, let topRow, let bottom) = controller.root,
              case .split(_, .horizontal, _, let left, let remainder) = topRow,
              case .tabs(_, let leftTabs, _) = left,
              case .tabs(_, let viewportTabs, let activeViewport) = remainder,
              case .tabs(_, let bottomTabs, _) = bottom else {
            XCTFail("expected right tabset to collapse after moving its only tab")
            return
        }

        XCTAssertEqual(leftTabs.map(\.userKey), ["hierarchy"])
        XCTAssertEqual(viewportTabs.map(\.userKey), ["viewport", "inspector"])
        XCTAssertEqual(activeViewport, tabs.inspector.id)
        XCTAssertEqual(bottomTabs.map(\.userKey), ["console"])
    }

    func testMovingInspectorToViewportLeftCollapsesRightAndKeepsBottomIntact() {
        let tabs = makeTabs()
        let controller = makeEditorLikeController(tabs: tabs)

        guard let viewportLeafID = leafID(containing: tabs.viewport.id, in: controller.root) else {
            XCTFail("missing viewport leaf")
            return
        }

        controller.apply(.move(tabID: tabs.inspector.id,
                               to: .splitEdge(target: viewportLeafID, edge: .left)))

        guard case .split(_, .vertical, _, let topRow, let bottom) = controller.root,
              case .split(_, .horizontal, _, let left, let remainder) = topRow,
              case .tabs(_, let leftTabs, _) = left,
              case .split(_, .horizontal, _, let inspectorLeaf, let viewportLeaf) = remainder,
              case .tabs(_, let inspectorTabs, let activeInspector) = inspectorLeaf,
              case .tabs(_, let viewportTabs, _) = viewportLeaf,
              case .tabs(_, let bottomTabs, _) = bottom else {
            XCTFail("expected the top row to expand left of viewport and the source right tabset to collapse")
            return
        }

        XCTAssertEqual(leftTabs.map(\.userKey), ["hierarchy"])
        XCTAssertEqual(inspectorTabs.map(\.userKey), ["inspector"])
        XCTAssertEqual(activeInspector, tabs.inspector.id)
        XCTAssertEqual(viewportTabs.map(\.userKey), ["viewport"])
        XCTAssertEqual(bottomTabs.map(\.userKey), ["console"])
    }

    func testMovingConsoleToViewportRightCollapsesBottomAndExpandsTopRow() {
        let tabs = makeTabs()
        let controller = makeEditorLikeController(tabs: tabs)

        guard let viewportLeafID = leafID(containing: tabs.viewport.id, in: controller.root) else {
            XCTFail("missing viewport leaf")
            return
        }

        controller.apply(.move(tabID: tabs.console.id,
                               to: .splitEdge(target: viewportLeafID, edge: .right)))

        guard case .split(_, .horizontal, _, let left, let remainder) = controller.root,
              case .tabs(_, let leftTabs, _) = left,
              case .split(_, .horizontal, _, let viewportSlice, let right) = remainder,
              case .split(_, .horizontal, _, let viewportLeaf, let consoleLeaf) = viewportSlice,
              case .tabs(_, let viewportTabs, let activeViewport) = viewportLeaf,
              case .tabs(_, let consoleTabs, let activeConsole) = consoleLeaf,
              case .tabs(_, let rightTabs, _) = right else {
            XCTFail("expected bottom tabset to collapse and the top row to expand")
            return
        }

        XCTAssertEqual(leftTabs.map(\.userKey), ["hierarchy"])
        XCTAssertEqual(viewportTabs.map(\.userKey), ["viewport"])
        XCTAssertEqual(activeViewport, tabs.viewport.id)
        XCTAssertEqual(consoleTabs.map(\.userKey), ["console"])
        XCTAssertEqual(activeConsole, tabs.console.id)
        XCTAssertEqual(rightTabs.map(\.userKey), ["inspector"])
    }

    func testMovingConsoleToViewportBottomCollapsesBottomAndSplitsViewportAreaOnly() {
        let tabs = makeTabs()
        let controller = makeEditorLikeController(tabs: tabs)

        guard let viewportLeafID = leafID(containing: tabs.viewport.id, in: controller.root) else {
            XCTFail("missing viewport leaf")
            return
        }

        controller.apply(.move(tabID: tabs.console.id,
                               to: .splitEdge(target: viewportLeafID, edge: .bottom)))

        guard case .split(_, .horizontal, _, let left, let remainder) = controller.root,
              case .tabs(_, let leftTabs, _) = left,
              case .split(_, .horizontal, _, let centerArea, let right) = remainder,
              case .split(_, .vertical, _, let viewportLeaf, let consoleLeaf) = centerArea,
              case .tabs(_, let viewportTabs, _) = viewportLeaf,
              case .tabs(_, let consoleTabs, let activeConsole) = consoleLeaf,
              case .tabs(_, let rightTabs, _) = right else {
            XCTFail("expected bottom tabset to collapse and only the viewport area to split vertically")
            return
        }

        XCTAssertEqual(leftTabs.map(\.userKey), ["hierarchy"])
        XCTAssertEqual(viewportTabs.map(\.userKey), ["viewport"])
        XCTAssertEqual(consoleTabs.map(\.userKey), ["console"])
        XCTAssertEqual(activeConsole, tabs.console.id)
        XCTAssertEqual(rightTabs.map(\.userKey), ["inspector"])
    }

    func testMovingConsoleToViewportTopCollapsesBottomAndSplitsViewportAreaOnly() {
        let tabs = makeTabs()
        let controller = makeEditorLikeController(tabs: tabs)

        guard let viewportLeafID = leafID(containing: tabs.viewport.id, in: controller.root) else {
            XCTFail("missing viewport leaf")
            return
        }

        controller.apply(.move(tabID: tabs.console.id,
                               to: .splitEdge(target: viewportLeafID, edge: .top)))

        guard case .split(_, .horizontal, _, let left, let remainder) = controller.root,
              case .tabs(_, let leftTabs, _) = left,
              case .split(_, .horizontal, _, let centerArea, let right) = remainder,
              case .split(_, .vertical, _, let consoleLeaf, let viewportLeaf) = centerArea,
              case .tabs(_, let consoleTabs, let activeConsole) = consoleLeaf,
              case .tabs(_, let viewportTabs, _) = viewportLeaf,
              case .tabs(_, let rightTabs, _) = right else {
            XCTFail("expected bottom tabset to collapse and only the viewport area to split above the viewport")
            return
        }

        XCTAssertEqual(leftTabs.map(\.userKey), ["hierarchy"])
        XCTAssertEqual(consoleTabs.map(\.userKey), ["console"])
        XCTAssertEqual(activeConsole, tabs.console.id)
        XCTAssertEqual(viewportTabs.map(\.userKey), ["viewport"])
        XCTAssertEqual(rightTabs.map(\.userKey), ["inspector"])
    }

    private func makeEditorLikeController(tabs: (hierarchy: DockTab,
                                                 viewport: DockTab,
                                                 inspector: DockTab,
                                                 console: DockTab)) -> DockController {
        let hierarchyLeaf = DockLayoutNode.tabs([tabs.hierarchy])
        let inspectorLeaf = DockLayoutNode.tabs([tabs.inspector])
        let viewportLeaf = DockLayoutNode.tabs([tabs.viewport])
        let consoleLeaf = DockLayoutNode.tabs([tabs.console])
        let viewportAndInspector = DockLayoutNode.hsplit(fraction: 55.0 / 75.0,
                                                         first: viewportLeaf,
                                                         second: inspectorLeaf)
        let topRow = DockLayoutNode.hsplit(fraction: 15.0 / 90.0,
                                           first: hierarchyLeaf,
                                           second: viewportAndInspector)
        return DockController(root: .vsplit(fraction: 0.7,
                                            first: topRow,
                                            second: consoleLeaf))
    }

    private func makeTabs() -> (hierarchy: DockTab,
                                 viewport: DockTab,
                                 inspector: DockTab,
                                 console: DockTab) {
        (
            hierarchy: DockTab(userKey: "hierarchy", title: "Hierarchy"),
            viewport: DockTab(userKey: "viewport",
                              title: "Viewport",
                              isDraggable: false,
                              isClosable: false),
            inspector: DockTab(userKey: "inspector", title: "Inspector"),
            console: DockTab(userKey: "console", title: "Console")
        )
    }

    private func leafID(containing tabID: DockTabID,
                        in node: DockLayoutNode) -> DockNodeID? {
        switch node {
        case .empty:
            return nil
        case .tabs(let id, let tabs, _):
            return tabs.contains(where: { $0.id == tabID }) ? id : nil
        case .split(_, _, _, let first, let second):
            return leafID(containing: tabID, in: first) ?? leafID(containing: tabID, in: second)
        }
    }
}