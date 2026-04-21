import Testing
import GuavaUIRuntime

@Suite("Phase 8 / Animation value type")
struct AnimationValueTests {

    // MARK: - Curve evaluation

    @Test("linear maps t directly to progress")
    func linear() {
        let c = AnimationCurve.linear
        #expect(c.evaluate(0.0) == 0)
        #expect(c.evaluate(0.25) == 0.25)
        #expect(c.evaluate(0.5) == 0.5)
        #expect(c.evaluate(0.75) == 0.75)
        #expect(c.evaluate(1.0) == 1)
    }

    @Test("easeIn at t=0.5 is 0.25 (quadratic)")
    func easeIn() {
        let c = AnimationCurve.easeIn
        #expect(c.evaluate(0) == 0)
        #expect(c.evaluate(0.5) == 0.25)
        #expect(c.evaluate(1) == 1)
    }

    @Test("easeOut is the mirror of easeIn around y=x")
    func easeOut() {
        let c = AnimationCurve.easeOut
        #expect(c.evaluate(0) == 0)
        #expect(abs(c.evaluate(0.5) - 0.75) < 1e-5)
        #expect(c.evaluate(1) == 1)
    }

    @Test("easeInOut is symmetric around (0.5, 0.5)")
    func easeInOutSymmetric() {
        let c = AnimationCurve.easeInOut
        for raw in stride(from: Float(0.0), through: Float(0.5), by: 0.05) {
            let p1 = c.evaluate(raw)
            let p2 = c.evaluate(1 - raw)
            #expect(abs((p1 + p2) - 1) < 1e-5)
        }
    }

    @Test("Inputs outside [0,1] are clamped")
    func curveClamps() {
        let c = AnimationCurve.easeInOut
        #expect(c.evaluate(-1) == c.evaluate(0))
        #expect(c.evaluate(2) == c.evaluate(1))
    }

    @Test("cubicBezier(0,0,1,1) reproduces linear within tolerance")
    func cubicLinear() {
        let c = AnimationCurve.cubicBezier(0, 0, 1, 1)
        for raw in stride(from: Float(0.0), through: Float(1.0), by: 0.1) {
            #expect(abs(c.evaluate(raw) - raw) < 1e-3)
        }
    }

    @Test("cubicBezier endpoints anchor at (0,0) and (1,1)")
    func cubicEndpoints() {
        let c = AnimationCurve.cubicBezier(0.42, 0, 0.58, 1)   // ease-in-out
        #expect(abs(c.evaluate(0)) < 1e-4)
        #expect(abs(c.evaluate(1) - 1) < 1e-4)
    }

    @Test("cubicBezier monotonically increases for canonical easing curves")
    func cubicMonotone() {
        let c = AnimationCurve.cubicBezier(0.25, 0.1, 0.25, 1)  // ease
        var last: Float = -1
        for raw in stride(from: Float(0.0), through: Float(1.0), by: 0.05) {
            let p = c.evaluate(raw)
            #expect(p >= last)
            last = p
        }
    }

    // MARK: - Animation value

    @Test("Animation defaults are sensible")
    func defaults() {
        #expect(Animation.default.duration == 0.25)
        #expect(Animation.default.curve == .easeInOut)
        #expect(Animation.default.delay == 0)

        #expect(Animation.linear.curve == .linear)
        #expect(Animation.easeIn.curve == .easeIn)
        #expect(Animation.easeOut.curve == .easeOut)
    }

    @Test("Animation is value-equatable")
    func equatable() {
        let a = Animation(duration: 0.3, curve: .easeIn, delay: 0.1)
        let b = Animation(duration: 0.3, curve: .easeIn, delay: 0.1)
        let c = Animation(duration: 0.3, curve: .easeIn, delay: 0.2)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("easeInOut(duration:) preserves curve and zeroes delay")
    func easeInOutFactory() {
        let a = Animation.easeInOut(duration: 0.5)
        #expect(a.duration == 0.5)
        #expect(a.curve == .easeInOut)
        #expect(a.delay == 0)
    }
}
