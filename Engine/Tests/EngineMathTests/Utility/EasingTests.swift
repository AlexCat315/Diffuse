import EngineMath
import Testing
import SIMDCompat

@Suite("Easing")
struct EasingTests {

    @Test("linear maps t to itself", arguments: [
        (0.0 as Float, 0.0 as Float),
        (0.25, 0.25), (0.5, 0.5), (0.75, 0.75), (1.0, 1.0),
    ])
    func linearEasing(t: Float, expected: Float) {
        #expect(Easing.linear.evaluate(t) == expected)
    }

    @Test("evaluate clamps input to [0,1]")
    func evaluateClampsInput() {
        #expect(Easing.linear.evaluate(-0.5) == 0)
        #expect(Easing.linear.evaluate(1.5) == 1)
    }

    @Test("ease at 0 is always 0")
    func easeAtZero() {
        let all = allEasings()
        for e in all {
            #expect(e.evaluate(0) == 0, "\(e) at t=0 should be 0")
        }
    }

    @Test("ease at 1 is always 1")
    func easeAtOne() {
        let all = allEasings()
        for e in all {
            #expect(e.evaluate(1) == 1, "\(e) at t=1 should be 1")
        }
    }

    @Test("easeOut inverts easeIn at t=0.5")
    func easeOutInvertsEaseIn() {
        let pairs: [(Easing, Easing)] = [
            (.easeInQuad, .easeOutQuad),
            (.easeInCubic, .easeOutCubic),
            (.easeInQuart, .easeOutQuart),
            (.easeInSine, .easeOutSine),
            (.easeInExpo, .easeOutExpo),
            (.easeInCirc, .easeOutCirc),
        ]
        for (easeIn, easeOut) in pairs {
            let v = easeIn.evaluate(0.3)
            let inv = 1 - easeOut.evaluate(1 - 0.3)
            #expect(abs(v - inv) < 0.001, "\(easeIn) vs \(easeOut)")
        }
    }

    @Test("interpolate scalar spans range")
    func interpolateScalar() {
        #expect(Easing.linear.interpolate(from: 0, to: 10, t: 0.5) == 5)
        #expect(Easing.linear.interpolate(from: 10, to: 0, t: 0.25) == 7.5)
    }

    @Test("interpolate SIMD3 spans range")
    func interpolateSIMD3() {
        let from = SIMD3<Float>(0, 0, 0)
        let to = SIMD3<Float>(4, 8, 12)
        let result = Easing.linear.interpolate(from: from, to: to, t: 0.5)
        #expect(result == SIMD3<Float>(2, 4, 6))
    }

    private func allEasings() -> [Easing] {
        [
            .linear,
            .easeInQuad, .easeOutQuad, .easeInOutQuad,
            .easeInCubic, .easeOutCubic, .easeInOutCubic,
            .easeInQuart, .easeOutQuart, .easeInOutQuart,
            .easeInQuint, .easeOutQuint, .easeInOutQuint,
            .easeInSine, .easeOutSine, .easeInOutSine,
            .easeInExpo, .easeOutExpo, .easeInOutExpo,
            .easeInCirc, .easeOutCirc, .easeInOutCirc,
            .easeInElastic, .easeOutElastic, .easeInOutElastic,
            .easeInBack, .easeOutBack, .easeInOutBack,
            .easeInBounce, .easeOutBounce, .easeInOutBounce,
        ]
    }
}
