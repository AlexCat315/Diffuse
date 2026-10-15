public import Foundation
public import Testing
public import GuavaUIRuntime
@testable public import GuavaUICompose

/// Verify the node, geometry and input during the lifecycle, rather than only
/// the transition value supplied by the caller.
@Suite("Transition scale", .serialized)
struct TransitionScaleTests: GuavaUIComposeSerializedSuite {

    private final class Harness: View {
        @State var visible = false
        @State var reducedMotion = false
        var body: some View {
            AnimatedVisibility(isVisible: visible,
                               transition: .scale(from: 0.5, anchor: CGPoint(x: 1, y: 1)),
                               animation: Animation(duration: 1, curve: .linear),
                               animateOnMount: true) {
                _DebugNode(label: "panel").frame(width: 200, height: 100)
                    .debugName("panel")
            }.reducedMotion(reducedMotion).debugName("host")
        }
    }

    private final class Fixture {
        let scheduler = AnimatorScheduler()
        let recomposer = Recomposer()
        let harness = Harness()
        private var graph: ViewGraph!
        private(set) var root: Node!
        private(set) var host: Node!

        /// Must be called with this fixture's scheduler installed as
        /// `AnimatorScheduler.current`: `VisibilityState` captures the
        /// scheduler once, at mount, and registers its controllers with
        /// whatever it found then. Mounting outside the scope leaves it holding
        /// nothing, and the animation never advances — which looks exactly like
        /// a transition that does not reach the node.
        func mount() {
            let tree = NodeTree()
            graph = ViewGraph(tree: tree, recomposer: recomposer)
            graph.install(root: harness)
            frame(0)
            root = tree.root!
            host = TransitionScaleTests.find(root, named: "host")
        }

        /// Commit, advance, re-lay-out — the order the rest of the suite uses.
        /// A node with no laid-out frame reports a zero-width rectangle, which
        /// would make a scale assertion vacuous.
        func frame(_ delta: Double) {
            recomposer.commitAll()
            scheduler.tick(deltaTime: delta)
            graph.computeLayout(width: 240, height: 180)
        }
    }

    private static func find(_ node: Node?, named name: String) -> Node? {
        guard let node else { return nil }
        if node.attachments[LayoutDebugAttachmentKey.debugName] as? String == name { return node }
        return node.children.lazy.compactMap { find($0, named: name) }.first
    }

    @Test("A scaling transition scales the node it hosts")
    func scaleReachesTheNode() {
        GlobalTestLock.locked {
            let fixture = Fixture()
            AnimatorScheduler.$current.withValue(fixture.scheduler) {
                fixture.mount()
                fixture.harness.$visible.wrappedValue = true
                fixture.frame(0)
                // At the first frame the panel is exactly its insertion
                // state — 0.5 about the bottom-right corner.
                #expect(abs(fixture.host.transform.scale - 0.5) < 1e-5)

                // Halfway through a linear second, the scale is halfway from
                // 0.5 to 1.
                fixture.frame(0.5)
                #expect(abs(fixture.host.transform.scale - 0.75) < 0.02)

                fixture.frame(0.5)
                #expect(abs(fixture.host.transform.scale - 1) < 1e-5)
            }
        }
    }

    /// The anchor is the whole point of "grew out of the trigger". Losing it
    /// turns the motion into a uniform shrink about the centre, which is the
    /// generic default and reads as the panel inflating in place.
    @Test("The anchor is carried through, and settles to identity")
    func anchorSurvives() {
        GlobalTestLock.locked {
            let fixture = Fixture()
            AnimatorScheduler.$current.withValue(fixture.scheduler) {
                fixture.mount()
                fixture.harness.$visible.wrappedValue = true
                fixture.frame(0.1)
                #expect(fixture.host.transform.anchor == CGPoint(x: 1, y: 1))
                #expect(fixture.host.transform.scale < 1)
                #expect(!fixture.host.transform.scalesShadow)

                fixture.frame(1)
                // Settles to identity, which carries the default anchor with
                // it — nothing is left behind on the node for the next
                // transition to trip over.
                #expect(fixture.host.transform.isIdentity)
            }
        }
    }

    /// A panel that is still growing must be clickable where it is drawn, not
    /// where it will end up — otherwise the visible gap swallows clicks that
    /// land on nothing. This is the seam between the geometry work and the
    /// transition work.
    @Test("A part-grown panel is hit where it is drawn")
    func growingPanelIsHittable() {
        GlobalTestLock.locked {
            let fixture = Fixture()
            AnimatorScheduler.$current.withValue(fixture.scheduler) {
                fixture.mount()
                fixture.harness.$visible.wrappedValue = true
                fixture.frame(0.5)

                let panel = fixture.host.absoluteFrame
                #expect(panel.width > 100)
                #expect(panel.width < 200)

                // The host itself is not hit-testable — its content is — so
                // the question is whether the *content* is reachable across
                // the whole grown rectangle and nowhere past it.
                let content = TransitionScaleTests.find(fixture.host, named: "panel")
                let inside = HitTester.hitTest(
                    rootNode: fixture.root,
                    point: CGPoint(x: panel.minX + 2, y: panel.minY + 2))
                #expect(inside?.node === content)
                // The space it has yet to reach is not clickable.
                let beyond = HitTester.hitTest(
                    rootNode: fixture.root,
                    point: CGPoint(x: panel.maxX + 2, y: panel.minY + 2))
                #expect(beyond?.node !== content)
            }
        }
    }

    // MARK: - Effect algebra

    @Test("Scales combine by multiplying")
    func scalesMultiply() {
        let a = Transition.scale(from: 0.5, anchor: .zero)
        #expect(a.combined(with: a).insertion.scale.scale == 0.25)
    }

    @Test("Combining with an identity transform changes nothing")
    func identityIsNeutral() {
        let a = Transition.scale(from: 0.5, anchor: CGPoint(x: 1, y: 1))
        #expect(a.combined(with: .identity) == a)
        #expect(Transition.identity.combined(with: a) == a)
    }

    @Test("Interpolating reaches both endpoints exactly")
    func interpolationEndpoints() {
        let from = Transition.Effect(opacity: 0, x: -4, y: -2,
                                      scale: NodeTransform(scale: 0.5, anchor: .zero))
        let to = Transition.Effect()
        #expect(from.interpolating(to: to, 0) == from)
        #expect(from.interpolating(to: to, 1) == to)
    }

    @Test("Interpolation retains the active anchor when growing to identity")
    func anchorIsDiscrete() {
        let from = Transition.scale(from: 0.5, anchor: CGPoint(x: 1, y: 1)).insertion
        let to = Transition.Effect()
        #expect(from.interpolating(to: to, 0.5).scale.anchor == CGPoint(x: 1, y: 1))
        #expect(to.interpolating(to: from, 0.5).scale.anchor == CGPoint(x: 1, y: 1))
        #expect(from.interpolating(to: to, 0) == from)
        #expect(from.interpolating(to: to, 1) == to)
    }

    /// `collapse` decides layout rather than paint and is read off the
    /// transition as a whole, so it is carried as a flag and never becomes a
    /// fraction of one.
    @Test("Collapsing is a flag, and is never a fraction of one")
    func collapseIsNotAFraction() {
        let from = Transition.Effect()
        let to = Transition.Effect(collapse: true)
        #expect(from.interpolating(to: to, 0.5).collapse)
        #expect(from.interpolating(to: to, 0.5).opacity == 1)
    }

    @Test("Reversal continues at the displayed scale; exit disables input and cleans up")
    func reversalAndCleanup() {
        GlobalTestLock.locked {
            let fixture = Fixture()
            AnimatorScheduler.$current.withValue(fixture.scheduler) {
                fixture.mount()
                fixture.harness.$visible.wrappedValue = true
                fixture.frame(0.4)
                let displayed = fixture.host.transform
                fixture.harness.$visible.wrappedValue = false
                fixture.frame(0)
                #expect(fixture.host.transform == displayed)
                #expect(!fixture.host.isInteractionEnabled && !fixture.host.allowsHitTesting)
                fixture.frame(0.2)
                #expect(fixture.host.transform.scale < displayed.scale)
                let reversing = fixture.host.transform
                fixture.harness.$visible.wrappedValue = true
                fixture.frame(0)
                #expect(fixture.host.transform == reversing)
                fixture.frame(1)
                #expect(fixture.host.transform == .identity && fixture.scheduler.activeCount == 0)
                fixture.harness.$visible.wrappedValue = false
                fixture.frame(1); fixture.frame(0)
                #expect(fixture.host.children.isEmpty && fixture.scheduler.activeCount == 0)
            }
        }
    }

    @Test("Scale factors and anchors do not introduce nonfinite geometry")
    func invalidFactors() {
        for factor: CGFloat in [.nan, .infinity, -.infinity] {
            #expect(Transition.scale(from: factor, anchor: .zero).insertion.scale.isIdentity)
        }
        #expect(Transition.scale(from: -1, anchor: CGPoint(x: CGFloat.nan, y: CGFloat.infinity)).insertion.scale
            == NodeTransform(scale: 0, anchor: .zero, scalesShadow: false))
    }

    @Test("Reduced motion finishes an active scale and makes subsequent reveals immediate")
    func reducedMotion() {
        GlobalTestLock.locked {
            let fixture = Fixture()
            AnimatorScheduler.$current.withValue(fixture.scheduler) {
                fixture.mount()
                fixture.harness.$visible.wrappedValue = true; fixture.frame(0.3)
                #expect(fixture.host.transform.scale < 1)
                fixture.harness.$reducedMotion.wrappedValue = true
                fixture.frame(0); fixture.frame(0)
                #expect(fixture.host.transform == .identity && fixture.scheduler.activeCount == 0)
                fixture.harness.$visible.wrappedValue = false; fixture.frame(0); fixture.frame(0)
                #expect(fixture.host.children.isEmpty && fixture.scheduler.activeCount == 0)
                fixture.harness.$visible.wrappedValue = true; fixture.frame(0)
                #expect(fixture.host.transform == .identity && fixture.scheduler.activeCount == 0)
            }
        }
    }
}
