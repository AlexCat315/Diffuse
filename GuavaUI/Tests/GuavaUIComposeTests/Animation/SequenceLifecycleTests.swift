import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Animation sequence lifecycle", .serialized)
struct SequenceLifecycleTests: GuavaUIComposeSerializedSuite {
    private final class Harness: View {
        @State var revision = 0
        @State var reduced = false
        var body: some View {
            Box(direction: .column) {
                KeyframeAnimator(KeyframeTimeline(initialValue: Float(0), keyframes: [.init(1, duration: 0.4)]), trigger: revision) { value in
                    _DebugNode(label: "track").opacity(value).debugName("lifecycle-track")
                }
                PhaseAnimator([Float(0), 0.5, 1], trigger: revision) { value in
                    _DebugNode(label: "phase").opacity(value).debugName("lifecycle-phase")
                }
            }.reducedMotion(reduced)
        }
    }
    @Test("Reduced motion keeps untriggered tracks at rest and does not replay completed sequences",
          arguments: [false, true])
    func restingState(initiallyReduced: Bool) throws {
        try GlobalTestLock.locked {
            let scheduler = AnimatorScheduler()
            try AnimatorScheduler.$current.withValue(scheduler) {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer()), harness = Harness()
                harness.$reduced.wrappedValue = initiallyReduced
                graph.install(root: harness)
                defer { graph.install(root: EmptyView()) }
                func settle() { for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 300, height: 200) } }
                func named(_ name: String) throws -> Node {
                    var pending = [graph.tree.root!], found: Node?
                    while let node = pending.popLast() {
                        if node.attachments[LayoutDebugAttachmentKey.debugName] as? String == name { found = node; break }
                        pending.append(contentsOf: node.children)
                    }
                    return try #require(found)
                }
                settle()
                let track = try named("lifecycle-track"), phase = try named("lifecycle-phase")
                #expect(track.opacity == 0)
                #expect(phase.opacity == 0)
                harness.$reduced.wrappedValue = true; settle()
                #expect(track.opacity == 0)
                #expect(phase.opacity == 0)
                harness.$revision.wrappedValue += 1; settle()
                #expect(track.opacity == 1)
                #expect(phase.opacity == 1)
                #expect(scheduler.activeCount == 0)
                harness.$reduced.wrappedValue = false; settle()
                #expect(scheduler.activeCount == 0 && !graph.recomposer.hasPending)
                #expect(track.opacity == 1)
                #expect(phase.opacity == 1)
            }
        }
    }
}
