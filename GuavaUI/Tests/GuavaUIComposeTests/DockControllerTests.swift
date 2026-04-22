import Foundation
import Testing
@testable import GuavaUICompose

@Suite("Phase D0 DockController")
struct DockControllerTests {

    // MARK: Helpers

    private func makeBasicTree() -> (DockController, DockTab, DockTab, DockNodeID, DockNodeID) {
        let tabA = DockTab(userKey: "a", title: "A")
        let tabB = DockTab(userKey: "b", title: "B")
        let leafA = DockLayoutNode.tabs([tabA])
        let leafB = DockLayoutNode.tabs([tabB])
        let leafAID = leafA.id
        let leafBID = leafB.id
        let root = DockLayoutNode.hsplit(first: leafA, second: leafB)
        return (DockController(root: root), tabA, tabB, leafAID, leafBID)
    }

    // MARK: insertTab

    @Test("insertTab appends into a tabs leaf and seeds active when none")
    func insertTabIntoEmpty() {
        let empty = DockLayoutNode.empty()
        let controller = DockController(root: empty)
        let tab = DockTab(userKey: "x", title: "X")
        controller.apply(.insertTab(tab, into: empty.id, at: 0))
        guard case .tabs(let id, let tabs, let active) = controller.root else {
            Issue.record("expected tabs leaf after insert into empty"); return
        }
        #expect(id == empty.id)
        #expect(tabs == [tab])
        #expect(active == tab.id)
        #expect(controller.version == 1)
    }

    // MARK: move — same-leaf reorder

    @Test("move within the same tabs leaf reorders")
    func moveSameLeafReorder() {
        let tabA = DockTab(userKey: "a", title: "A")
        let tabB = DockTab(userKey: "b", title: "B")
        let leaf = DockLayoutNode.tabs([tabA, tabB])
        let leafID = leaf.id
        let controller = DockController(root: leaf)

        controller.apply(.move(tabID: tabA.id,
                               to: .tabSlot(parent: leafID, index: 2)))
        guard case .tabs(_, let tabs, let active) = controller.root else {
            Issue.record("expected tabs leaf"); return
        }
        #expect(tabs.map(\.id) == [tabB.id, tabA.id])
        #expect(active == tabA.id)
    }

    // MARK: move — across leaves with collapse

    @Test("Moving the only tab from a leaf collapses the parent split")
    func moveCollapsesEmptyLeaf() {
        let (controller, tabA, _, _, leafBID) = makeBasicTree()
        controller.apply(.move(tabID: tabA.id,
                               to: .tabSlot(parent: leafBID, index: 1)))
        // Source leaf had only tabA; removing it makes that side empty,
        // collapsing the split to leafB-only with both tabs.
        guard case .tabs(_, let tabs, _) = controller.root else {
            Issue.record("expected collapsed leaf as new root, got \(controller.root)")
            return
        }
        #expect(tabs.count == 2)
        #expect(tabs.map(\.userKey) == ["b", "a"])
    }

    // MARK: move — splitEdge

    @Test("Center drop merges into the target leaf instead of replacing it")
    func moveReplaceMergesIntoLeaf() {
        let tabA = DockTab(userKey: "a", title: "A")
        let tabB = DockTab(userKey: "b", title: "B")
        let leafA = DockLayoutNode.tabs([tabA])
        let leafB = DockLayoutNode.tabs([tabB])
        let leafBID = leafB.id
        let controller = DockController(root: .hsplit(first: leafA, second: leafB))

        controller.apply(.move(tabID: tabA.id,
                               to: .replace(target: leafBID)))

        guard case .tabs(let id, let tabs, let active) = controller.root else {
            Issue.record("expected merged tabs leaf as root, got \(controller.root)")
            return
        }
        #expect(id == leafBID)
        #expect(tabs.map(\.id) == [tabB.id, tabA.id])
        #expect(active == tabA.id)
    }

    @Test("splitEdge wraps the target leaf in a new split")
    func moveSplitEdge() {
        let tabA = DockTab(userKey: "a", title: "A")
        let tabB = DockTab(userKey: "b", title: "B")
        let leafA = DockLayoutNode.tabs([tabA])
        let leafB = DockLayoutNode.tabs([tabB])
        let leafAID = leafA.id
        let root = DockLayoutNode.hsplit(first: leafA, second: leafB)
        let controller = DockController(root: root)

        controller.apply(.move(tabID: tabB.id,
                               to: .splitEdge(target: leafAID, edge: .bottom)))
        // leafA is now wrapped in a vertical split, leafA on top, the new
        // leaf with tabB on bottom; the right side of the original split
        // collapsed because tabB was the only tab in leafB.
        guard case .split(_, let outerAxis, _, let outerFirst, _) = controller.root else {
            Issue.record("expected outer split, got \(controller.root)"); return
        }
        // After collapsing the right side, the root could be either the new
        // vertical split alone or the original horizontal split. The relevant
        // assertion is that we now have a vertical split somewhere.
        if outerAxis == .vertical {
            #expect(outerFirst.id == leafAID)
        } else {
            // The original horizontal split survived because the right side
            // got the new vertical split. Walk one more level.
            guard case .split(_, _, _, _, let outerSecond) = controller.root,
                  case .split(_, let innerAxis, _, let innerFirst, _) = outerSecond
            else {
                Issue.record("expected vertical split nested on the right"); return
            }
            #expect(innerAxis == .vertical)
            #expect(innerFirst.id == leafAID || innerFirst.collectTabIDs().contains(tabA.id))
        }

        // The moved tab is present somewhere in the tree.
        #expect(controller.root.collectTabIDs().contains(tabB.id))
        #expect(controller.root.collectTabIDs().contains(tabA.id))
    }

    @Test("Bottom drop on a side-by-side strip splits the whole strip, not only the target leaf")
    func moveBottomEdgePromotesAcrossHorizontalStrip() {
        let hierarchy = DockTab(userKey: "hierarchy", title: "Hierarchy")
        let viewport = DockTab(userKey: "viewport", title: "Viewport")
        let console = DockTab(userKey: "console", title: "Console")
        let inspector = DockTab(userKey: "inspector", title: "Inspector")

        let leftLeaf = DockLayoutNode.tabs([hierarchy])
        let viewportLeaf = DockLayoutNode.tabs([viewport, console])
        let inspectorLeaf = DockLayoutNode.tabs([inspector])
        let workspaceStrip = DockLayoutNode.hsplit(first: viewportLeaf, second: inspectorLeaf)
        let controller = DockController(root: .hsplit(first: leftLeaf, second: workspaceStrip))

        controller.apply(.move(tabID: console.id,
                               to: .splitEdge(target: viewportLeaf.id, edge: .bottom)))

        guard case .split(_, .horizontal, _, let left, let right) = controller.root,
              case .tabs(let leftID, _, _) = left,
              case .split(_, .vertical, _, let top, let bottom) = right,
              case .split(let promotedID, .horizontal, _, let topLeft, let topRight) = top,
              case .tabs(let viewportID, let viewportTabs, _) = topLeft,
              case .tabs(let inspectorID, let inspectorTabs, _) = topRight,
              case .tabs(_, let consoleTabs, let activeBottom) = bottom else {
            Issue.record("expected the side-by-side strip to be wrapped by a vertical split")
            return
        }

        #expect(leftID == leftLeaf.id)
        #expect(promotedID == workspaceStrip.id)
        #expect(viewportID == viewportLeaf.id)
        #expect(inspectorID == inspectorLeaf.id)
        #expect(viewportTabs.map(\.id) == [viewport.id])
        #expect(inspectorTabs.map(\.id) == [inspector.id])
        #expect(consoleTabs.map(\.id) == [console.id])
        #expect(activeBottom == console.id)
    }

    // MARK: closeTab

    @Test("closeTab removes the tab and collapses an empty leaf")
    func closeTab() {
        let (controller, tabA, _, _, _) = makeBasicTree()
        controller.apply(.closeTab(tabA.id))
        // Right side survives as the only tab.
        let remaining = controller.root.collectTabIDs()
        #expect(remaining.count == 1)
        #expect(!remaining.contains(tabA.id))
    }

    // MARK: setActive

    @Test("setActive switches the active tab on the addressed leaf only")
    func setActive() {
        let tabA = DockTab(userKey: "a", title: "A")
        let tabB = DockTab(userKey: "b", title: "B")
        let leaf = DockLayoutNode.tabs([tabA, tabB])
        let leafID = leaf.id
        let controller = DockController(root: leaf)

        controller.apply(.setActive(node: leafID, tab: tabB.id))
        if case .tabs(_, _, let active) = controller.root {
            #expect(active == tabB.id)
        } else {
            Issue.record("expected tabs leaf")
        }

        let v = controller.version
        // Setting active to a tab that doesn't exist is a no-op.
        controller.apply(.setActive(node: leafID, tab: DockTabID()))
        #expect(controller.version == v)
    }

    // MARK: resizeSplit

    @Test("resizeSplit clamps fraction and only fires onChange on real change")
    func resizeSplit() {
        let (controller, _, _, _, _) = makeBasicTree()
        guard case .split(let splitID, _, _, _, _) = controller.root else {
            Issue.record("expected split root"); return
        }

        var notified = 0
        controller.onChange = { _ in notified += 1 }

        controller.apply(.resizeSplit(node: splitID, fraction: 0.3))
        guard case .split(_, _, let frac, _, _) = controller.root else {
            Issue.record("expected split"); return
        }
        #expect(frac == 0.3)
        #expect(notified == 1)

        // Same value → no notification.
        controller.apply(.resizeSplit(node: splitID, fraction: 0.3))
        #expect(notified == 1)

        // Out-of-range → clamped.
        controller.apply(.resizeSplit(node: splitID, fraction: 99))
        if case .split(_, _, let f2, _, _) = controller.root {
            #expect(f2 == 0.95)
        }
    }

    // MARK: invariants

    @Test("Mutations preserve uniqueness of node and tab IDs")
    func invariantsAfterMutations() {
        let tabA = DockTab(userKey: "a", title: "A")
        let tabB = DockTab(userKey: "b", title: "B")
        let tabC = DockTab(userKey: "c", title: "C")
        let leaf1 = DockLayoutNode.tabs([tabA, tabB])
        let leaf2 = DockLayoutNode.tabs([tabC])
        let leaf2ID = leaf2.id
        let root = DockLayoutNode.hsplit(first: leaf1, second: leaf2)
        let controller = DockController(root: root)

        controller.apply(.move(tabID: tabA.id,
                               to: .splitEdge(target: leaf2ID, edge: .right)))
        controller.apply(.move(tabID: tabB.id,
                               to: .tabSlot(parent: leaf2ID, index: 0)))
        controller.apply(.closeTab(tabC.id))

        let nodeIDs = controller.root.collectNodeIDs()
        #expect(Set(nodeIDs).count == nodeIDs.count)
        let tabIDs = controller.root.collectTabIDs()
        #expect(Set(tabIDs).count == tabIDs.count)
    }

    // MARK: Codable round-trip

    @Test("Controller.replace + Codable round-trip restores the tree")
    func replaceRoundTrip() throws {
        let (controller, _, _, _, _) = makeBasicTree()
        let encoded = try JSONEncoder().encode(controller.root)

        // Reset and reload.
        let blank = DockController(root: .empty())
        let decoded = try JSONDecoder().decode(DockLayoutNode.self, from: encoded)
        blank.replace(root: decoded)
        #expect(blank.root == controller.root)
    }
}
