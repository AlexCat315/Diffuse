import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// Step 6 — verify that `withAnimation` flows backgroundColor, foreground
/// color, and cornerRadius through the scheduler too, sharing the same
/// `animatableSet` helper as opacity. Frame and padding remain instant
/// writes for now (animating Yoga layout requires per-frame relayout
/// integration scheduled for a later step).
@Suite("Phase 8 / withAnimation → bg / fg / cornerRadius")
struct WithAnimationPropertiesTests {

    struct BgHarness: View {
        @State var color: Color = Color(r: 0, g: 0, b: 0, a: 1)
        var body: some View {
            _DebugNode(label: "x").background(color)
        }
    }

    struct FgHarness: View {
        @State var color: Color = Color(r: 0, g: 0, b: 0, a: 1)
        var body: some View {
            _DebugNode(label: "x").foregroundColor(color)
        }
    }

    struct CornerHarness: View {
        @State var r: Float = 0
        var body: some View {
            _DebugNode(label: "x").cornerRadius(r)
        }
    }

    @Test("backgroundColor animates through the scheduler")
    func backgroundAnimates() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = BgHarness()
            graph.install(root: h)

            let node = tree.root?.children.first?.children.first
            let target = Color(r: 1, g: 1, b: 1, a: 1)

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$color.wrappedValue = target
            }
            recomp.commitAll()
            #expect(node?.backgroundColor?.r == 0)
            #expect(scheduler.activeCount == 1)

            scheduler.tick(deltaTime: 0.5)
            #expect(node?.backgroundColor?.r == 0.5)

            scheduler.tick(deltaTime: 0.5)
            #expect(node?.backgroundColor?.r == 1.0)
            #expect(scheduler.activeCount == 0)
        }
    }

    @Test("foregroundColor animates through the scheduler")
    func foregroundAnimates() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = FgHarness()
            graph.install(root: h)

            let node = tree.root?.children.first?.children.first

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$color.wrappedValue = Color(r: 1, g: 0.5, b: 0, a: 1)
            }
            recomp.commitAll()
            #expect(scheduler.activeCount == 1)

            scheduler.tick(deltaTime: 0.5)
            #expect(node?.foregroundColor?.r == 0.5)
            #expect(node?.foregroundColor?.g == 0.25)
        }
    }

    @Test("cornerRadius animates through the scheduler")
    func cornerRadiusAnimates() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = CornerHarness()
            graph.install(root: h)

            let node = tree.root?.children.first?.children.first

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$r.wrappedValue = 10
            }
            recomp.commitAll()
            #expect(node?.cornerRadius == 0)
            #expect(scheduler.activeCount == 1)

            scheduler.tick(deltaTime: 0.5)
            #expect(node?.cornerRadius == 5)

            scheduler.tick(deltaTime: 0.5)
            #expect(node?.cornerRadius == 10)
        }
    }

    @Test("Equal target value does not register a controller")
    func noOpForEqualTarget() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = CornerHarness()
            graph.install(root: h)

            // Same value — withAnimation present but no actual change.
            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$r.wrappedValue = 0
            }
            recomp.commitAll()
            #expect(scheduler.activeCount == 0)
        }
    }
}
