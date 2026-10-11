import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Animated visibility", .serialized)
struct AnimatedVisibilityTests: GuavaUIComposeSerializedSuite {
    private struct Harness: View {
        @State var visible = true
        @State var reduceMotion = false
        @State var height: Float = 80
        @State var completed = 0
        var body: some View {
            AnimatedVisibility(isVisible: visible, transition: .opacity.combined(with: .collapse),
                animation: Animation(duration: 0.2, curve: .linear), onVisibilitySettled: { _ in completed += 1 }) {
                Button("Content") {}.frame(height: height).debugName("visibility-content")
            }.reducedMotion(reduceMotion).debugName("visibility-host")
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

    @Test("Reduced motion settles an active reveal, disables exit input and completes exactly once")
    func reducedMotionDuringExit() throws { try GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        try AnimatorScheduler.$current.withValue(scheduler) {
            let harness = Harness()
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: harness); graph.computeLayout(width: 240, height: 300)
            harness.$visible.wrappedValue = false; graph.recomposer.commitAll()
            scheduler.tick(deltaTime: 0.05)
            #expect(scheduler.activeCount == 1)
            harness.$reduceMotion.wrappedValue = true
            graph.recomposer.commitAll(); graph.recomposer.commitAll()
            #expect(find(graph.tree.root, named: "visibility-content") == nil)
            #expect(scheduler.activeCount == 0 && harness.completed == 1)
            harness.$visible.wrappedValue = true
            graph.recomposer.commitAll(); graph.recomposer.commitAll()
            #expect(find(graph.tree.root, named: "visibility-content")?.acceptsSubtreeInput == true)
            #expect(scheduler.activeCount == 0 && harness.completed == 2)
            scheduler.tick(deltaTime: 1); graph.recomposer.commitAll()
            #expect(harness.completed == 2)
        }
    } }

    @Test("Reveal measures changing content at its natural height, including shrinking during a reversal")
    func dynamicHeight() throws { try GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        try AnimatorScheduler.$current.withValue(scheduler) {
            let harness = Harness()
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            func settle() { for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 240, height: 300) } }
            graph.install(root: harness); settle()
            harness.$visible.wrappedValue = false; graph.recomposer.commitAll()
            scheduler.tick(deltaTime: 0.1); settle()
            #expect(find(graph.tree.root, named: "visibility-content")?.frame.height == 80)
            #expect(find(graph.tree.root, named: "visibility-host")?.frame.height == 40)
            harness.$height.wrappedValue = 160; settle()
            #expect(find(graph.tree.root, named: "visibility-host")?.frame.height == 80)
            harness.$height.wrappedValue = 40; settle()
            #expect(find(graph.tree.root, named: "visibility-host")?.frame.height == 20)
            harness.$visible.wrappedValue = true; graph.recomposer.commitAll()
            scheduler.tick(deltaTime: 1); settle()
            #expect(find(graph.tree.root, named: "visibility-host")?.frame.height == 40)
            #expect(harness.completed == 1)
            graph.install(root: EmptyView())
            #expect(scheduler.activeCount == 0)
        }
    } }

    @Test("Removing a transitioning subtree immediately releases its scheduler entry")
    func unmountCancels() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let harness = Harness()
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: harness); graph.computeLayout(width: 240, height: 180)
            harness.$visible.wrappedValue = false; graph.recomposer.commitAll()
            #expect(scheduler.activeCount == 1)
            graph.install(root: EmptyView())
            #expect(scheduler.activeCount == 0 && harness.completed == 0)
        }
    } }
}
