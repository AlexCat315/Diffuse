import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Container size queries", .serialized)
struct ContainerQueryTests: GuavaUIComposeSerializedSuite {
    private final class Recorder {
        var builds = 0
        var sizes: [CGSize] = []
        /// Single-expression content so the view builder closure stays an
        /// expression; the call itself records the build.
        func content(for size: CGSize) -> some View {
            builds += 1
            sizes.append(size)
            return Box {}.debugName("probe-child")
        }
    }

    private struct Harness: View {
        @State var width: Float = 300
        @State var height: Float = 100
        let recorder: Recorder

        var body: some View {
            ContainerSizeReader { size in
                recorder.content(for: size)
            }.frame(width: width, height: height)
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

    /// One settle cycle: layout publishes the frame, the queued recompose
    /// rebuilds the content with the measured size, layout runs again to
    /// leave the graph consistent.
    private func settle(_ graph: ViewGraph, _ recomposer: Recomposer, width: Float, height: Float) {
        recomposer.commitAll()
        graph.computeLayout(width: width, height: height)
        recomposer.commitAll()
        graph.computeLayout(width: width, height: height)
    }

    @Test("the measured content box is published after layout, unmeasured build reports zero")
    func reportsMeasuredContentBox() throws { try GlobalTestLock.locked {
        let recorder = Recorder()
        let harness = Harness(recorder: recorder)
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: harness)
        let recomposer = graph.recomposer
        settle(graph, recomposer, width: 300, height: 100)

        #expect(recorder.builds == 2)
        #expect(recorder.sizes.count == 2)
        #expect(recorder.sizes[0] == .zero)
        #expect(recorder.sizes[1].width.isApproximatelyEqual(to: 300))
        #expect(recorder.sizes[1].height.isApproximatelyEqual(to: 100))
        #expect(!recomposer.hasPending)
    } }

    @Test("width and height changes republish, the subtree keeps identity, and idle frames stay idle")
    func republishesAndStabilizes() throws { try GlobalTestLock.locked {
        let recorder = Recorder()
        var harness = Harness(recorder: recorder)
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: harness)
        let recomposer = graph.recomposer
        settle(graph, recomposer, width: 300, height: 100)
        let child = named("probe-child", in: graph)

        harness.$width.wrappedValue = 120
        harness.$height.wrappedValue = 240
        settle(graph, recomposer, width: 120, height: 240)

        #expect(recorder.sizes.last?.width.isApproximatelyEqual(to: 120) == true)
        #expect(recorder.sizes.last?.height.isApproximatelyEqual(to: 240) == true)
        #expect(!recomposer.hasPending)
        // A stable subtree keeps its node across settle cycles.
        #expect(named("probe-child", in: graph) === child)

        // Additional idle frames must not rebuild the content.
        let builds = recorder.builds
        for _ in 0..<3 {
            recomposer.commitAll()
            graph.computeLayout(width: 120, height: 240)
        }
        #expect(recorder.builds == builds)
    } }

    @Test("queries the parent allocation rather than branch intrinsic width, and excludes insets")
    func allocationAndInsets() throws { try GlobalTestLock.locked {
        let recorder = Recorder()
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Box(direction: .column, alignItems: .stretch) {
            ContainerSizeReader { recorder.content(for: $0) }
                .padding(horizontal: 12, vertical: 8).border(.white, width: 2)
                .frame(height: 100).debugName("inset-reader")
        }.frame(width: 400))
        let probe = try #require(named("inset-reader", in: graph))
        probe.layoutNode?.setBorder(2)
        settle(graph, graph.recomposer, width: 900, height: 300)
        #expect(recorder.sizes.last == CGSize(width: 372, height: 80))
        #expect(!graph.recomposer.hasPending)
    } }

    @Test("row queries use the flex allocation even when content has a larger intrinsic width")
    func rowAllocation() throws { try GlobalTestLock.locked {
        let recorder = Recorder(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Row {
            Box {}.frame(width: 100, height: 40).flex(0, shrink: 0)
            ContainerSizeReader { size in recorder.content(for: size).frame(width: 950, height: 40) }
                .flex(1, shrink: 1, basis: 0)
        }.frame(width: 400))
        settle(graph, graph.recomposer, width: 900, height: 300)
        #expect(recorder.sizes.last?.width == 300)
        #expect(!graph.recomposer.hasPending)
    } }

    @Test("exactly half a point is published")
    func toleranceBoundary() throws { try GlobalTestLock.locked {
        let recorder = Recorder()
        let measured = Harness(recorder: recorder)
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: measured)
        settle(graph, graph.recomposer, width: 300, height: 100)
        // Yoga rounds at the default pixel scale; exercise a subpixel host frame
        // directly to verify the publication threshold before pixel snapping.
        let probe = try #require(nodes(graph.tree.root).first { $0.layoutDidUpdate != nil })
        probe.frame.size.width = 300.5
        probe.layoutDidUpdate?(probe)
        graph.recomposer.commitAll()
        #expect(recorder.sizes.last?.width == 300.5)
        #expect(!graph.recomposer.hasPending)
    } }

    @Test("sub-tolerance frame jitter does not republish")
    func ignoresJitter() throws { try GlobalTestLock.locked {
        let recorder = Recorder()
        var harness = Harness(recorder: recorder)
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: harness)
        let recomposer = graph.recomposer
        settle(graph, recomposer, width: 300, height: 100)

        // A jittered proposal rebuilds once from the parent state write, but
        // the published size must stay at the last measured value.
        harness.$width.wrappedValue = 300.4
        settle(graph, recomposer, width: 300.4, height: 100)
        #expect(recorder.sizes.allSatisfy { !$0.width.isApproximatelyEqual(to: 300.4) })
        #expect(recorder.sizes.last?.width.isApproximatelyEqual(to: 300) == true)
        #expect(!recomposer.hasPending)

        harness.$height.wrappedValue = 100.3
        settle(graph, recomposer, width: 300.4, height: 100.3)
        #expect(recorder.sizes.allSatisfy { !$0.height.isApproximatelyEqual(to: 100.3) })
        #expect(recorder.sizes.last?.height.isApproximatelyEqual(to: 100) == true)
        #expect(!recomposer.hasPending)
    } }
}

private extension CGFloat {
    func isApproximatelyEqual(to other: CGFloat) -> Bool {
        abs(self - other) <= 0.05
    }
}
