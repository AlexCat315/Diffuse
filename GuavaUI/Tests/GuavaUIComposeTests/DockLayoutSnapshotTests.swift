import Foundation
import Testing
@testable import GuavaUICompose

@Suite("Phase D5 DockLayoutSnapshot")
struct DockLayoutSnapshotTests {

    private func makeSnapshotted() -> (DockController, DockNodeID) {
        let tabA = DockTab(userKey: "a", title: "A")
        let tabB = DockTab(userKey: "b", title: "B")
        let leafA = DockLayoutNode.tabs([tabA])
        let leafB = DockLayoutNode.tabs([tabB])
        let leafBID = leafB.id
        let root = DockLayoutNode.hsplit(first: leafA, second: leafB)
        let controller = DockController(root: root)
        // Detach leafB into a satellite by replacing with explicit sat map.
        controller.replace(root: .tabs([tabA]),
                           satellites: [leafBID: .tabs([tabB])],
                           satelliteOrder: [leafBID])
        return (controller, leafBID)
    }

    @Test("snapshot captures root + satellites + order")
    func snapshotCapturesAll() {
        let (controller, leafBID) = makeSnapshotted()
        let snap = controller.snapshot()
        #expect(snap.root == controller.root)
        #expect(snap.satellites.keys.contains(leafBID))
        #expect(snap.satelliteOrder == [leafBID])
        #expect(snap.schemaVersion == DockLayoutSnapshot.currentSchemaVersion)
    }

    @Test("JSON round-trip preserves layout")
    func jsonRoundTrip() throws {
        let (controller, _) = makeSnapshotted()
        let snap = controller.snapshot()
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(DockLayoutSnapshot.self, from: data)
        #expect(decoded == snap)

        // Apply to a blank controller and confirm load() restores state.
        let blank = DockController(root: .empty())
        blank.load(decoded)
        #expect(blank.root == controller.root)
        #expect(blank.satellites == controller.satellites)
        #expect(blank.satelliteOrder == controller.satelliteOrder)
    }

    @Test("Decode tolerates missing satellites/satelliteOrder/schemaVersion")
    func decodeTolerantDefaults() throws {
        let json = """
        { "root": \(try String(data: JSONEncoder().encode(DockLayoutNode.tabs([DockTab(userKey: "x", title: "X")])), encoding: .utf8)!) }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DockLayoutSnapshot.self, from: data)
        #expect(decoded.satellites.isEmpty)
        #expect(decoded.satelliteOrder.isEmpty)
        #expect(decoded.schemaVersion == DockLayoutSnapshot.currentSchemaVersion)
    }

    @Test("Decode filters satelliteOrder against satellites dict")
    func decodeFiltersOrder() throws {
        let realID = DockNodeID()
        let ghostID = DockNodeID()
        let leaf = DockLayoutNode.tabs([DockTab(userKey: "x", title: "X")])
        let snap = DockLayoutSnapshot(
            root: .empty(),
            satellites: [realID: leaf],
            satelliteOrder: [ghostID, realID]
        )
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(DockLayoutSnapshot.self, from: data)
        #expect(decoded.satelliteOrder == [realID])
    }
}
