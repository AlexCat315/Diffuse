import Foundation
import Testing
@testable import GuavaUICompose

@Suite("Phase D0 DockLayout")
struct DockLayoutTests {

    @Test("Convenience constructors clamp fraction and seed active tab")
    func constructors() {
        let leaf = DockLayoutNode.tabs([
            DockTab(userKey: "a", title: "A"),
            DockTab(userKey: "b", title: "B")
        ])
        guard case .tabs(_, let tabs, let active) = leaf else {
            Issue.record("expected tabs leaf")
            return
        }
        #expect(tabs.count == 2)
        #expect(active == tabs.first?.id)

        let split = DockLayoutNode.hsplit(fraction: 5.0,
                                          first: leaf,
                                          second: .empty())
        guard case .split(_, let axis, let frac, _, _) = split else {
            Issue.record("expected split")
            return
        }
        #expect(axis == .horizontal)
        #expect(frac == 0.95)
    }

    @Test("All node IDs are unique within a freshly built tree")
    func uniqueIDs() {
        let tree = DockLayoutNode.hsplit(
            first: .tabs([DockTab(userKey: "a", title: "A")]),
            second: .vsplit(
                first: .tabs([DockTab(userKey: "b", title: "B")]),
                second: .empty()
            )
        )
        let ids = tree.collectNodeIDs()
        #expect(Set(ids).count == ids.count)
    }

    @Test("find / leafContainingTab walk the whole tree")
    func searchHelpers() {
        let tabA = DockTab(userKey: "a", title: "A")
        let tabB = DockTab(userKey: "b", title: "B")
        let leafA = DockLayoutNode.tabs([tabA])
        let leafB = DockLayoutNode.tabs([tabB])
        let tree = DockLayoutNode.hsplit(first: leafA, second: leafB)

        #expect(tree.find(leafA.id) != nil)
        #expect(tree.find(leafB.id) != nil)
        #expect(tree.leafContainingTab(tabA.id)?.id == leafA.id)
        #expect(tree.leafContainingTab(tabB.id)?.id == leafB.id)
        #expect(tree.leafContainingTab(DockTabID()) == nil)
    }

    @Test("Codable round-trip preserves IDs and structure")
    func codableRoundTrip() throws {
        let tabA = DockTab(userKey: "a", title: "A")
        let tabB = DockTab(userKey: "b", title: "B")
        let tabC = DockTab(userKey: "c", title: "C")
        let tree = DockLayoutNode.hsplit(
            fraction: 0.3,
            first: .tabs([tabA]),
            second: .vsplit(
                fraction: 0.7,
                first: .tabs([tabB, tabC], active: tabC.id),
                second: .empty()
            )
        )
        let encoded = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(DockLayoutNode.self, from: encoded)
        #expect(decoded == tree)
    }
}
