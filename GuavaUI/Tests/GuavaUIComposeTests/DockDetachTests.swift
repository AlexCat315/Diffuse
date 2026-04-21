import Foundation
import Testing
@testable import GuavaUICompose

@Suite("Phase D4 Detach / Redock / Close Satellite")
struct DockDetachTests {

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

    // MARK: detach

    @Test("Detaching a leaf collapses the parent split and stores the satellite")
    func detachCollapsesParent() {
        let (controller, _, tabB, leafAID, leafBID) = makeBasicTree()
        let baseVersion = controller.version

        controller.apply(.detach(leafID: leafAID))

        // Root collapsed onto leaf B.
        guard case .tabs(let id, let tabs, _) = controller.root else {
            Issue.record("expected leaf B as the new root after detaching A"); return
        }
        #expect(id == leafBID)
        #expect(tabs == [tabB])

        // Satellite stored under the original leaf ID.
        #expect(controller.satellites[leafAID] != nil)
        #expect(controller.satelliteOrder == [leafAID])
        #expect(controller.version == baseVersion + 1)
    }

    @Test("Detaching a leaf that is the root is refused")
    func detachRefusesRoot() {
        let tab = DockTab(userKey: "x", title: "X")
        let leaf = DockLayoutNode.tabs([tab])
        let controller = DockController(root: leaf)

        controller.apply(.detach(leafID: leaf.id))

        // Root unchanged, no satellite created.
        #expect(controller.satellites.isEmpty)
        #expect(controller.satelliteOrder.isEmpty)
        #expect(controller.version == 0)
        if case .tabs(let id, _, _) = controller.root {
            #expect(id == leaf.id)
        } else {
            Issue.record("root should still be the original tabs leaf")
        }
    }

    @Test("Detach is a no-op when the leaf has already been detached")
    func detachIsIdempotent() {
        let (controller, _, _, leafAID, _) = makeBasicTree()
        controller.apply(.detach(leafID: leafAID))
        let firstVersion = controller.version
        controller.apply(.detach(leafID: leafAID))
        #expect(controller.version == firstVersion)
        #expect(controller.satelliteOrder == [leafAID])
    }

    @Test("Detaching an empty placeholder is refused")
    func detachRefusesEmpty() {
        let empty = DockLayoutNode.empty()
        let tab = DockTab(userKey: "x", title: "X")
        let other = DockLayoutNode.tabs([tab])
        let controller = DockController(root: .hsplit(first: empty, second: other))
        controller.apply(.detach(leafID: empty.id))
        #expect(controller.satellites.isEmpty)
    }

    // MARK: redock

    @Test("Redock onto a leaf edge grafts the satellite as a split")
    func redockSplitsTarget() {
        let (controller, tabA, tabB, leafAID, leafBID) = makeBasicTree()
        controller.apply(.detach(leafID: leafAID))

        // Sanity: only B remains.
        if case .tabs = controller.root {} else {
            Issue.record("expected single tabs leaf before redock"); return
        }

        controller.apply(.redock(satelliteID: leafAID,
                                 to: .splitEdge(target: leafBID, edge: .right)))

        // Now: hsplit with B on the left and A on the right (edge=right
        // places the new content as the second child).
        guard case .split(_, let axis, _, let first, let second) = controller.root else {
            Issue.record("expected split after redock"); return
        }
        #expect(axis == .horizontal)
        if case .tabs(let id, let tabs, _) = first {
            #expect(id == leafBID)
            #expect(tabs == [tabB])
        } else {
            Issue.record("first child should be leaf B")
        }
        if case .tabs(let id, let tabs, _) = second {
            #expect(id == leafAID)
            #expect(tabs == [tabA])
        } else {
            Issue.record("second child should be leaf A (the redocked satellite)")
        }

        #expect(controller.satellites.isEmpty)
        #expect(controller.satelliteOrder.isEmpty)
    }

    @Test("Redock to a tab slot merges all satellite tabs into the target leaf")
    func redockTabSlotMergesTabs() {
        let tabA = DockTab(userKey: "a", title: "A")
        let tabB = DockTab(userKey: "b", title: "B")
        let tabC = DockTab(userKey: "c", title: "C")
        let leafAB = DockLayoutNode.tabs([tabA, tabB])
        let leafC = DockLayoutNode.tabs([tabC])
        let leafABID = leafAB.id
        let leafCID = leafC.id
        let controller = DockController(root: .hsplit(first: leafAB, second: leafC))

        controller.apply(.detach(leafID: leafABID))

        controller.apply(.redock(satelliteID: leafABID,
                                 to: .tabSlot(parent: leafCID, index: 0)))

        guard case .tabs(let id, let tabs, let active) = controller.root else {
            Issue.record("expected merged tabs leaf as new root"); return
        }
        #expect(id == leafCID)
        #expect(tabs.map(\.id) == [tabA.id, tabB.id, tabC.id])
        // Active is restored to the satellite's previously-active tab.
        #expect(active == tabA.id)
        #expect(controller.satellites.isEmpty)
    }

    @Test("Redock with replace target swaps the destination leaf wholesale")
    func redockReplaceSwapsTarget() {
        let (controller, tabA, _, leafAID, leafBID) = makeBasicTree()
        controller.apply(.detach(leafID: leafAID))

        controller.apply(.redock(satelliteID: leafAID,
                                 to: .replace(target: leafBID)))

        // Replacement keeps the satellite leaf's ID (since we graft the
        // entire subtree). Note: the old leafBID is gone.
        guard case .tabs(let id, let tabs, _) = controller.root else {
            Issue.record("expected tabs root"); return
        }
        #expect(id == leafAID)
        #expect(tabs == [tabA])
        #expect(controller.satellites.isEmpty)
    }

    @Test("Redock of an unknown satellite ID is a no-op")
    func redockUnknownIsNoOp() {
        let (controller, _, _, _, leafBID) = makeBasicTree()
        let baseVersion = controller.version
        controller.apply(.redock(satelliteID: DockNodeID(),
                                 to: .splitEdge(target: leafBID, edge: .right)))
        #expect(controller.version == baseVersion)
    }

    // MARK: closeSatellite

    @Test("closeSatellite drops the entry and bumps version")
    func closeSatelliteDrops() {
        let (controller, _, _, leafAID, _) = makeBasicTree()
        controller.apply(.detach(leafID: leafAID))
        let afterDetach = controller.version

        controller.apply(.closeSatellite(leafAID))
        #expect(controller.satellites.isEmpty)
        #expect(controller.satelliteOrder.isEmpty)
        #expect(controller.version == afterDetach + 1)
    }

    @Test("closeSatellite on an unknown id is a no-op")
    func closeSatelliteUnknownIsNoOp() {
        let (controller, _, _, _, _) = makeBasicTree()
        let baseVersion = controller.version
        controller.apply(.closeSatellite(DockNodeID()))
        #expect(controller.version == baseVersion)
    }

    // MARK: subscribers

    @Test("Detach and redock fire change notifications")
    func detachRedockNotifiesSubscribers() {
        let (controller, _, _, leafAID, leafBID) = makeBasicTree()
        var receivedVersions: [UInt64] = []
        _ = controller.subscribe { c in receivedVersions.append(c.version) }

        controller.apply(.detach(leafID: leafAID))
        controller.apply(.redock(satelliteID: leafAID,
                                 to: .splitEdge(target: leafBID, edge: .left)))
        #expect(receivedVersions.count == 2)
    }

    // MARK: replace round-trip

    @Test("replace restores satellite map alongside the tree")
    func replaceRestoresSatellites() {
        let (controller, _, _, leafAID, _) = makeBasicTree()
        controller.apply(.detach(leafID: leafAID))
        let snapshotRoot = controller.root
        let snapshotSatellites = controller.satellites
        let snapshotOrder = controller.satelliteOrder

        // Wipe to a different state.
        controller.replace(root: .empty())
        #expect(controller.satellites.isEmpty)

        // Restore.
        controller.replace(root: snapshotRoot,
                           satellites: snapshotSatellites,
                           satelliteOrder: snapshotOrder)
        #expect(controller.satelliteOrder == snapshotOrder)
        #expect(controller.satellites[leafAID] != nil)
    }
}
