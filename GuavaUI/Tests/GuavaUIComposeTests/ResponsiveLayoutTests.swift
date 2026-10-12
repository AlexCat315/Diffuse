import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Responsive candidate layouts", .serialized)
struct ResponsiveLayoutTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }

    private func named(_ name: String, in graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first {
            $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name
        })
    }

    private struct Harness: View {
        @State var width: Float = 200
        var body: some View {
            LayoutThatFits([
                StackLayout(.horizontal, spacing: 10),
                StackLayout(.vertical, spacing: 10)
            ]) {
                Box {}.frame(width: 70, height: 20).debugName("candidate-first").id("first")
                Box {}.frame(width: 60, height: 30).debugName("candidate-second").id("second")
            }.frame(width: width, height: 100)
        }
    }

    @Test("width changes select horizontal or vertical geometry without replacing child nodes")
    func preservesChildren() throws { try GlobalTestLock.locked {
        let harness = Harness()
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: harness)
        graph.computeLayout(width: 300, height: 200)
        let first = try named("candidate-first", in: graph)
        let second = try named("candidate-second", in: graph)
        #expect(first.frame == CGRect(x: 0, y: 0, width: 70, height: 20))
        #expect(second.frame == CGRect(x: 80, y: 0, width: 60, height: 30))
        harness.$width.wrappedValue = 100
        graph.recomposer.commitAll()
        graph.computeLayout(width: 300, height: 200)
        let retainedFirst = try named("candidate-first", in: graph)
        let retainedSecond = try named("candidate-second", in: graph)
        #expect(retainedFirst === first)
        #expect(retainedSecond === second)
        #expect(second.frame == CGRect(x: 0, y: 30, width: 60, height: 30))
        harness.$width.wrappedValue = 140
        graph.recomposer.commitAll()
        graph.computeLayout(width: 300, height: 200)
        #expect(second.frame.origin == CGPoint(x: 80, y: 0))
    } }

    @Test("stack alignment follows semantic leading in RTL on both axes")
    func rtlAlignment() throws { try GlobalTestLock.locked {
        let horizontal = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        horizontal.install(root: StackLayout(.horizontal, spacing: 10) {
            Box {}.frame(width: 60, height: 20).debugName("first")
            Box {}.frame(width: 40, height: 30).debugName("second")
        }.frame(width: 200, height: 100).layoutDirection(.rtl))
        horizontal.computeLayout(width: 300, height: 200)
        let horizontalFirst = try named("first", in: horizontal)
        let horizontalSecond = try named("second", in: horizontal)
        #expect(horizontalFirst.frame.origin == CGPoint(x: 140, y: 0))
        #expect(horizontalSecond.frame.origin == CGPoint(x: 90, y: 0))
        let vertical = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        vertical.install(root: StackLayout(.vertical, spacing: 10) {
            Box {}.frame(width: 60, height: 20).debugName("first")
            Box {}.frame(width: 40, height: 30).debugName("second")
        }.frame(width: 200, height: 100).layoutDirection(.rtl))
        vertical.computeLayout(width: 300, height: 200)
        let verticalFirst = try named("first", in: vertical)
        let verticalSecond = try named("second", in: vertical)
        #expect(verticalFirst.frame.origin == CGPoint(x: 140, y: 0))
        #expect(verticalSecond.frame.origin == CGPoint(x: 160, y: 30))
    } }

    @Test("center and bottom alignment place intrinsic stacks inside larger bounds")
    func alignment() throws { try GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: StackLayout(.horizontal, spacing: 10, alignment: .bottom) {
            Box {}.frame(width: 60, height: 20).debugName("first")
            Box {}.frame(width: 40, height: 30).debugName("second")
        }.frame(width: 200, height: 100))
        graph.computeLayout(width: 300, height: 200)
        let first = try named("first", in: graph)
        let second = try named("second", in: graph)
        #expect(first.frame.origin == CGPoint(x: 45, y: 80))
        #expect(second.frame.origin == CGPoint(x: 115, y: 70))
    } }

    private final class Decisions {
        var measurements: [Int] = []
        var placements: [Int] = []
    }

    private struct Candidate: Layout {
        let id: Int
        let size: CGSize
        let decisions: Decisions

        func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
            decisions.measurements.append(id)
            return size
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
            decisions.placements.append(id)
            for subview in subviews { subview.place(at: bounds.origin, proposal: .init(width: 10, height: 10)) }
        }
    }

    @Test("candidate evaluation stops at the first fit and uses the final candidate for overflow")
    func candidateSelection() { GlobalTestLock.locked {
        let firstFit = Decisions()
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: LayoutThatFits([
            Candidate(id: 0, size: CGSize(width: 80, height: 20), decisions: firstFit),
            Candidate(id: 1, size: CGSize(width: 10, height: 10), decisions: firstFit)
        ]) { Box {}.frame(width: 10, height: 10) }.frame(width: 100, height: 100))
        graph.computeLayout(width: 200, height: 200)
        #expect(!firstFit.measurements.isEmpty)
        #expect(firstFit.measurements.allSatisfy { $0 == 0 })
        #expect(firstFit.placements == [0])
        let fallback = Decisions()
        let overflow = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        overflow.install(root: LayoutThatFits([
            Candidate(id: 0, size: CGSize(width: 120, height: 20), decisions: fallback),
            Candidate(id: 1, size: CGSize(width: 80, height: 120), decisions: fallback)
        ]) { Box {}.frame(width: 10, height: 10) }.frame(width: 100, height: 100))
        overflow.computeLayout(width: 200, height: 200)
        #expect(fallback.placements == [1])
        #expect(fallback.measurements.contains(0) && fallback.measurements.contains(1))
    } }

    @Test("unspecified axes accept intrinsic candidate extents and empty stacks stay empty")
    func intrinsicProposals() {
        let decisions = Decisions()
        let layout = LayoutThatFits([
            Candidate(id: 0, size: CGSize(width: 300, height: 20), decisions: decisions),
            Candidate(id: 1, size: CGSize(width: 10, height: 10), decisions: decisions)
        ])
        #expect(layout.sizeThatFits(proposal: .init(height: 30), subviews: []) == CGSize(width: 300, height: 20))
        #expect(decisions.measurements == [0])
        #expect(StackLayout(.horizontal, spacing: 10).sizeThatFits(proposal: .unspecified, subviews: []) == .zero)
        #expect(StackLayout(.vertical, spacing: .nan).sizeThatFits(proposal: .zero, subviews: []) == .zero)
    }

    @Test("real font button labels keep their measured lines and bounds at 100% and 200%", arguments: [Float(1), Float(2)])
    func realFontPlacement(scale: Float) throws { try GlobalTestLock.locked {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TextEnvironment.bootstrapped(
            atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        defer { TextEnvironmentHolder.current = previous }
        for width in [Float(620), Float(180)] {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: LayoutThatFits([
                StackLayout(.horizontal, spacing: 12), StackLayout(.vertical, spacing: 12)
            ]) {
                Button("Files") {}.buttonStyle(.secondary)
                Button("Preview") {}.buttonStyle(.secondary)
                Button("Settings") {}.buttonStyle(.secondary)
            }.frame(width: width).debugName("real-font-candidates").textScaler(.init(scale)))
            for _ in 0..<3 {
                graph.recomposer.commitAll()
                graph.computeLayout(width: 700, height: 500)
                if let root = graph.tree.root { NodeRenderer().render(root: root, into: DrawList()) }
            }
            let owner = try named("real-font-candidates", in: graph)
            let hosts = nodes(owner).filter { $0.attachments[ButtonHost.markerKey] as? Bool == true }
            #expect(hosts.count == 3)
            for host in hosts {
                let label = try #require(nodes(host).first { $0.layoutNode?.textInputs != nil })
                let measured = try #require(label.layoutNode?.textMeasure)
                #expect(measured.result.lines.count == 1,
                        "\(measured.key.text), scale \(scale), width \(width), label \(label.frame)")
                #expect(host.absoluteFrame.contains(label.absoluteFrame))
                #expect(host.absoluteFrame.maxY <= owner.absoluteFrame.maxY)
            }
            for pair in zip(hosts, hosts.dropFirst()) {
                #expect(!pair.0.absoluteFrame.intersects(pair.1.absoluteFrame))
            }
        }
    } }
}
