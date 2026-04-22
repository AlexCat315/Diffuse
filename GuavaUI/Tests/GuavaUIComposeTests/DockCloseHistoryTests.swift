import Foundation
import Testing
@testable import GuavaUICompose

/// Phase R.A — close-others / close-to-the-right / reopen-last-closed.
/// Covers history capture order, FIFO eviction at the cap, and the
/// reopen-target fallback chain (original leaf → first tabs leaf → empty
/// root replacement).
@Suite("Phase R.A DockController close history")
struct DockCloseHistoryTests {

    // MARK: closeOthers

    @Test("closeOthers keeps the pinned tab and pushes victims left-to-right")
    func closeOthersBasic() {
        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let c = DockTab(userKey: "c", title: "C")
        let leaf = DockLayoutNode.tabs([a, b, c], active: c.id)
        let leafID = leaf.id
        let controller = DockController(root: leaf)

        controller.apply(.closeOthers(in: leafID, keep: b.id))

        guard case .tabs(_, let tabs, _) = controller.root else {
            Issue.record("expected tabs leaf at root"); return
        }
        #expect(tabs.map(\.id) == [b.id])
        #expect(controller.closedHistory.map { $0.tab.id } == [a.id, c.id])
        #expect(controller.closedHistory.map { $0.originalIndex } == [0, 2])
    }

    @Test("closeOthers is a no-op when keep is not in the leaf")
    func closeOthersUnknownKeep() {
        let a = DockTab(userKey: "a", title: "A")
        let leaf = DockLayoutNode.tabs([a])
        let controller = DockController(root: leaf)

        controller.apply(.closeOthers(in: leaf.id, keep: DockTabID()))
        #expect(controller.version == 0)
        #expect(controller.closedHistory.isEmpty)
    }

    // MARK: closeToTheRight

    @Test("closeToTheRight closes only tabs after the pivot")
    func closeRightBasic() {
        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let c = DockTab(userKey: "c", title: "C")
        let d = DockTab(userKey: "d", title: "D")
        let leaf = DockLayoutNode.tabs([a, b, c, d])
        let leafID = leaf.id
        let controller = DockController(root: leaf)

        controller.apply(.closeToTheRight(in: leafID, of: b.id))

        guard case .tabs(_, let tabs, _) = controller.root else {
            Issue.record("expected tabs leaf"); return
        }
        #expect(tabs.map(\.id) == [a.id, b.id])
        #expect(controller.closedHistory.map { $0.tab.id } == [c.id, d.id])
    }

    @Test("closeToTheRight is a no-op when pivot is the rightmost tab")
    func closeRightOnLast() {
        let a = DockTab(userKey: "a", title: "A")
        let leaf = DockLayoutNode.tabs([a])
        let controller = DockController(root: leaf)

        controller.apply(.closeToTheRight(in: leaf.id, of: a.id))
        #expect(controller.version == 0)
    }

    // MARK: history cap

    @Test("closedHistory drops oldest entries past the cap (FIFO)")
    func historyCap() {
        let leaf = DockLayoutNode.tabs([DockTab(userKey: "seed", title: "seed")])
        let controller = DockController(root: leaf)
        controller.closedHistoryLimit = 3
        for i in 0..<5 {
            let t = DockTab(userKey: "k\(i)", title: "T\(i)")
            controller.apply(.insertTab(t, into: leaf.id, at: 0))
            controller.apply(.closeTab(t.id))
        }
        #expect(controller.closedHistory.count == 3)
        // Newest (T4, T3, T2) survive; T0 / T1 evicted.
        #expect(controller.closedHistory.map { $0.tab.title } == ["T2", "T3", "T4"])
    }

    // MARK: reopen — happy path

    @Test("reopenLastClosed restores the most-recent close at the original index")
    func reopenAtOriginalIndex() {
        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let c = DockTab(userKey: "c", title: "C")
        let leaf = DockLayoutNode.tabs([a, b, c])
        let leafID = leaf.id
        let controller = DockController(root: leaf)

        controller.apply(.closeTab(b.id))
        controller.apply(.reopenLastClosed)

        guard case .tabs(_, let tabs, _) = controller.root else {
            Issue.record("expected tabs leaf"); return
        }
        #expect(tabs.map(\.id) == [a.id, b.id, c.id])
        #expect(controller.closedHistory.isEmpty)
    }

    @Test("reopenLastClosed restores in reverse order (LIFO)")
    func reopenLifo() {
        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let c = DockTab(userKey: "c", title: "C")
        let leaf = DockLayoutNode.tabs([a, b, c])
        let leafID = leaf.id
        let controller = DockController(root: leaf)

        controller.apply(.closeOthers(in: leafID, keep: b.id))
        // history: [a, c] — reopen restores c first, then a.
        controller.apply(.reopenLastClosed)
        controller.apply(.reopenLastClosed)

        guard case .tabs(_, let tabs, _) = controller.root else {
            Issue.record("expected tabs leaf"); return
        }
        #expect(tabs.map(\.id) == [a.id, b.id, c.id])
    }

    // MARK: reopen — fallback chains

    @Test("reopenLastClosed appends to the first tabs leaf when source vanished")
    func reopenFallbackToFirstLeaf() {
        let a = DockTab(userKey: "a", title: "A")
        let leafA = DockLayoutNode.tabs([a])
        let leafAID = leafA.id
        let other = DockLayoutNode.tabs([DockTab(userKey: "k", title: "K")])
        let otherID = other.id
        let controller = DockController(root: .hsplit(first: leafA, second: other))

        controller.apply(.closeTab(a.id))
        // Closing the only tab in leafA collapses leafA out of the tree, so
        // sourceLeafID no longer exists. Reopen must fall back to `other`.
        controller.apply(.reopenLastClosed)

        guard case .tabs(let id, let tabs, _) = controller.root else {
            Issue.record("expected tabs leaf"); return
        }
        #expect(id == otherID)
        #expect(tabs.map(\.id).contains(a.id))
        _ = leafAID
    }

    @Test("reopenLastClosed promotes an empty root into a fresh tabs leaf")
    func reopenFallbackEmptyRoot() {
        let a = DockTab(userKey: "a", title: "A")
        let leaf = DockLayoutNode.tabs([a])
        let controller = DockController(root: leaf)

        controller.apply(.closeTab(a.id))
        // After closing the only tab the root becomes `.empty`.
        guard case .empty = controller.root else {
            Issue.record("expected empty root after closing only tab"); return
        }
        controller.apply(.reopenLastClosed)

        guard case .tabs(_, let tabs, _) = controller.root else {
            Issue.record("expected tabs leaf after reopen"); return
        }
        #expect(tabs.map(\.id) == [a.id])
    }

    @Test("reopenLastClosed on an empty history is a no-op")
    func reopenEmpty() {
        let controller = DockController(root: .tabs([DockTab(userKey: "k", title: "K")]))
        let v = controller.version
        controller.apply(.reopenLastClosed)
        #expect(controller.version == v)
    }
}
