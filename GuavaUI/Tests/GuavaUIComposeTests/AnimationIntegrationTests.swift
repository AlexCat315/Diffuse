import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// Step 10 — integration coverage for the animation system.
///
/// Exercises the moving parts end-to-end through `withAnimation` /
/// `.animation(_:value:)` and the per-frame scheduler tick:
///
/// - multiple animated properties on the same node concurrently;
/// - multiple animated nodes concurrently;
/// - nested `withAnimation` blocks (inner wins);
/// - zero-duration animations snap;
/// - mid-flight retarget converges on the final value;
/// - scheduler quiesces (`activeCount == 0`) once everything finishes.
@Suite("Phase 8 / animation integration", .serialized)
struct AnimationIntegrationTests: GuavaUIComposeSerializedSuite {

    struct DualPropHarness: View {
        @State var t: Float = 0.0
        var body: some View {
            _DebugNode(label: "dual")
                .opacity(t)
                .background(Color(r: t, g: t, b: t, a: 1))
        }
    }

    struct DualNodeHarness: View {
        @State var t: Float = 0.0
        var body: some View {
            _DebugNode(label: "a").opacity(t)
            _DebugNode(label: "b").opacity(t)
        }
    }

    struct SinglePropHarness: View {
        @State var t: Float = 0.0
        var body: some View {
            _DebugNode(label: "single").opacity(t)
        }
    }

    struct LayoutWidthHarness: View {
        @State var width: Float = 40
        var body: some View {
            Box {
                _DebugNode(label: "leaf")
                    .frame(width: width, height: 20)
            }
            .frame(width: 200, height: 60)
        }
    }

    struct LayoutPaddingHarness: View {
        @State var pad: EdgeInsets = .init(all: 0)
        var body: some View {
            Box {
                _DebugNode(label: "leaf")
                    .frame(width: 40, height: 20)
            }
            .frame(width: 200, height: 60)
            .padding(pad)
        }
    }

    struct LayoutPercentWidthHarness: View {
        @State var widthPercent: Float = 20
        var body: some View {
            Box {
                _DebugNode(label: "leaf")
                    .frame(height: 20, widthPercent: widthPercent)
            }
            .frame(width: 200, height: 60)
        }
    }

    struct LayoutPercentToAutoHarness: View {
        @State var useAuto = false
        var body: some View {
            Box {
                if useAuto {
                    _DebugNode(label: "leaf")
                        .frame(height: 20)
                } else {
                    _DebugNode(label: "leaf")
                        .frame(height: 20, widthPercent: 20)
                }
            }
            .frame(width: 200, height: 60)
        }
    }

    struct LayoutPercentHeightHarness: View {
        @State var heightPercent: Float = 20
        var body: some View {
            Box {
                _DebugNode(label: "leaf")
                    .frame(width: 40, heightPercent: heightPercent)
            }
            .frame(width: 200, height: 100)
        }
    }

    struct LayoutPercentHeightToAutoHarness: View {
        @State var useAuto = false
        var body: some View {
            Box {
                if useAuto {
                    _DebugNode(label: "leaf")
                        .frame(width: 40)
                } else {
                    _DebugNode(label: "leaf")
                        .frame(width: 40, heightPercent: 20)
                }
            }
            .frame(width: 200, height: 100)
        }
    }

    struct LayoutPercentWithClampHarness: View {
        @State var widthPercent: Float = 20
        @State var heightPercent: Float = 20
        var body: some View {
            Box {
                _DebugNode(label: "leaf")
                    .frame(widthPercent: widthPercent,
                           heightPercent: heightPercent,
                           minWidth: 70,
                           minHeight: 30,
                           maxWidth: 90,
                           maxHeight: 40)
            }
            .frame(width: 200, height: 100)
        }
    }

    struct LayoutPercentToAutoWithMinHarness: View {
        @State var useAuto = false
        var body: some View {
            Box {
                if useAuto {
                    _DebugNode(label: "leaf")
                        .frame(height: 20, minWidth: 70)
                } else {
                    _DebugNode(label: "leaf")
                        .frame(height: 20, widthPercent: 20, minWidth: 70)
                }
            }
            .frame(width: 200, height: 100)
        }
    }

    struct LayoutPointsToPercentSwitchHarness: View {
        @State var width: Float = 40
        @State var usePercent = false
        var body: some View {
            Box {
                _DebugNode(label: "leaf")
                    .frame(width: usePercent ? nil : width,
                           height: 20,
                           widthPercent: usePercent ? 30 : nil)
            }
            .frame(width: 200, height: 100)
        }
    }

    private func leaves(_ root: Node) -> [Node] {
        var out: [Node] = []
        func walk(_ n: Node) {
            if n.children.isEmpty { out.append(n) }
            else { n.children.forEach(walk) }
        }
        walk(root)
        return out
    }

    @Test("Same node, multiple properties animate concurrently")
    func dualProperty() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = DualPropHarness()
            graph.install(root: h)

            let node = leaves(tree.root!).first

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$t.wrappedValue = 1.0
            }
            recomp.commitAll()
            // Two controllers: one for opacity, one for backgroundColor.
            #expect(scheduler.activeCount == 2)

            scheduler.tick(deltaTime: 0.5)
            #expect(node?.opacity == 0.5)
            #expect(node?.backgroundColor?.r == 0.5)

            scheduler.tick(deltaTime: 0.5)
            #expect(node?.opacity == 1.0)
            #expect(node?.backgroundColor?.r == 1.0)
            #expect(scheduler.activeCount == 0)
        }
    } }

    @Test("Multiple nodes animate concurrently from a single state mutation")
    func dualNode() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = DualNodeHarness()
            graph.install(root: h)

            let leafs = leaves(tree.root!)
            #expect(leafs.count == 2)

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$t.wrappedValue = 1.0
            }
            recomp.commitAll()
            #expect(scheduler.activeCount == 2)

            scheduler.tick(deltaTime: 1.0)
            for n in leafs {
                #expect(n.opacity == 1.0)
            }
            #expect(scheduler.activeCount == 0)
        }
    } }

    @Test("Nested withAnimation: inner wins")
    func nestedAnimation() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let outer = Animation(duration: 1.0, curve: .linear)
            let inner = Animation(duration: 0.10, curve: .linear)

            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = DualPropHarness()
            graph.install(root: h)

            let node = leaves(tree.root!).first

            withAnimation(outer) {
                withAnimation(inner) {
                    h.$t.wrappedValue = 1.0
                }
            }
            recomp.commitAll()

            // Inner duration = 0.10 → completes after a single 0.10 tick.
            scheduler.tick(deltaTime: 0.10)
            #expect(node?.opacity == 1.0)
            #expect(scheduler.activeCount == 0)
        }
    } }

    @Test("Zero-duration animation snaps to target on commit")
    func zeroDurationSnaps() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = DualPropHarness()
            graph.install(root: h)

            let node = leaves(tree.root!).first

            withAnimation(Animation(duration: 0.0, curve: .linear)) {
                h.$t.wrappedValue = 1.0
            }
            recomp.commitAll()

            // Zero duration → controller marks itself finished on construction
            // and writes the target value immediately.
            #expect(node?.opacity == 1.0)
            // Scheduler may still hold the controller until next tick prunes
            // it; one tick clears the slate.
            scheduler.tick(deltaTime: 0)
            #expect(scheduler.activeCount == 0)
        }
    } }

    @Test("Mid-flight retarget converges on the final value")
    func midFlightRetarget() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = DualPropHarness()
            graph.install(root: h)

            let node = leaves(tree.root!).first

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$t.wrappedValue = 1.0
            }
            recomp.commitAll()
            scheduler.tick(deltaTime: 0.5)
            #expect(node?.opacity == 0.5)

            // Retarget to 0 mid-flight. Spawns a new controller from the
            // current value (0.5) toward 0.
            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$t.wrappedValue = 0.0
            }
            recomp.commitAll()

            // Drive to convergence. Both old + new controllers may still tick
            // briefly; the final value must be the most recent target.
            for _ in 0..<10 {
                scheduler.tick(deltaTime: 0.2)
            }
            #expect(node?.opacity == 0.0)
            #expect(node?.backgroundColor?.r == 0.0)
            #expect(scheduler.activeCount == 0)
        }
    } }

    @Test("Retargeting same property cancels superseded controller")
    func retargetCancelsSupersededController() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = SinglePropHarness()
            graph.install(root: h)

            let node = leaves(tree.root!).first

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$t.wrappedValue = 1.0
            }
            recomp.commitAll()
            #expect(scheduler.activeCount == 1)

            scheduler.tick(deltaTime: 0.3)
            #expect(node?.opacity == 0.3)

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$t.wrappedValue = 0.0
            }
            recomp.commitAll()
            #expect(scheduler.activeCount == 1)

            scheduler.tick(deltaTime: 0.2)
            #expect((node?.opacity ?? 0) < 0.3)

            scheduler.tick(deltaTime: 0.8)
            #expect(node?.opacity == 0.0)
            #expect(scheduler.activeCount == 0)
        }
    } }

    @Test("Plain commit during an active animation does not register a new controller")
    func plainWriteDuringAnimation() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = DualPropHarness()
            graph.install(root: h)

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$t.wrappedValue = 1.0
            }
            recomp.commitAll()
            #expect(scheduler.activeCount == 2)

            scheduler.tick(deltaTime: 0.3)
            let beforeCount = scheduler.activeCount

            // Plain (no withAnimation) write to the same value — no-op
            // because target equals previous.
            h.$t.wrappedValue = 1.0
            recomp.commitAll()
            #expect(scheduler.activeCount == beforeCount)

            scheduler.tick(deltaTime: 0.7)
            #expect(scheduler.activeCount == 0)
        }
    } }

    @Test("Layout frame width updates over ticks in a real container")
    func layoutFrameWidthE2E() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = LayoutWidthHarness()
            graph.install(root: h)

            graph.computeLayout(width: 300, height: 120)
            let leaf = leaves(tree.root!).first(where: { $0.isHitTestable })
            #expect(leaf?.frame.width == 40)

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$width.wrappedValue = 120
            }
            recomp.commitAll()

            scheduler.tick(deltaTime: 0.5)
            graph.computeLayout(width: 300, height: 120)
            #expect(leaf?.frame.width == 80)

            scheduler.tick(deltaTime: 0.5)
            graph.computeLayout(width: 300, height: 120)
            #expect(leaf?.frame.width == 120)
        }
    } }

    @Test("Layout frame origin updates over ticks when padding animates")
    func layoutPaddingE2E() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = LayoutPaddingHarness()
            graph.install(root: h)

            graph.computeLayout(width: 300, height: 120)
            let leaf = leaves(tree.root!).first(where: { $0.isHitTestable })
            #expect(leaf?.frame.origin.x == 0)
            #expect(leaf?.frame.origin.y == 0)

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$pad.wrappedValue = .init(all: 20)
            }
            recomp.commitAll()

            scheduler.tick(deltaTime: 0.5)
            graph.computeLayout(width: 300, height: 120)
            #expect(leaf?.frame.origin.x == 10)
            #expect(leaf?.frame.origin.y == 10)

            scheduler.tick(deltaTime: 0.5)
            graph.computeLayout(width: 300, height: 120)
            #expect(leaf?.frame.origin.x == 20)
            #expect(leaf?.frame.origin.y == 20)
        }
    } }

    @Test("Layout frame width updates over ticks when widthPercent animates")
    func layoutPercentWidthE2E() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = LayoutPercentWidthHarness()
            graph.install(root: h)

            graph.computeLayout(width: 300, height: 120)
            let leaf = leaves(tree.root!).first(where: { $0.isHitTestable })
            #expect(leaf?.frame.width == 40)

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$widthPercent.wrappedValue = 60
            }
            recomp.commitAll()

            scheduler.tick(deltaTime: 0.5)
            graph.computeLayout(width: 300, height: 120)
            #expect(leaf?.frame.width == 80)

            scheduler.tick(deltaTime: 0.5)
            graph.computeLayout(width: 300, height: 120)
            #expect(leaf?.frame.width == 120)
        }
    } }

    @Test("Percent to auto mode switch snaps to container width")
    func layoutPercentToAutoSnaps() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = LayoutPercentToAutoHarness()
            graph.install(root: h)

            graph.computeLayout(width: 300, height: 120)
            let leaf = leaves(tree.root!).first(where: { $0.isHitTestable })
            #expect(leaf?.frame.width == 40)

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$useAuto.wrappedValue = true
            }
            recomp.commitAll()
            graph.computeLayout(width: 300, height: 120)

            // percent -> auto is a mode switch and should snap immediately.
            #expect(scheduler.activeCount == 0)
            #expect(leaf?.frame.width == 200)
        }
    } }

    @Test("Layout frame height updates over ticks when heightPercent animates")
    func layoutPercentHeightE2E() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = LayoutPercentHeightHarness()
            graph.install(root: h)

            graph.computeLayout(width: 300, height: 160)
            let leaf = leaves(tree.root!).first(where: { $0.isHitTestable })
            #expect(leaf?.frame.height == 20)

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$heightPercent.wrappedValue = 60
            }
            recomp.commitAll()

            scheduler.tick(deltaTime: 0.5)
            graph.computeLayout(width: 300, height: 160)
            #expect(leaf?.frame.height == 40)

            scheduler.tick(deltaTime: 0.5)
            graph.computeLayout(width: 300, height: 160)
            #expect(leaf?.frame.height == 60)
        }
    } }

    @Test("Percent to auto mode switch snaps to container height")
    func layoutPercentHeightToAutoSnaps() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = LayoutPercentHeightToAutoHarness()
            graph.install(root: h)

            graph.computeLayout(width: 300, height: 160)
            let leaf = leaves(tree.root!).first(where: { $0.isHitTestable })
            #expect(leaf?.frame.height == 20)

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$useAuto.wrappedValue = true
            }
            recomp.commitAll()
            graph.computeLayout(width: 300, height: 160)

            #expect(scheduler.activeCount == 0)
            // In this container, auto height resolves to the leaf's
            // intrinsic height (0 for _DebugNode), not parent stretch.
            #expect(leaf?.frame.height == 0)
        }
    } }

    @Test("Percent dimensions respect min/max clamps during layout animation")
    func layoutPercentWithClampE2E() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = LayoutPercentWithClampHarness()
            graph.install(root: h)

            graph.computeLayout(width: 300, height: 160)
            let leaf = leaves(tree.root!).first(where: { $0.isHitTestable })
            #expect(leaf?.frame.width == 70)
            #expect(leaf?.frame.height == 30)

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$widthPercent.wrappedValue = 60
                h.$heightPercent.wrappedValue = 80
            }
            recomp.commitAll()

            scheduler.tick(deltaTime: 1.0)
            graph.computeLayout(width: 300, height: 160)
            #expect(leaf?.frame.width == 90)
            #expect(leaf?.frame.height == 40)
        }
    } }

    @Test("Percent to auto keeps min constraint and clears active animation")
    func layoutPercentToAutoKeepsMinWidth() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = LayoutPercentToAutoWithMinHarness()
            graph.install(root: h)

            graph.computeLayout(width: 300, height: 160)
            let leaf = leaves(tree.root!).first(where: { $0.isHitTestable })
            #expect(leaf?.frame.width == 70)

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$useAuto.wrappedValue = true
            }
            recomp.commitAll()
            graph.computeLayout(width: 300, height: 160)

            #expect(scheduler.activeCount == 0)
            // In this container, auto width resolves to stretch behavior.
            #expect(leaf?.frame.width == 200)
        }
    } }

    @Test("Points to percent mode switch cancels in-flight width animation")
    func layoutPointsToPercentSwitchCancelsController() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = LayoutPointsToPercentSwitchHarness()
            graph.install(root: h)

            graph.computeLayout(width: 300, height: 160)
            let leaf = leaves(tree.root!).first(where: { $0.isHitTestable })
            #expect(leaf?.frame.width == 40)

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$width.wrappedValue = 120
            }
            recomp.commitAll()
            #expect(scheduler.activeCount == 1)

            scheduler.tick(deltaTime: 0.5)
            graph.computeLayout(width: 300, height: 160)
            #expect(leaf?.frame.width == 80)

            withAnimation(Animation(duration: 1.0, curve: .linear)) {
                h.$usePercent.wrappedValue = true
            }
            recomp.commitAll()
            graph.computeLayout(width: 300, height: 160)

            // points -> percent is a mode switch: layout snaps immediately.
            // The canceled controller is swept from the scheduler on next tick.
            #expect(scheduler.activeCount == 1)
            #expect(leaf?.frame.width == 60)

            scheduler.tick(deltaTime: 0)
            #expect(scheduler.activeCount == 0)
        }
    } }
}
