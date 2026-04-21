import Foundation
import Testing
@testable import GuavaUICompose

/// Phase D8.1 — `DockOperation.moveLeaf` model-only coverage. Mirrors the
/// shape of DockControllerTests; verifies cycle/no-op guards plus the
/// three target shapes (tabSlot / replace / splitEdge).
@Suite("Phase D8 / DockController moveLeaf")
struct DockMoveLeafTests {

    // MARK: tabSlot — fold leaf tabs into a sibling

    @Test("moveLeaf into a sibling tabSlot folds all tabs and collapses the source")
    func moveLeafIntoTabSlot() {
        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let c = DockTab(userKey: "c", title: "C")
        let leafA = DockLayoutNode.tabs([a])
        let leafBC = DockLayoutNode.tabs([b, c])
        let leafAID = leafA.id
        let leafBCID = leafBC.id
        let controller = DockController(root: .hsplit(first: leafA, second: leafBC))

        controller.apply(.moveLeaf(leafID: leafAID,
                                   to: .tabSlot(parent: leafBCID, index: 1)))

        guard case .tabs(let id, let tabs, _) = controller.root else {
            Issue.record("expected collapsed tabs leaf at root"); return
        }
        #expect(id == leafBCID)
        #expect(tabs.map(\.id) == [b.id, a.id, c.id])
    }

    // MARK: replace — graft leaf subtree at a sibling

    @Test("moveLeaf with .replace target swaps the sibling and collapses the source")
    func moveLeafReplace() {
        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let leafA = DockLayoutNode.tabs([a])
        let leafB = DockLayoutNode.tabs([b])
        let leafAID = leafA.id
        let leafBID = leafB.id
        let controller = DockController(root: .hsplit(first: leafA, second: leafB))

        controller.apply(.moveLeaf(leafID: leafAID, to: .replace(target: leafBID)))

        // Source collapse leaves leafB as the surviving sibling, then the
        // replace swaps that node with leafA. Net: root is leafA.
        guard case .tabs(let id, let tabs, _) = controller.root else {
            Issue.record("expected tabs leaf at root"); return
        }
        #expect(id == leafAID)
        #expect(tabs.map(\.id) == [a.id])
    }

    // MARK: splitEdge — graft leaf subtree as a new split

    @Test("moveLeaf with .splitEdge .right wraps the target in a new hsplit")
    func moveLeafSplitRight() {
        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let c = DockTab(userKey: "c", title: "C")
        let leafA = DockLayoutNode.tabs([a])
        let leafB = DockLayoutNode.tabs([b])
        let leafC = DockLayoutNode.tabs([c])
        let leafAID = leafA.id
        let leafBID = leafB.id
        let controller = DockController(root: .hsplit(
            first: leafA,
            second: .vsplit(first: leafB, second: leafC)
        ))

        controller.apply(.moveLeaf(leafID: leafAID,
                                   to: .splitEdge(target: leafBID, edge: .right)))

        // Source collapse leaves the inner vsplit as the new root; then
        // the .right edge wraps leafB in a horizontal split with leafA on
        // the right.
        guard case .split(_, .vertical, _, let first, let second) = controller.root else {
            Issue.record("expected vsplit at root after collapse"); return
        }
        guard case .split(_, .horizontal, _, let l, let r) = first,
              case .tabs(let lID, _, _) = l,
              case .tabs(let rID, _, _) = r else {
            Issue.record("expected hsplit on the first half"); return
        }
        #expect(lID == leafBID)
        #expect(rID == leafAID)
        guard case .tabs(let cID, _, _) = second else {
            Issue.record("expected leafC on the second half"); return
        }
        #expect(cID == leafC.id)
    }

    // MARK: guards

    @Test("moveLeaf is a no-op when leafID is the root")
    func moveLeafRejectsRoot() {
        let a = DockTab(userKey: "a", title: "A")
        let leaf = DockLayoutNode.tabs([a])
        let leafID = leaf.id
        let controller = DockController(root: leaf)
        let v = controller.version
        controller.apply(.moveLeaf(leafID: leafID,
                                   to: .replace(target: leafID)))
        #expect(controller.version == v)
    }

    @Test("moveLeaf is a no-op when target is the leaf itself")
    func moveLeafRejectsSelf() {
        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let leafA = DockLayoutNode.tabs([a])
        let leafB = DockLayoutNode.tabs([b])
        let leafAID = leafA.id
        let controller = DockController(root: .hsplit(first: leafA, second: leafB))
        let v = controller.version
        controller.apply(.moveLeaf(leafID: leafAID,
                                   to: .tabSlot(parent: leafAID, index: 0)))
        #expect(controller.version == v)
    }

    @Test("moveLeaf is a no-op for an unknown leaf id")
    func moveLeafRejectsMissing() {
        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let leafA = DockLayoutNode.tabs([a])
        let leafB = DockLayoutNode.tabs([b])
        let leafBID = leafB.id
        let controller = DockController(root: .hsplit(first: leafA, second: leafB))
        let v = controller.version
        controller.apply(.moveLeaf(leafID: DockNodeID(),
                                   to: .replace(target: leafBID)))
        #expect(controller.version == v)
    }
}
