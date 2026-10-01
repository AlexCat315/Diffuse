import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Animated visibility", .serialized)
struct AnimatedVisibilityTests: GuavaUIComposeSerializedSuite {
    private struct Harness: View {
        @State var visible = true
        var body: some View {
            AnimatedVisibility(isVisible: visible, animation: Animation(duration: 0.2, curve: .linear)) {
                Button("Content") {}.frame(height: 80).debugName("visibility-content")
            }
        }
    }

    private func find(_ node: Node?, named name: String) -> Node? {
        guard let node else { return nil }
        if node.attachments[LayoutDebugAttachmentKey.debugName] as? String == name { return node }
        return node.children.lazy.compactMap { find($0, named: name) }.first
    }

    @Test("exit retains paint, disables input immediately, then removes content")
    func exitLifecycle() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext()
        let scheduler = AnimatorScheduler()
        try context.withCurrent {
            try AnimatorScheduler.$current.withValue(scheduler) {
                let harness = Harness()
                let tree = NodeTree()
                let graph = ViewGraph(tree: tree, recomposer: Recomposer())
                graph.install(root: harness)
                graph.computeLayout(width: 240, height: 180)
                let content = try #require(find(tree.root, named: "visibility-content"))
                harness.$visible.wrappedValue = false
                graph.recomposer.commitAll()
                #expect(find(tree.root, named: "visibility-content") === content)
                #expect(!content.acceptsSubtreeInput)
                scheduler.tick(deltaTime: 0.1)
                graph.computeLayout(width: 240, height: 180)
                #expect(find(tree.root, named: "visibility-content") != nil)
                scheduler.tick(deltaTime: 0.2)
                graph.recomposer.commitAll()
                graph.computeLayout(width: 240, height: 180)
                #expect(find(tree.root, named: "visibility-content") == nil)
                #expect(scheduler.activeCount == 0)
            }
        }
    } }

    @Test("reversing removal reuses the subtree and cancels the old animation")
    func reversal() throws { try GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        try AnimatorScheduler.$current.withValue(scheduler) {
            let harness = Harness()
            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            graph.install(root: harness)
            graph.computeLayout(width: 240, height: 180)
            let content = try #require(find(tree.root, named: "visibility-content"))
            harness.$visible.wrappedValue = false
            graph.recomposer.commitAll()
            scheduler.tick(deltaTime: 0.08)
            harness.$visible.wrappedValue = true
            graph.recomposer.commitAll()
            scheduler.tick(deltaTime: 1)
            graph.recomposer.commitAll()
            #expect(find(tree.root, named: "visibility-content") === content)
            #expect(content.acceptsSubtreeInput)
            #expect(scheduler.activeCount == 0)
        }
    } }
}
