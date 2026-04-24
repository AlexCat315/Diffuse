import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// Step 5 — verify that `withAnimation { state = ... }` causes opacity
/// changes to flow through the animator instead of writing the new value
/// instantaneously, and that the eventual scheduler tick converges on the
/// target value.
@Suite("Phase 8 / withAnimation → opacity")
struct WithAnimationOpacityTests {

    private enum _ExpectedError: Error {
        case boom
    }

    /// A view whose opacity is driven by a `@State Float`. We mutate the
    /// state from outside via the published binding, optionally wrapped in
    /// `withAnimation`, then drive the recomposer + scheduler manually.
    struct OpacityHarness: View {
        @State var alpha: Float = 0.0
        var body: some View {
            _DebugNode(label: "x").opacity(alpha)
        }
    }

    @Test("Plain mutation writes opacity instantly")
    func plainMutationIsInstant() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = OpacityHarness()
            graph.install(root: h)

            let node = tree.root?.children.first?.children.first
            #expect(node?.opacity == 0)

            h.$alpha.wrappedValue = 1.0
            recomp.commitAll()

            #expect(node?.opacity == 1.0)
            #expect(scheduler.activeCount == 0)
        }
    }

    @Test("withAnimation defers opacity through the scheduler")
    func animatedMutationGoesThroughScheduler() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = OpacityHarness()
            graph.install(root: h)
            tree.flush()

            let node = tree.root?.children.first?.children.first
            #expect(node?.opacity == 0)

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$alpha.wrappedValue = 1.0
            }
            recomp.commitAll()
            #expect(node?.opacity == 0)
            #expect(scheduler.activeCount == 1)
            #expect(node?.renderDirty == false)

            scheduler.tick(deltaTime: 0.5)
            #expect(node?.opacity == 0.5)
            #expect(node?.renderDirty == true)

            scheduler.tick(deltaTime: 0.5)
            #expect(node?.opacity == 1.0)
            #expect(scheduler.activeCount == 0)
        }
    }

    @Test("withAnimation(nil) opts out of an outer animation")
    func nilAnimationOptsOut() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = OpacityHarness()
            graph.install(root: h)

            let node = tree.root?.children.first?.children.first

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                withAnimation(nil) {
                    h.$alpha.wrappedValue = 1.0
                }
            }
            recomp.commitAll()

            // Inner nil overrides outer → instant write.
            #expect(node?.opacity == 1.0)
            #expect(scheduler.activeCount == 0)
        }
    }

    @Test("withAnimation default overload uses Animation.default")
    func defaultOverloadAnimates() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = OpacityHarness()
            graph.install(root: h)

            let node = tree.root?.children.first?.children.first
            #expect(node?.opacity == 0)

            withAnimation {
                h.$alpha.wrappedValue = 1.0
            }
            recomp.commitAll()
            #expect(scheduler.activeCount == 1)

            scheduler.tick(deltaTime: Animation.default.duration)
            #expect(node?.opacity == 1.0)
            #expect(scheduler.activeCount == 0)
        }
    }

    @Test("withAnimation rethrows errors from the body")
    func rethrowsError() {
        var observed = false
        do {
            let _: Void = try withAnimation(Animation(duration: 0.1, curve: .linear)) {
                observed = true
                throw _ExpectedError.boom
            }
            Issue.record("expected withAnimation body to throw")
        } catch _ExpectedError.boom {
            #expect(observed == true)
            #expect(ActiveAnimationContext.current == nil)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("ActiveAnimationContext.current is nil outside withAnimation")
    func contextNilOutside() {
        #expect(ActiveAnimationContext.current == nil)
    }
}
