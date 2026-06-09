import Testing
@testable import GuavaKit

@Suite("GuavaKit Tree")
struct TreeTests {
    struct Node: Equatable {
        let id: Int
        let title: String
        let children: [Node]
    }

    static let sample = [
        Node(id: 1, title: "Root", children: [
            Node(id: 2, title: "ChildA", children: []),
            Node(id: 3, title: "ChildB", children: [
                Node(id: 4, title: "Leaf", children: [])
            ])
        ])
    ]

    final class Box<T> { var v: T; init(_ v: T) { self.v = v } }

    private struct App: View {
        let roots: [Node]
        let selection: Binding<Int?>
        var body: some View {
            Tree(roots, id: \.id, children: \.children, selection: selection) { node, _, _ in
                Text(node.title)
            }
        }
    }

    // All text strings in the retained tree, in tree order.
    private func texts(_ node: UINode) -> [String] {
        var out: [String] = []
        if let t = node.textContent?.string { out.append(t) }
        for c in node.children { out.append(contentsOf: texts(c)) }
        return out
    }

    private func node(text: String, in node: UINode) -> UINode? {
        if node.textContent?.string == text { return node }
        for c in node.children { if let f = self.node(text: text, in: c) { return f } }
        return nil
    }

    private func absCenter(_ node: UINode) -> Point {
        var x = node.geometry.frame.minX, y = node.geometry.frame.minY
        var p = node.parent
        while let cur = p {
            x += cur.geometry.frame.minX - cur.geometry.contentOffset.x
            y += cur.geometry.frame.minY - cur.geometry.contentOffset.y
            p = cur.parent
        }
        return Point(x: x + node.geometry.frame.size.width / 2,
                     y: y + node.geometry.frame.size.height / 2)
    }

    @Test("Collapsed tree shows only roots; clicking the chevron reveals children")
    func expandCollapse() {
        let sel = Box<Int?>(nil)
        let ctx = UIContext(); let graph = ViewGraph(context: ctx)
        graph.install(root: App(roots: Self.sample,
                                selection: Binding(get: { sel.v }, set: { sel.v = $0 })))
        ctx.layoutIfNeeded(engine: StackLayoutEngine(), available: Size(width: 240, height: 400))

        #expect(texts(graph.root).contains("Root"))
        #expect(!texts(graph.root).contains("ChildA")) // collapsed

        // Click the root's disclosure chevron (the only "▸" while collapsed).
        let chevron = node(text: "▸", in: graph.root)!
        let p = absCenter(chevron)
        let disp = EventDispatcher(context: ctx)
        disp.pointerDown(PointerEvent(position: p, action: .down))
        disp.pointerUp(PointerEvent(position: p, action: .up))
        graph.commitIfNeeded()

        #expect(texts(graph.root).contains("ChildA")) // expanded
        #expect(texts(graph.root).contains("ChildB"))
        #expect(!texts(graph.root).contains("Leaf"))  // grandchild still collapsed
        #expect(sel.v == nil)                          // toggling did not select
    }

    @Test("Clicking a row updates the selection binding")
    func rowSelection() {
        let sel = Box<Int?>(nil)
        let ctx = UIContext(); let graph = ViewGraph(context: ctx)
        graph.install(root: App(roots: Self.sample,
                                selection: Binding(get: { sel.v }, set: { sel.v = $0 })))
        ctx.layoutIfNeeded(engine: StackLayoutEngine(), available: Size(width: 240, height: 400))

        let p = absCenter(node(text: "Root", in: graph.root)!)
        let disp = EventDispatcher(context: ctx)
        disp.pointerDown(PointerEvent(position: p, action: .down))
        disp.pointerUp(PointerEvent(position: p, action: .up))
        #expect(sel.v == 1)
    }
}
