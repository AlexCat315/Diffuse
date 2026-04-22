import Foundation
import Testing
@testable import GuavaUICompose

/// Phase O — `DockTab.isPinned` data + `.setPinned` op + Codable
/// backward-compatibility coverage. Tab strip rendering is a separate
/// (still-pending) chunk; this suite locks down the model layer.
@Suite("Phase O DockTab pinned model")
struct DockTabPinnedTests {

    // MARK: data + op

    @Test("setPinned flips the flag without reordering the tabs")
    func setPinnedFlipsFlag() {
        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let c = DockTab(userKey: "c", title: "C")
        let leaf = DockLayoutNode.tabs([a, b, c])
        let controller = DockController(root: leaf)

        controller.apply(.setPinned(tabID: b.id, isPinned: true))

        guard case .tabs(_, let tabs, _) = controller.root else {
            Issue.record("expected tabs leaf"); return
        }
        #expect(tabs.map(\.id) == [a.id, b.id, c.id])
        #expect(tabs.map(\.isPinned) == [false, true, false])
    }

    @Test("setPinned to the current value is a no-op (version unchanged)")
    func setPinnedNoOp() {
        let a = DockTab(userKey: "a", title: "A")
        let leaf = DockLayoutNode.tabs([a])
        let controller = DockController(root: leaf)
        let v = controller.version
        controller.apply(.setPinned(tabID: a.id, isPinned: false))
        #expect(controller.version == v)
    }

    @Test("closeOthers excludes pinned tabs from the victim set")
    func closeOthersSparesPinned() {
        let a = DockTab(userKey: "a", title: "A", isPinned: true)
        let b = DockTab(userKey: "b", title: "B")
        let c = DockTab(userKey: "c", title: "C")
        let leaf = DockLayoutNode.tabs([a, b, c])
        let leafID = leaf.id
        let controller = DockController(root: leaf)

        controller.apply(.closeOthers(in: leafID, keep: c.id))

        guard case .tabs(_, let tabs, _) = controller.root else {
            Issue.record("expected tabs leaf"); return
        }
        // Pinned `a` survives even though `keep` is `c`.
        #expect(tabs.map(\.id) == [a.id, c.id])
        #expect(controller.closedHistory.map { $0.tab.id } == [b.id])
    }

    // MARK: Codable backward compat

    @Test("Pre-O snapshots without isPinned decode with the false default")
    func decodeLegacySnapshot() throws {
        let json = """
        {
            "id": { "raw": "AAAAAAAA-0000-0000-0000-000000000000" },
            "userKey": "k",
            "title": "T",
            "isClosable": true
        }
        """.data(using: .utf8)!
        let tab = try JSONDecoder().decode(DockTab.self, from: json)
        #expect(tab.userKey == "k")
        #expect(tab.title == "T")
        #expect(tab.isPinned == false)
        #expect(tab.isClosable == true)
    }

    @Test("Round-trip preserves the pinned flag")
    func roundTrip() throws {
        let original = DockTab(userKey: "k", title: "T", isPinned: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DockTab.self, from: data)
        #expect(decoded.isPinned == true)
        #expect(decoded.id == original.id)
    }
}
