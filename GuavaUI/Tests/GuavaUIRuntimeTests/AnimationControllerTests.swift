import Testing
import GuavaUIRuntime

@Suite("Phase 8 / AnimationController & Scheduler")
struct AnimationControllerTests {

    // MARK: - Controller

    @Test("Tick at t=0 applies from; at t=duration applies to and finishes")
    func endpoints() {
        var written: Float = -1
        let c = AnimationController(
            from: Float(0),
            to: Float(10),
            animation: Animation(duration: 1.0, curve: .linear),
            apply: { written = $0 }
        )

        c.tick(deltaTime: 0)
        #expect(written == 0)
        #expect(c.isFinished == false)

        c.tick(deltaTime: 1.0)
        #expect(written == 10)
        #expect(c.isFinished == true)
    }

    @Test("Linear interpolation hits the midpoint")
    func midpoint() {
        var written: Float = -1
        let c = AnimationController(
            from: Float(0),
            to: Float(10),
            animation: Animation(duration: 1.0, curve: .linear),
            apply: { written = $0 }
        )
        c.tick(deltaTime: 0.5)
        #expect(written == 5)
        #expect(c.isFinished == false)
    }

    @Test("Delay window pins to the from value")
    func delayWindow() {
        var written: Float = -1
        let c = AnimationController(
            from: Float(0),
            to: Float(10),
            animation: Animation(duration: 1.0, curve: .linear, delay: 0.5),
            apply: { written = $0 }
        )

        c.tick(deltaTime: 0.25)
        #expect(written == 0)
        #expect(c.isFinished == false)

        c.tick(deltaTime: 0.5)   // now at elapsed=0.75 → active=0.25/1.0
        #expect(abs(written - 2.5) < 1e-5)
    }

    @Test("Tick after isFinished is a no-op")
    func tickAfterFinished() {
        var calls = 0
        let c = AnimationController(
            from: Float(0),
            to: Float(10),
            animation: Animation(duration: 0.1, curve: .linear),
            apply: { _ in calls += 1 }
        )
        c.tick(deltaTime: 1.0)   // first tick → finishes
        #expect(c.isFinished == true)
        let before = calls
        c.tick(deltaTime: 1.0)   // additional ticks should not call apply
        #expect(calls == before)
    }

    @Test("Zero-duration animation snaps to target on construction")
    func zeroDuration() {
        var written: Float = -1
        let c = AnimationController(
            from: Float(0),
            to: Float(10),
            animation: Animation(duration: 0, curve: .linear),
            apply: { written = $0 }
        )
        #expect(written == 10)
        #expect(c.isFinished == true)
    }

    @Test("finishImmediately writes target and marks finished")
    func finishImmediately() {
        var written: Float = -1
        let c = AnimationController(
            from: Float(0),
            to: Float(10),
            animation: Animation(duration: 1.0, curve: .linear),
            apply: { written = $0 }
        )
        c.tick(deltaTime: 0.25)
        #expect(written == 2.5)
        c.finishImmediately()
        #expect(written == 10)
        #expect(c.isFinished == true)
    }

    @Test("Eased curve produces non-linear progress at t=0.5")
    func easingShape() {
        var written: Float = -1
        let c = AnimationController(
            from: Float(0),
            to: Float(100),
            animation: Animation(duration: 1.0, curve: .easeIn),
            apply: { written = $0 }
        )
        c.tick(deltaTime: 0.5)
        // easeIn at t=0.5 is 0.25 → value should be 25
        #expect(abs(written - 25) < 1e-3)
    }

    @Test("Color controller interpolates RGBA")
    func colorController() {
        var written = Color(r: 0, g: 0, b: 0, a: 0)
        let c = AnimationController(
            from: Color(r: 0, g: 0, b: 0, a: 0),
            to: Color(r: 1, g: 1, b: 1, a: 1),
            animation: Animation(duration: 1.0, curve: .linear),
            apply: { written = $0 }
        )
        c.tick(deltaTime: 0.5)
        #expect(written.r == 0.5)
        #expect(written.a == 0.5)
    }

    // MARK: - Scheduler

    @Test("Scheduler tracks and ticks every registered controller")
    func schedulerTicks() {
        let s = AnimatorScheduler()
        var v1: Float = -1, v2: Float = -1
        s.register(AnimationController(
            from: Float(0), to: Float(10),
            animation: Animation(duration: 1.0, curve: .linear),
            apply: { v1 = $0 }
        ))
        s.register(AnimationController(
            from: Float(100), to: Float(0),
            animation: Animation(duration: 1.0, curve: .linear),
            apply: { v2 = $0 }
        ))
        #expect(s.activeCount == 2)

        s.tick(deltaTime: 0.5)
        #expect(v1 == 5)
        #expect(v2 == 50)
    }

    @Test("Finished controllers are evicted on subsequent tick")
    func schedulerEvicts() {
        let s = AnimatorScheduler()
        s.register(AnimationController(
            from: Float(0), to: Float(10),
            animation: Animation(duration: 0.1, curve: .linear),
            apply: { _ in }
        ))
        #expect(s.activeCount == 1)

        s.tick(deltaTime: 1.0)   // finishes during this tick
        // Eviction happens at the end of the same tick.
        #expect(s.activeCount == 0)
    }

    @Test("Empty scheduler tick is a no-op")
    func emptyTick() {
        let s = AnimatorScheduler()
        s.tick(deltaTime: 0.016)
        #expect(s.activeCount == 0)
    }

    @Test("reset drops every active controller")
    func reset() {
        let s = AnimatorScheduler()
        s.register(AnimationController(
            from: Float(0), to: Float(1),
            animation: Animation(duration: 1.0, curve: .linear),
            apply: { _ in }
        ))
        s.reset()
        #expect(s.activeCount == 0)
    }
}
