import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// Visual contracts found by the Gallery audit: controls keep their intrinsic
/// drawing when stretched, and container chrome is not silently erased.
@Suite("Control chrome regressions", .serialized)
@MainActor
struct ChromeRegressionTests {
    private func nodes(_ node: Node?) -> [Node] { guard let node else { return [] }; return [node] + node.children.flatMap(nodes) }

    private func render(_ view: some View, width: Float = 600) -> ViewGraph {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: view)
        for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 400) }
        return graph
    }

    @Test("A switch stretched by a value slot keeps its 38pt track at the leading edge")
    func stretchedToggle() throws { try GlobalTestLock.locked {
        let graph = render(Toggle(isOn: .constant(true)).flex(1, shrink: 1, basis: 0).frame(width: 300))
        let toggle = try #require(nodes(graph.tree.root).first { $0.accessibility?.role == .toggle })
        #expect(toggle.frame.width > 200)
        let list = DrawList(); toggle.draw?(list, .zero)
        let xs = list.vertices.map(\.posX)
        #expect((xs.max() ?? 0) - (xs.min() ?? 0) <= 40 && (xs.min() ?? 99) < 2)
        graph.install(root: EmptyView())
    } }

    @Test("A badge without a title and with a dot renders a bare dot, not an empty pill")
    func dotBadge() throws { try GlobalTestLock.locked {
        let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = old }
        let graph = render(Box { Badge("", tone: .success) { $0.showsDot = true } })
        let badge = try #require(nodes(graph.tree.root).first { $0.accessibility?.role == .staticText })
        let dot = try #require(badge.children.first)
        #expect(dot.frame.width == dot.frame.height && dot.frame.width <= 10 && dot.frame.width >= 7, "\(dot.frame)")
        #expect(dot.children.isEmpty && dot.backgroundColor != nil)
        graph.install(root: EmptyView())
    } }

    @Test("An empty state centers its capped content in a wide container")
    func centeredEmptyState() throws { try GlobalTestLock.locked {
        let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = old }
        let graph = render(EmptyState("No records", message: "Change your filters.", action: { EmptyView() }).frame(width: 900, height: 300), width: 900)
        let title = try #require(nodes(graph.tree.root).first { $0.layoutNode?.textInputs?.text == "No records" })
        #expect(abs(title.absoluteFrame.midX - 450) < 2 && abs(title.absoluteFrame.midY - 150) < 60)
        graph.install(root: EmptyView())
    } }

    @Test("An empty Combobox trigger spans its width instead of hugging a short placeholder")
    func emptyComboboxTrigger() throws { try GlobalTestLock.locked {
        let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = old }
        let graph = render(Box { Combobox(selection: .constant(Int?.none), options: [SelectOption(value: 1, label: "One")]) })
        let chrome = try #require(nodes(graph.tree.root).filter { $0.borderWidth >= 1 && $0.borderColor.map { $0.a > 0 } == true }.max { $0.frame.width < $1.frame.width })
        #expect(chrome.frame.width == 280, "\(chrome.frame)")
        graph.install(root: EmptyView())
    } }

    @Test("A Select trigger keeps its input border; the trigger's focus ring does not erase it")
    func selectBorder() throws { try GlobalTestLock.locked {
        let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = old }
        let graph = render(Select(selection: .constant(1), options: [SelectOption(value: 1, label: "One", isEnabled: true)]))
        let bordered = nodes(graph.tree.root).filter { ($0.borderWidth) >= 1 && $0.borderColor.map { $0.a > 0 } == true }
        #expect(!bordered.isEmpty)
        graph.install(root: EmptyView())
    } }
}
