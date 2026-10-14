import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("ViewThatFits content trees", .serialized)
struct ViewThatFitsTests: GuavaUIComposeSerializedSuite {
    private struct Harness: View {
        @State var width: Float = 700

        var body: some View {
            ViewThatFits {
                Row {}.frame(width: 120, height: 40).debugName("branch-wide")
            } narrow: {
                Column {}.frame(width: 60, height: 40).debugName("branch-narrow")
            }.frame(width: width, height: 100)
        }
    }

    private struct ThresholdHarness: View {
        @State var threshold: Float = 600
        @State var width: Float = 450

        var body: some View {
            ViewThatFits(threshold: CGFloat(threshold)) {
                Row {}.debugName("threshold-wide")
            } narrow: {
                Column {}.debugName("threshold-narrow")
            }.frame(width: width, height: 100)
        }
    }

    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }

    private func named(_ name: String, in graph: ViewGraph) -> Node? {
        nodes(graph.tree.root).first {
            $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name
        }
    }

    private func settle(_ graph: ViewGraph, _ recomposer: Recomposer, width: Float, height: Float) {
        recomposer.commitAll()
        graph.computeLayout(width: width, height: height)
        recomposer.commitAll()
        graph.computeLayout(width: width, height: height)
    }

    @Test("the wide branch is selected once the container is measured; the unmeasured build is narrow")
    func selectsByMeasuredWidth() throws { try GlobalTestLock.locked {
        var harness = Harness()
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: harness)
        let recomposer = graph.recomposer

        // Before any layout the container size is unknown: the narrow branch
        // is the documented first build.
        graph.computeLayout(width: 700, height: 100)
        #expect(named("branch-narrow", in: graph) != nil)
        #expect(named("branch-wide", in: graph) == nil)

        settle(graph, recomposer, width: 700, height: 100)
        #expect(named("branch-wide", in: graph) != nil)
        #expect(named("branch-narrow", in: graph) == nil)
        #expect(!recomposer.hasPending)

        // A narrower container switches the branch and settles without
        // further pending work.
        harness.$width.wrappedValue = 300
        settle(graph, recomposer, width: 300, height: 100)
        #expect(named("branch-wide", in: graph) == nil)
        #expect(named("branch-narrow", in: graph) != nil)
        #expect(!recomposer.hasPending)
    } }

    @Test("a selected branch keeps its node identity while it stays selected")
    func branchIdentitySurvivesRecomposition() throws { try GlobalTestLock.locked {
        var harness = Harness()
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: harness)
        let recomposer = graph.recomposer
        settle(graph, recomposer, width: 700, height: 100)
        let wide = named("branch-wide", in: graph)

        // Idle frames must not rebuild the selected branch.
        for _ in 0..<3 {
            recomposer.commitAll()
            graph.computeLayout(width: 700, height: 100)
        }
        #expect(named("branch-wide", in: graph) === wide)

        // Dropping below the threshold rebuilds the narrow branch; the wide
        // node is gone and a fresh one appears when it is selected again.
        harness.$width.wrappedValue = 300
        settle(graph, recomposer, width: 300, height: 100)
        #expect(named("branch-wide", in: graph) == nil)
        harness.$width.wrappedValue = 800
        settle(graph, recomposer, width: 800, height: 100)
        let reselected = named("branch-wide", in: graph)
        #expect(reselected != nil)
        #expect(reselected !== wide)
    } }

    @Test("an explicit threshold switches at the boundary, wide inclusive")
    func explicitThresholdBoundary() throws { try GlobalTestLock.locked {
        var harness = ThresholdHarness()
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: harness)
        let recomposer = graph.recomposer

        settle(graph, recomposer, width: 450, height: 100)
        #expect(named("threshold-narrow", in: graph) != nil)

        harness.$width.wrappedValue = 600
        settle(graph, recomposer, width: 600, height: 100)
        #expect(named("threshold-wide", in: graph) != nil)

        harness.$threshold.wrappedValue = 700
        settle(graph, recomposer, width: 600, height: 100)
        #expect(named("threshold-wide", in: graph) == nil)
        #expect(named("threshold-narrow", in: graph) != nil)
    } }
}
