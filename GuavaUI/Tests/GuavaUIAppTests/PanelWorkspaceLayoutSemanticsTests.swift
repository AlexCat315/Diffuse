import XCTest
@testable import GuavaUIApp
import GuavaUICompose

@MainActor
final class PanelWorkspaceLayoutSemanticsTests: XCTestCase {
    func testInstallNormalizesLegacyEditorTreeIntoCanonicalRegions() {
        let tabs = makeTabs()
        let registry = makeRegistry()
        let legacyRoot = DockLayoutNode.hsplit(
            fraction: 0.22,
            first: .tabs([tabs.hierarchy]),
            second: .hsplit(
                fraction: 0.78,
                first: .tabs([tabs.viewport, tabs.console], active: tabs.viewport.id),
                second: .tabs([tabs.inspector])
            )
        )
        let controller = DockController(root: legacyRoot)

        PanelWorkspaceLayoutSemantics.ide.install(on: controller, registry: registry)

        assertCanonicalEditorShell(controller.root,
                                   centerTabs: ["viewport"],
                                   bottomTabs: ["console"])
    }

    func testConsoleMoveSnapsBackToBottomRegion() {
        let tabs = makeTabs()
        let registry = makeRegistry()
        let controller = DockController(root: DockLayoutNode.hsplit(
            fraction: 0.22,
            first: .tabs([tabs.hierarchy]),
            second: .hsplit(
                fraction: 0.78,
                first: .vsplit(fraction: 0.72,
                               first: .tabs([tabs.viewport]),
                               second: .tabs([tabs.console])),
                second: .tabs([tabs.inspector])
            )
        ))

        PanelWorkspaceLayoutSemantics.ide.install(on: controller, registry: registry)

        guard let viewportLeafID = leafID(containing: "viewport", in: controller.root) else {
            XCTFail("missing viewport leaf")
            return
        }

        controller.apply(.move(tabID: tabs.console.id,
                               to: .splitEdge(target: viewportLeafID, edge: .top)))

        assertCanonicalEditorShell(controller.root,
                                   centerTabs: ["viewport"],
                                   bottomTabs: ["console"])
    }

    func testCanonicalFractionsSurviveCrossRegionCanonicalization() throws {
        let tabs = makeTabs()
        let registry = makeRegistry()
        let controller = DockController(root: DockLayoutNode.hsplit(
            fraction: 0.22,
            first: .tabs([tabs.hierarchy]),
            second: .hsplit(
                fraction: 0.78,
                first: .vsplit(fraction: 0.72,
                               first: .tabs([tabs.viewport]),
                               second: .tabs([tabs.console])),
                second: .tabs([tabs.inspector])
            )
        ))

        PanelWorkspaceLayoutSemantics.ide.install(on: controller, registry: registry)

        var splitIDs = try XCTUnwrap(canonicalSplitIDs(in: controller.root))
        controller.apply(.resizeSplit(node: splitIDs.leading, fraction: 0.30))
        splitIDs = try XCTUnwrap(canonicalSplitIDs(in: controller.root))
        controller.apply(.resizeSplit(node: splitIDs.main, fraction: 0.64))
        splitIDs = try XCTUnwrap(canonicalSplitIDs(in: controller.root))
        controller.apply(.resizeSplit(node: splitIDs.bottom, fraction: 0.58))

        guard let viewportLeafID = leafID(containing: "viewport", in: controller.root) else {
            XCTFail("missing viewport leaf")
            return
        }
        controller.apply(.move(tabID: tabs.console.id,
                               to: .splitEdge(target: viewportLeafID, edge: .top)))

        let fractions = try XCTUnwrap(canonicalFractions(in: controller.root))
        XCTAssertEqual(fractions.leading, 0.30, accuracy: 0.0001)
        XCTAssertEqual(fractions.main, 0.64, accuracy: 0.0001)
        XCTAssertEqual(fractions.bottom, 0.58, accuracy: 0.0001)
    }

    func testAllowDropAllowsCrossRegionPanelMoves() {
        let tabs = makeTabs()
        let registry = makeRegistry()
        let controller = DockController(root: DockLayoutNode.hsplit(
            fraction: 0.22,
            first: .tabs([tabs.hierarchy]),
            second: .hsplit(
                fraction: 0.78,
                first: .vsplit(fraction: 0.72,
                               first: .tabs([tabs.viewport]),
                               second: .tabs([tabs.console])),
                second: .tabs([tabs.inspector])
            )
        ))

        PanelWorkspaceLayoutSemantics.ide.install(on: controller, registry: registry)

        guard let viewportLeafID = leafID(containing: "viewport", in: controller.root) else {
            XCTFail("missing viewport leaf")
            return
        }
        let request = DockDropRequest(tabID: tabs.console.id,
                                      sourceLeafID: leafID(containing: "console", in: controller.root),
                                      origin: .mainTreeTab,
                                      target: .splitEdge(target: viewportLeafID, edge: .top))
        XCTAssertEqual(controller.onAllowDrop?(request), true)
    }

    func testCommittedCrossRegionDropMovesPanelToTargetRegion() {
        let tabs = makeTabs()
        let registry = makeRegistry()
        let controller = DockController(root: DockLayoutNode.hsplit(
            fraction: 0.22,
            first: .tabs([tabs.hierarchy]),
            second: .hsplit(
                fraction: 0.78,
                first: .vsplit(fraction: 0.72,
                               first: .tabs([tabs.viewport]),
                               second: .tabs([tabs.console])),
                second: .tabs([tabs.inspector])
            )
        ))

        PanelWorkspaceLayoutSemantics.ide.install(on: controller, registry: registry)

        guard let viewportLeafID = leafID(containing: "viewport", in: controller.root),
              let consoleLeafID = leafID(containing: "console", in: controller.root) else {
            XCTFail("missing expected leaves")
            return
        }
        let request = DockDropRequest(tabID: tabs.console.id,
                                      sourceLeafID: consoleLeafID,
                                      origin: .mainTreeTab,
                                      target: .tabSlot(parent: viewportLeafID, index: 1))

        controller.onCommitDrop?(request)
        controller.apply(.move(tabID: tabs.console.id, to: request.target))

        XCTAssertEqual(leafID(containing: "console", in: controller.root),
                       leafID(containing: "viewport", in: controller.root))
        XCTAssertEqual(tabKeys(inLeaf: viewportLeafID, root: controller.root), ["viewport", "console"])
    }

    func testReinstallKeepsCommittedCrossRegionPanelMove() {
        let tabs = makeTabs()
        let registry = makeRegistry()
        let controller = DockController(root: DockLayoutNode.hsplit(
            fraction: 0.22,
            first: .tabs([tabs.hierarchy]),
            second: .hsplit(
                fraction: 0.78,
                first: .vsplit(fraction: 0.72,
                               first: .tabs([tabs.viewport]),
                               second: .tabs([tabs.console])),
                second: .tabs([tabs.inspector])
            )
        ))

        PanelWorkspaceLayoutSemantics.ide.install(on: controller, registry: registry)

        guard let viewportLeafID = leafID(containing: "viewport", in: controller.root),
              let consoleLeafID = leafID(containing: "console", in: controller.root) else {
            XCTFail("missing expected leaves")
            return
        }
        let request = DockDropRequest(tabID: tabs.console.id,
                                      sourceLeafID: consoleLeafID,
                                      origin: .mainTreeTab,
                                      target: .tabSlot(parent: viewportLeafID, index: 1))

        controller.onCommitDrop?(request)
        controller.apply(.move(tabID: tabs.console.id, to: request.target))
        PanelWorkspaceLayoutSemantics.ide.install(on: controller, registry: registry)

        XCTAssertEqual(leafID(containing: "console", in: controller.root),
                       leafID(containing: "viewport", in: controller.root))
        XCTAssertEqual(tabKeys(inLeaf: viewportLeafID, root: controller.root), ["viewport", "console"])
    }

    func testAllowDropKeepsCenterRegionFlexible() {
        let tabs = makeTabs()
        let registry = makeRegistry()
        let controller = DockController(root: DockLayoutNode.hsplit(
            fraction: 0.22,
            first: .tabs([tabs.hierarchy]),
            second: .hsplit(
                fraction: 0.78,
                first: .vsplit(fraction: 0.72,
                               first: .tabs([tabs.viewport]),
                               second: .tabs([tabs.console])),
                second: .tabs([tabs.inspector])
            )
        ))

        PanelWorkspaceLayoutSemantics.ide.install(on: controller, registry: registry)

        guard let viewportLeafID = leafID(containing: "viewport", in: controller.root) else {
            XCTFail("missing viewport leaf")
            return
        }
        let request = DockDropRequest(tabID: tabs.viewport.id,
                                      sourceLeafID: viewportLeafID,
                                      origin: .mainTreeTab,
                                      target: .splitEdge(target: viewportLeafID, edge: .right))
        XCTAssertEqual(controller.onAllowDrop?(request), true)
    }

    func testAllowDropKeepsPanelRegionGuidesInteractive() {
        let tabs = makeTabs()
        let registry = makeRegistry()
        let controller = DockController(root: DockLayoutNode.hsplit(
            fraction: 0.22,
            first: .tabs([tabs.hierarchy]),
            second: .hsplit(
                fraction: 0.78,
                first: .vsplit(fraction: 0.72,
                               first: .tabs([tabs.viewport]),
                               second: .tabs([tabs.console])),
                second: .tabs([tabs.inspector])
            )
        ))

        PanelWorkspaceLayoutSemantics.ide.install(on: controller, registry: registry)

        guard let consoleLeafID = leafID(containing: "console", in: controller.root) else {
            XCTFail("missing console leaf")
            return
        }
        let request = DockDropRequest(tabID: tabs.console.id,
                                      sourceLeafID: consoleLeafID,
                                      origin: .mainTreeTab,
                                      target: .splitEdge(target: consoleLeafID, edge: .left))
        XCTAssertEqual(controller.onAllowDrop?(request), true)
    }

    func testSemanticRegionLeafIDsStayStableAcrossCanonicalization() {
        let tabs = makeTabs()
        let registry = makeRegistry()
        let controller = DockController(root: DockLayoutNode.hsplit(
            fraction: 0.22,
            first: .tabs([tabs.hierarchy]),
            second: .hsplit(
                fraction: 0.78,
                first: .tabs([tabs.viewport, tabs.console], active: tabs.viewport.id),
                second: .tabs([tabs.inspector])
            )
        ))

        PanelWorkspaceLayoutSemantics.ide.install(on: controller, registry: registry)

        let beforeHierarchy = leafID(containing: "hierarchy", in: controller.root)
        let beforeViewport = leafID(containing: "viewport", in: controller.root)
        let beforeInspector = leafID(containing: "inspector", in: controller.root)
        let beforeConsole = leafID(containing: "console", in: controller.root)

        guard let viewportLeafID = beforeViewport else {
            XCTFail("missing viewport leaf")
            return
        }

        controller.apply(.move(tabID: tabs.console.id,
                               to: .splitEdge(target: viewportLeafID, edge: .top)))

        XCTAssertEqual(leafID(containing: "hierarchy", in: controller.root), beforeHierarchy)
        XCTAssertEqual(leafID(containing: "viewport", in: controller.root), beforeViewport)
        XCTAssertEqual(leafID(containing: "inspector", in: controller.root), beforeInspector)
        XCTAssertEqual(leafID(containing: "console", in: controller.root), beforeConsole)
    }

    func testReinstallKeepsUserResizedFractions() throws {
        let tabs = makeTabs()
        let registry = makeRegistry()
        let controller = DockController(root: DockLayoutNode.hsplit(
            fraction: 0.22,
            first: .tabs([tabs.hierarchy]),
            second: .hsplit(
                fraction: 0.78,
                first: .vsplit(fraction: 0.72,
                               first: .tabs([tabs.viewport]),
                               second: .tabs([tabs.console])),
                second: .tabs([tabs.inspector])
            )
        ))

        PanelWorkspaceLayoutSemantics.ide.install(on: controller, registry: registry)

        var splitIDs = try XCTUnwrap(canonicalSplitIDs(in: controller.root))
        controller.apply(.resizeSplit(node: splitIDs.leading, fraction: 0.31))
        splitIDs = try XCTUnwrap(canonicalSplitIDs(in: controller.root))
        controller.apply(.resizeSplit(node: splitIDs.main, fraction: 0.66))
        splitIDs = try XCTUnwrap(canonicalSplitIDs(in: controller.root))
        controller.apply(.resizeSplit(node: splitIDs.bottom, fraction: 0.57))

        // Simulate PanelWorkspace view re-init which re-installs semantics.
        PanelWorkspaceLayoutSemantics.ide.install(on: controller, registry: registry)

        let fractions = try XCTUnwrap(canonicalFractions(in: controller.root))
        XCTAssertEqual(fractions.leading, 0.31, accuracy: 0.0001)
        XCTAssertEqual(fractions.main, 0.66, accuracy: 0.0001)
        XCTAssertEqual(fractions.bottom, 0.57, accuracy: 0.0001)
    }

    func testMinimizePolicyMapsRegionsToRailsAndRestoresCanonicalShell() {
        let tabs = makeTabs()
        let registry = makeRegistry()
        let controller = DockController(root: DockLayoutNode.hsplit(
            fraction: 0.22,
            first: .tabs([tabs.hierarchy]),
            second: .hsplit(
                fraction: 0.78,
                first: .vsplit(fraction: 0.72,
                               first: .tabs([tabs.viewport]),
                               second: .tabs([tabs.console])),
                second: .tabs([tabs.inspector])
            )
        ))

        PanelWorkspaceLayoutSemantics.ide.install(on: controller, registry: registry)

        guard let hierarchyLeafID = leafID(containing: "hierarchy", in: controller.root),
              let viewportLeafID = leafID(containing: "viewport", in: controller.root),
              let consoleLeafID = leafID(containing: "console", in: controller.root) else {
            XCTFail("missing expected leaves")
            return
        }

        XCTAssertEqual(controller.onResolveMinimizedEdge?(hierarchyLeafID), .left)
        XCTAssertNil(controller.onResolveMinimizedEdge?(viewportLeafID))
        XCTAssertEqual(controller.onResolveMinimizedEdge?(consoleLeafID), .bottom)

        controller.apply(.minimizeLeaf(leafID: hierarchyLeafID, edge: .left))
        XCTAssertNil(leafID(containing: "hierarchy", in: controller.root))
        XCTAssertEqual(controller.minimizedLeaves[hierarchyLeafID]?.edge, .left)

        controller.apply(.restoreMinimizedLeaf(hierarchyLeafID))
        assertCanonicalEditorShell(controller.root,
                                   centerTabs: ["viewport"],
                                   bottomTabs: ["console"])
        XCTAssertEqual(leafID(containing: "hierarchy", in: controller.root), hierarchyLeafID)
    }

    func testMinimizeRestoreKeepsUserResizedFractions() throws {
        let tabs = makeTabs()
        let registry = makeRegistry()
        let controller = DockController(root: DockLayoutNode.hsplit(
            fraction: 0.22,
            first: .tabs([tabs.hierarchy]),
            second: .hsplit(
                fraction: 0.78,
                first: .vsplit(fraction: 0.72,
                               first: .tabs([tabs.viewport]),
                               second: .tabs([tabs.console])),
                second: .tabs([tabs.inspector])
            )
        ))

        PanelWorkspaceLayoutSemantics.ide.install(on: controller, registry: registry)

        var splitIDs = try XCTUnwrap(canonicalSplitIDs(in: controller.root))
        controller.apply(.resizeSplit(node: splitIDs.leading, fraction: 0.31))
        splitIDs = try XCTUnwrap(canonicalSplitIDs(in: controller.root))
        controller.apply(.resizeSplit(node: splitIDs.main, fraction: 0.66))
        splitIDs = try XCTUnwrap(canonicalSplitIDs(in: controller.root))
        controller.apply(.resizeSplit(node: splitIDs.bottom, fraction: 0.57))

        guard let hierarchyLeafID = leafID(containing: "hierarchy", in: controller.root),
              let consoleLeafID = leafID(containing: "console", in: controller.root) else {
            XCTFail("missing expected leaves")
            return
        }

        controller.apply(.minimizeLeaf(leafID: hierarchyLeafID, edge: .left))
        controller.apply(.restoreMinimizedLeaf(hierarchyLeafID))
        var fractions = try XCTUnwrap(canonicalFractions(in: controller.root))
        XCTAssertEqual(fractions.leading, 0.31, accuracy: 0.0001)
        XCTAssertEqual(fractions.main, 0.66, accuracy: 0.0001)
        XCTAssertEqual(fractions.bottom, 0.57, accuracy: 0.0001)

        controller.apply(.minimizeLeaf(leafID: consoleLeafID, edge: .bottom))
        controller.apply(.restoreMinimizedLeaf(consoleLeafID))
        fractions = try XCTUnwrap(canonicalFractions(in: controller.root))
        XCTAssertEqual(fractions.leading, 0.31, accuracy: 0.0001)
        XCTAssertEqual(fractions.main, 0.66, accuracy: 0.0001)
        XCTAssertEqual(fractions.bottom, 0.57, accuracy: 0.0001)
    }

    func testReinstallPreservesMinimizedLeaves() {
        let tabs = makeTabs()
        let registry = makeRegistry()
        let controller = DockController(root: DockLayoutNode.hsplit(
            fraction: 0.22,
            first: .tabs([tabs.hierarchy]),
            second: .hsplit(
                fraction: 0.78,
                first: .vsplit(fraction: 0.72,
                               first: .tabs([tabs.viewport]),
                               second: .tabs([tabs.console])),
                second: .tabs([tabs.inspector])
            )
        ))

        PanelWorkspaceLayoutSemantics.ide.install(on: controller, registry: registry)
        guard let hierarchyLeafID = leafID(containing: "hierarchy", in: controller.root) else {
            XCTFail("missing hierarchy leaf")
            return
        }

        controller.apply(.minimizeLeaf(leafID: hierarchyLeafID, edge: .left))
        PanelWorkspaceLayoutSemantics.ide.install(on: controller, registry: registry)

        XCTAssertEqual(controller.minimizedLeaves[hierarchyLeafID]?.edge, .left)
        XCTAssertEqual(controller.minimizedOrder, [hierarchyLeafID])
        XCTAssertNil(leafID(containing: "hierarchy", in: controller.root))
    }

    private func makeRegistry() -> PanelRegistry {
        PanelRegistry([
            PanelDescriptor(id: "hierarchy",
                            title: "Hierarchy",
                            preferredRegion: .leadingSidebar) {
                EmptyView()
            },
            PanelDescriptor(id: "viewport",
                            title: "Viewport",
                            closable: false,
                            preferredRegion: .center) {
                EmptyView()
            },
            PanelDescriptor(id: "inspector",
                            title: "Inspector",
                            preferredRegion: .trailingSidebar) {
                EmptyView()
            },
            PanelDescriptor(id: "console",
                            title: "Console",
                            preferredRegion: .bottomPanel) {
                EmptyView()
            },
        ])
    }

    private func makeTabs() -> (hierarchy: DockTab,
                                 viewport: DockTab,
                                 inspector: DockTab,
                                 console: DockTab) {
        (
            hierarchy: DockTab(userKey: "hierarchy", title: "Hierarchy"),
            viewport: DockTab(userKey: "viewport", title: "Viewport", isClosable: false),
            inspector: DockTab(userKey: "inspector", title: "Inspector"),
            console: DockTab(userKey: "console", title: "Console")
        )
    }

    private func assertCanonicalEditorShell(_ root: DockLayoutNode,
                                            centerTabs: [String],
                                            bottomTabs: [String]) {
        guard case .split(_, .horizontal, _, let leading, let workspace) = root,
              case .tabs(_, let leadingTabs, _) = leading,
              case .split(_, .horizontal, _, let main, let trailing) = workspace,
              case .split(_, .vertical, _, let center, let bottom) = main,
              case .tabs(_, let centerLeafTabs, _) = center,
              case .tabs(_, let bottomLeafTabs, _) = bottom,
              case .tabs(_, let trailingTabs, _) = trailing else {
            XCTFail("expected canonical editor shell")
            return
        }

        XCTAssertEqual(leadingTabs.map(\.userKey), ["hierarchy"])
        XCTAssertEqual(centerLeafTabs.map(\.userKey), centerTabs)
        XCTAssertEqual(bottomLeafTabs.map(\.userKey), bottomTabs)
        XCTAssertEqual(trailingTabs.map(\.userKey), ["inspector"])
    }

    private func leafID(containing userKey: String,
                        in node: DockLayoutNode) -> DockNodeID? {
        switch node {
        case .empty:
            return nil
        case .tabs(let id, let tabs, _):
            return tabs.contains(where: { $0.userKey == userKey }) ? id : nil
        case .split(_, _, _, let first, let second):
            return leafID(containing: userKey, in: first)
                ?? leafID(containing: userKey, in: second)
        }
    }

    private func tabKeys(inLeaf leafID: DockNodeID,
                         root: DockLayoutNode) -> [String] {
        guard let node = root.find(leafID) else { return [] }
        switch node {
        case .tabs(_, let tabs, _):
            return tabs.map(\.userKey)
        case .empty, .split:
            return []
        }
    }

    private func canonicalSplitIDs(in root: DockLayoutNode) -> (leading: DockNodeID, main: DockNodeID, bottom: DockNodeID)? {
        guard case .split(let leadingID, .horizontal, _, _, let workspace) = root,
              case .split(let mainID, .horizontal, _, let main, _) = workspace,
              case .split(let bottomID, .vertical, _, _, _) = main else {
            return nil
        }
        return (leading: leadingID, main: mainID, bottom: bottomID)
    }

    private func canonicalFractions(in root: DockLayoutNode) -> (leading: Float, main: Float, bottom: Float)? {
        guard case .split(_, .horizontal, let leadingFraction, _, let workspace) = root,
              case .split(_, .horizontal, let mainFraction, let main, _) = workspace,
              case .split(_, .vertical, let bottomFraction, _, _) = main else {
            return nil
        }
        return (leading: leadingFraction, main: mainFraction, bottom: bottomFraction)
    }
}
