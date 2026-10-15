import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// Item 19 — an interrupted animation continues from the motion already on
/// screen instead of starting again from rest. A fixed-duration curve cannot
/// express this: it only ever maps elapsed time to progress, so a superseding
/// animation that begins at `t = 0` looks like the value stalling and
/// restarting.
@Suite("Spring interruption", .serialized)
struct SpringInterruptionTests: GuavaUIComposeSerializedSuite {

    private let response: Float = 0.4

    private func bouncy(_ allowsOvershoot: Bool = false) -> Animation {
        Animation(duration: Double(response),
                  curve: .spring(response: response, dampingFraction: 0.55),
                  allowsOvershoot: allowsOvershoot)
    }

    @Test("A spring reports the velocity it is travelling at")
    func reportsVelocity() {
        let controller = AnimationController(from: Float(0), to: Float(1),
                                             animation: bouncy()) { _ in }
        // Nothing has moved yet, so there is nothing to hand over.
        #expect(controller.progressVelocity == 0)
        controller.tick(deltaTime: 0.1)
        let first = controller.progressVelocity
        #expect(first > 0)
        controller.tick(deltaTime: 0.1)
        #expect(controller.progressVelocity != first)
    }

    @Test("Velocity at release is what the caller asked for")
    func releasedWithVelocity() {
        let solution = SpringSolution(response: response, dampingFraction: 0.7)
        #expect(abs(solution.velocity(at: 0, from: 0, velocity: 2.5) - 2.5) < 1e-3)
        #expect(abs(solution.velocity(at: 0, from: 0, velocity: -2.5) + 2.5) < 1e-3)
    }

    /// The endpoint anchor belongs to a spring released from rest — that is
    /// what `AnimationCurve.spring` samples. A spring that inherits velocity is
    /// already travelling, and pinning it to the same arrival instant would
    /// distort the motion it was handed; it approaches the target instead.
    @Test("Only a spring released from rest is pinned to its endpoint")
    func normalizationAppliesToRestOnly() {
        let solution = SpringSolution(response: response, dampingFraction: 0.55)
        #expect(abs(solution.position(at: response, from: 0, velocity: 0) - 1) < 1e-4)

        // Released with a shove it is somewhere else on its way, and must not
        // be yanked onto the same schedule.
        let shoved = solution.position(at: response, from: 0, velocity: 2.0)
        #expect(shoved != 1)
        // ...but it is still converging on the target rather than diverging.
        let later = solution.position(at: response * 3, from: 0, velocity: 2.0)
        #expect(abs(later - 1) < abs(shoved - 1))
    }

    struct Harness: View {
        @State var radius: Float = 0
        var body: some View { _DebugNode(label: "x").cornerRadius(radius) }
    }

    private final class Fixture {
        let scheduler = AnimatorScheduler()
        let recomposer = Recomposer()
        let harness = Harness()
        let node: Node?
        private let graph: ViewGraph

        init() {
            let tree = NodeTree()
            graph = ViewGraph(tree: tree, recomposer: recomposer)
            graph.install(root: harness)
            tree.flush()
            node = tree.root?.children.first?.children.first
        }

        func frame(_ delta: Double) {
            recomposer.commitAll()
            scheduler.tick(deltaTime: delta)
        }
    }

    /// The whole point: reversing mid-flight must not stall. From rest the
    /// second animation would start at zero rate, so the value would hold
    /// still for a frame before moving — which is exactly the stutter that
    /// made fast toggles read as broken.
    @Test("Reversing mid-flight does not stall the value")
    func reversalDoesNotStall() {
        GlobalTestLock.locked {
            let fixture = Fixture()
            AnimatorScheduler.$current.withValue(fixture.scheduler) {
                withAnimation(bouncy(true)) { fixture.harness.$radius.wrappedValue = 60 }
                fixture.frame(0.1)
                let rising = fixture.node?.cornerRadius ?? 0
                #expect(rising > 0)

                withAnimation(bouncy(true)) { fixture.harness.$radius.wrappedValue = 0 }
                fixture.frame(0.04)

                let afterReverse = fixture.node?.cornerRadius ?? -1
                // Still under the peak — it turned around rather than jumping.
                #expect(afterReverse < rising)
                // And still above zero: a release from rest at this instant
                // would also be above zero, so the distinguishing measurement
                // is the *rate* below, not the value.
                #expect(afterReverse > 0)
            }
        }
    }

    /// The measurable difference, at the level the mechanism lives. A successor
    /// released from rest begins the reversal with zero rate; one seeded with
    /// the outgoing controller's rate is already travelling when its first
    /// frame lands, so after the same slice of time it is further along.
    @Test("Seeding a successor with the outgoing rate moves it further")
    func seedingMovesTheSuccessorFurther() {
        let outgoing = AnimationController(from: Float(0), to: Float(1),
                                           animation: bouncy(true)) { _ in }
        outgoing.tick(deltaTime: 0.2)
        let rate = outgoing.progressVelocity
        #expect(rate > 0)

        func firstSlice(velocity: Float) -> Float {
            let controller = AnimationController(from: Float(0), to: Float(1),
                                                 animation: bouncy(true),
                                                 initialVelocity: velocity) { value in
                last = value
            }
            controller.tick(deltaTime: 0.05)
            return last
        }
        var last: Float = 0
        let fromRest = firstSlice(velocity: 0)
        last = 0
        let inherited = firstSlice(velocity: rate)

        #expect(inherited > fromRest)
        #expect(inherited < 1)
    }
}