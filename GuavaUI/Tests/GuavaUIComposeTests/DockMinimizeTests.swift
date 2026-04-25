import Foundation
import Testing
@testable import GuavaUICompose

@Suite("Dock minimize")
struct DockMinimizeTests {

    @Test("minimizeLeaf removes a leaf from root and stores it by edge")
    func minimizeLeafStoresLeaf() {
        let tabA = DockTab(userKey: "a", title: "A")
        let tabB = DockTab(userKey: "b", title: "B")
        let leafA = DockLayoutNode.tabs([tabA])
        let leafB = DockLayoutNode.tabs([tabB])
        let controller = DockController(root: .hsplit(first: leafA, second: leafB))

        controller.apply(.minimizeLeaf(leafID: leafA.id, edge: .left))

        #expect(!controller.root.collectTabIDs().contains(tabA.id))
        #expect(controller.root.collectTabIDs() == [tabB.id])
        #expect(controller.minimizedLeaves[leafA.id]?.edge == .left)
        #expect(controller.minimizedLeaves[leafA.id]?.node.collectTabIDs() == [tabA.id])
        #expect(controller.minimizedOrder == [leafA.id])
    }

    @Test("restoreMinimizedLeaf reinserts the stored leaf")
    func restoreMinimizedLeaf() {
        let tabA = DockTab(userKey: "a", title: "A")
        let tabB = DockTab(userKey: "b", title: "B")
        let leafA = DockLayoutNode.tabs([tabA])
        let leafB = DockLayoutNode.tabs([tabB])
        let controller = DockController(root: .hsplit(first: leafA, second: leafB))

        controller.apply(.minimizeLeaf(leafID: leafA.id, edge: .left))
        controller.apply(.restoreMinimizedLeaf(leafA.id))

        #expect(controller.minimizedLeaves.isEmpty)
        #expect(controller.minimizedOrder.isEmpty)
        #expect(controller.root.collectTabIDs().contains(tabA.id))
        #expect(controller.root.collectTabIDs().contains(tabB.id))
    }

    @Test("minimizing the only root leaf leaves an empty dock and restores cleanly")
    func minimizeOnlyRootLeaf() {
        let tab = DockTab(userKey: "a", title: "A")
        let leaf = DockLayoutNode.tabs([tab])
        let controller = DockController(root: leaf)

        controller.apply(.minimizeLeaf(leafID: leaf.id, edge: .bottom))
        guard case .empty = controller.root else {
            Issue.record("expected empty root after minimizing the only leaf")
            return
        }

        controller.apply(.restoreMinimizedLeaf(leaf.id))
        #expect(controller.root.collectTabIDs() == [tab.id])
    }
}
