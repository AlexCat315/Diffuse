import Foundation
import Testing
@testable import GuavaUIScene

@Suite("Animation playback and physical motion")
struct PlaybackTests {
    @Test("Finite repetitions count complete forward/reverse cycles", arguments: [false, true])
    func repeats(autoreverses: Bool) {
        var value: Float = -1
        let controller = AnimationController(from: Float(0), to: Float(10),
            animation: Animation(duration: 1, curve: .linear).repeatCount(2, autoreverses: autoreverses)) { value = $0 }
        controller.tick(deltaTime: 0.5); #expect(value == 5)
        controller.tick(deltaTime: 0.5); #expect(value == (autoreverses ? 10 : 0))
        controller.tick(deltaTime: 0.5); #expect(value == 5)
        controller.tick(deltaTime: 10)
        #expect(value == (autoreverses ? 0 : 10) && controller.isFinished)
    }

    @Test("Forever playback preserves delay, handles dropped frames and only stops explicitly")
    func forever() {
        var value = 0.0
        let scheduler = AnimatorScheduler()
        let controller = AnimationController(from: 0.0, to: 10.0,
            animation: Animation(duration: 1, curve: .linear, delay: 0.2).repeatForever(autoreverses: false)) { value = $0 }
        scheduler.register(controller)
        scheduler.tick(deltaTime: 0.2); #expect(value == 0)
        scheduler.tick(deltaTime: 10.75); #expect(abs(value - 7.5) < 0.0001)
        scheduler.tick(deltaTime: 1e14); #expect(value.isFinite && value >= 0 && value <= 10)
        #expect(scheduler.activeCount == 1 && !controller.isFinished)
        controller.finishImmediately(); scheduler.tick(deltaTime: 0)
        #expect(value == 10 && scheduler.activeCount == 0)
    }

    @Test("Invalid ticks are ignored; invalid durations and zero duration repeats snap once")
    func invalidTime() {
        var writes = 0
        let controller = AnimationController(from: Float(0), to: Float(1), animation: .linear) { _ in writes += 1 }
        for delta in [-1.0, .nan, .infinity] { controller.tick(deltaTime: delta) }
        #expect(controller.elapsed == 0 && writes == 0)
        for duration in [0.0, -1, .nan, .infinity] {
            var value = 0.0
            let instant = AnimationController(from: 0.0, to: 0.1,
                animation: Animation(duration: duration).repeatForever()) { value = $0 }
            #expect(instant.isFinished && value == 0.1)
        }
    }

    @Test("Timeline samples plateaus, reversals and exact boundaries independently of cadence")
    func timeline() {
        let timeline = KeyframeTimeline(initialValue: Float(0), keyframes: [
            .init(10, duration: 0.5), .init(10, duration: 0.25), .init(-5, duration: 0.25)
        ])
        for (time, expected): (Double, Float) in [(-1, 0), (0.25, 5), (0.5, 10), (0.7, 10), (0.875, 2.5), (1, -5), (.infinity, -5)] {
            #expect(timeline.value(at: time) == expected)
        }
        #expect(timeline.value(at: .nan) == 0 && timeline.duration == 1)
    }

    @Test("Physical spring velocity matches the derivative and the equilibrium remains the target",
          arguments: [Float(0.4), 1, 3])
    func physicalSpring(damping: Float) {
        let spring = SpringSolution(response: 0.4, dampingFraction: damping)
        let time: Float = 0.12, delta: Float = 0.0001
        let derivative = (spring.position(at: time + delta, from: 3, velocity: -7, to: 12)
            - spring.position(at: time - delta, from: 3, velocity: -7, to: 12)) / (2 * delta)
        #expect(abs(derivative - spring.velocity(at: time, from: 3, velocity: -7, to: 12)) < 0.02)
        #expect(abs(spring.position(at: Float(spring.settlingDuration), from: 3, velocity: -7, to: 12) - 12) < 0.002)
        #expect(AnimationCurve.spring(response: 0.4, dampingFraction: damping).evaluate(1) == 1)
    }

    @Test("Spring parameters and nonfinite time cannot create nonfinite scene geometry")
    func springValidation() {
        for parameter: Float in [0, -1, .nan, .infinity, .greatestFiniteMagnitude] {
            let spring = SpringSolution(response: parameter, dampingFraction: parameter)
            #expect(spring.response >= 0.001 && spring.response <= 30)
            #expect(spring.dampingFraction >= 0.01 && spring.dampingFraction <= 20)
            #expect(spring.position(at: 0.1, from: 0, velocity: 0).isFinite)
            #expect(spring.position(at: .nan, from: 3, velocity: 2) == 3)
            #expect(spring.position(at: .infinity, from: 3, velocity: 2) == 1)
        }
    }

    @Test("Retargeted point motion preserves both components of real value velocity")
    func inheritedVector() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let node = Node()
            let motion = Animation.spring(response: 0.4, dampingFraction: 0.6, allowsOvershoot: true)
            ActiveAnimationContext.with(motion) { node.animatableSet(\.contentOffset, to: CGPoint(x: 100, y: 50)) }
            scheduler.tick(deltaTime: 0.08)
            let before = node.contentOffset
            ActiveAnimationContext.with(motion) { node.animatableSet(\.contentOffset, to: CGPoint(x: -20, y: 140)) }
            #expect(node.contentOffset == before && scheduler.activeCount == 1)
            scheduler.tick(deltaTime: 0.0001)
            let expected = SpringSolution(response: 0.4, dampingFraction: 0.6).velocity(at: 0.08, from: 0, velocity: 0)
            #expect(abs(Float((node.contentOffset.x - before.x) / 0.0001) - expected * 100) < 2)
            #expect(abs(Float((node.contentOffset.y - before.y) / 0.0001) - expected * 50) < 2)
            scheduler.tick(deltaTime: 5)
            #expect(node.contentOffset == CGPoint(x: -20, y: 140) && scheduler.activeCount == 0)
        }
    }

    @Test("Unmount cancels a forever property animation immediately and suppresses its completion")
    func unmount() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let root = Node(), node = Node(); root.addChild(node)
            var completions = 0
            let group = AnimationCompletionGroup(criteria: .removed) { completions += 1 }
            scheduler.track(group)
            ActiveAnimationContext.with(Animation.linear.repeatForever(), completion: group) { node.animatableSet(\.opacity, to: 0) }
            #expect(scheduler.activeCount == 1)
            root.removeChild(node)
            #expect(scheduler.activeCount == 0)
            scheduler.tick(deltaTime: 10)
            #expect(group.hasSettled && completions == 0)
        }
    }

    @Test("Logical spring completion precedes physical removal", arguments: [AnimationCompletionCriteria.logicallyComplete, .removed])
    func completion(criteria: AnimationCompletionCriteria) {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let node = Node()
            var completions = 0
            let group = AnimationCompletionGroup(criteria: criteria) { completions += 1 }
            scheduler.track(group)
            ActiveAnimationContext.with(.spring(response: 0.4, dampingFraction: 0.6), completion: group) {
                node.animatableSet(\.opacity, to: 0)
            }
            scheduler.tick(deltaTime: 0.4)
            #expect(completions == (criteria == .logicallyComplete ? 1 : 0))
            #expect(scheduler.activeCount == 1)
            scheduler.tick(deltaTime: 5)
            #expect(completions == 1 && scheduler.activeCount == 0)
        }
    }

    @Test("Cancelled completion groups release without needing another scheduler tick")
    func completionLifetime() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let root = Node(), node = Node(); root.addChild(node)
            weak var retained: AnimationCompletionGroup?
            do {
                let group = AnimationCompletionGroup(criteria: .removed) { Issue.record("Cancelled scope completed") }
                retained = group; scheduler.track(group)
                ActiveAnimationContext.with(Animation.linear, completion: group) { node.animatableSet(\.opacity, to: 0) }
            }
            #expect(retained != nil)
            root.removeChild(node)
            #expect(retained == nil && scheduler.activeCount == 0)
        }
    }
}
