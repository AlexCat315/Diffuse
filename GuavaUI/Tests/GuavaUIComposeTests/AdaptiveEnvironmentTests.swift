import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Adaptive environment readers", .serialized)
struct AdaptiveEnvironmentTests: GuavaUIComposeSerializedSuite {
    @Test("WidthClassReader follows the surface breakpoints independently of input density")
    func widthClasses() { GlobalTestLock.locked {
        final class Reads { var values: [UIEnvironment.WidthClass] = []
            func content(_ value: UIEnvironment.WidthClass) -> some View { values.append(value); return EmptyView() }
        }
        let reads = Reads(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        var surface = UIEnvironment()
        for (width, expected): (Float, UIEnvironment.WidthClass) in [(599, .compact), (600, .medium), (999, .medium), (1000, .expanded)] {
            surface.viewport.width = width; surface.input = [.touch]
            graph.install(root: WidthClassReader { reads.content($0) }.surfaceEnvironment(surface))
            #expect(reads.values.last == expected)
        }
    } }

    @Test("layout density floors preserve authored minima and their changes while active")
    func minimumFloorRestoration() throws { try GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Box {}.frame(width: 20, height: 20, minWidth: 30, minHeight: 32))
        let node = try #require(graph.tree.root?.children.first), layout = try #require(node.layoutNode)
        layout.setMinimumSizeFloor(CGSize(width: 44, height: 44))
        graph.computeLayout(width: 300, height: 200)
        #expect(node.frame.size == CGSize(width: 44, height: 44))
        #expect(layout.minWidth == 30 && layout.minHeight == 32)
        layout.minWidth = 60; layout.minHeight = 36
        graph.computeLayout(width: 300, height: 200)
        #expect(node.frame.size == CGSize(width: 60, height: 44))
        layout.setMinimumSizeFloor(nil)
        graph.computeLayout(width: 300, height: 200)
        #expect(node.frame.size == CGSize(width: 60, height: 36))
        layout.minWidth = nil; layout.minHeight = nil
        graph.computeLayout(width: 300, height: 200)
        #expect(node.frame.size == CGSize(width: 20, height: 20))
    } }
}
