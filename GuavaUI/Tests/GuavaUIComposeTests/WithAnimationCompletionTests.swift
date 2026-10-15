import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// `withAnimation(_:completionCriteria:_:completion:)` — the callback has to
/// land on the frame its last controller finishes, and *not* land when the
/// animation was merely interrupted.
@Suite("withAnimation completion", .serialized)
struct WithAnimationCompletionTests: GuavaUIComposeSerializedSuite {

    struct Harness: View {
        @State var alpha: Float = 0.0
        var body: some View { _DebugNode(label: "x").opacity(alpha) }
    }

    /// One harness wired to its own tree, recomposer and scheduler, matching
    /// how the existing `withAnimation` tests drive the runtime by hand.
    private final class Fixture {
        let scheduler = AnimatorScheduler()
        let recomposer = Recomposer()
        let harness = Harness()
        let node: Node?
        // Held for the fixture's lifetime: the graph registers itself with the
        // runtime, and letting it go at the end of `init` tears the harness
        // back down before a single frame is driven.
        private let graph: ViewGraph

        init() {
            let tree = NodeTree()
            graph = ViewGraph(tree: tree, recomposer: recomposer)
            graph.install(root: harness)
            tree.flush()
            node = tree.root?.children.first?.children.first
        }

        /// A frame: commit whatever the mutation queued, then advance the clock.
        func frame(_ delta: Double) {
            recomposer.commitAll()
            scheduler.tick(deltaTime: delta)
        }
    }

    private let oneSecond = Animation(duration: 1.0, curve: .linear)

    private final class ReducedHarness: View {
        @State var alpha: Float = 0
        @State var reduced = false
        var body: some View { _DebugNode(label: "reduced").opacity(alpha).reducedMotion(reduced) }
    }
    @Test("Enabling reduced motion finishes the current target and its completion")
    func reducedMotionCompletes() {
        GlobalTestLock.locked {
            let scheduler = AnimatorScheduler()
            AnimatorScheduler.$current.withValue(scheduler) {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer()), harness = ReducedHarness()
                defer { graph.install(root: EmptyView()) }
                graph.install(root: harness)
                var completions = 0
                withAnimation(oneSecond, completionCriteria: .removed) {
                    harness.$alpha.wrappedValue = 1
                } completion: { completions += 1 }
                graph.recomposer.commitAll(); scheduler.tick(deltaTime: 0.1)
                #expect(completions == 0 && scheduler.activeCount == 1)
                harness.$reduced.wrappedValue = true
                graph.recomposer.commitAll(); scheduler.tick(deltaTime: 0)
                #expect(completions == 1 && scheduler.activeCount == 0)
            }
        }
    }

    @Test("The callback fires on the frame the animation lands")
    func firesWhenTheLastControllerFinishes() {
        GlobalTestLock.locked {
            let fixture = Fixture()
            AnimatorScheduler.$current.withValue(fixture.scheduler) {
                var fired = 0
                withAnimation(oneSecond) {
                    fixture.harness.$alpha.wrappedValue = 1.0
                } completion: { fired += 1 }

                fixture.frame(0.5)
                #expect(fired == 0)
                fixture.frame(0.25)
                #expect(fired == 0)
                // Still short of the target.
                fixture.frame(0.2)
                #expect(fired == 0)
                fixture.frame(0.5)
                #expect(fired == 1)
                // Exactly once.
                fixture.frame(0.5)
                #expect(fired == 1)
            }
        }
    }

    @Test("A mutation that animates nothing still completes")
    func firesWhenNothingAnimates() {
        GlobalTestLock.locked {
            let fixture = Fixture()
            AnimatorScheduler.$current.withValue(fixture.scheduler) {
                var fired = 0
                // Writing the value it already holds registers no controller.
                withAnimation(oneSecond) {
                    fixture.harness.$alpha.wrappedValue = fixture.harness.$alpha.wrappedValue
                } completion: { fired += 1 }
                #expect(fired == 0)
                fixture.frame(0.1)
                #expect(fired == 1)
            }
        }
    }

    @Test("An interrupted animation does not complete")
    func doesNotFireWhenSuperseded() {
        GlobalTestLock.locked {
            let fixture = Fixture()
            AnimatorScheduler.$current.withValue(fixture.scheduler) {
                var fired = 0
                withAnimation(oneSecond) {
                    fixture.harness.$alpha.wrappedValue = 1.0
                } completion: { fired += 1 }

                // One frame so the mutation commits and a controller is really
                // running — two writes before any commit coalesce into a single
                // recompose and never interrupt anything.
                fixture.frame(0.5)

                withAnimation(oneSecond) { fixture.harness.$alpha.wrappedValue = 0.25 }
                fixture.frame(0.5)
                fixture.frame(2.0)
                #expect(fired == 0)
            }
        }
    }

    /// Two writes landing before the first commit are one recompose, not an
    /// interruption. The scope keeps the first animation — and its completion —
    /// and the merged animation fires it when it lands.
    @Test("Writes coalesced into one commit share a single completion")
    func coalescedWritesCompleteOnce() {
        GlobalTestLock.locked {
            let fixture = Fixture()
            AnimatorScheduler.$current.withValue(fixture.scheduler) {
                var fired = 0
                withAnimation(oneSecond) {
                    fixture.harness.$alpha.wrappedValue = 1.0
                } completion: { fired += 1 }
                withAnimation(oneSecond) { fixture.harness.$alpha.wrappedValue = 0.25 }
                fixture.frame(2.0)
                #expect(fired == 1)
            }
        }
    }

    @Test("Without a callback the scheduler is untouched")
    func noCallbackTracksNothing() {
        GlobalTestLock.locked {
            let fixture = Fixture()
            AnimatorScheduler.$current.withValue(fixture.scheduler) {
                withAnimation(oneSecond) { fixture.harness.$alpha.wrappedValue = 1.0 }
                fixture.frame(0.1)
                #expect(fixture.scheduler.activeCount == 1)
                fixture.frame(2.0)
                #expect(fixture.scheduler.activeCount == 0)
            }
        }
    }
}
