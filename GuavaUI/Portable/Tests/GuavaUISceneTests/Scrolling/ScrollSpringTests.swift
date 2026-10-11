import Testing
import GuavaUIScene

@Suite struct ScrollSpringTests {

    @Test("A critically damped spring arrives without crossing its target")
    func criticalDampingDoesNotOvershoot() {
        var spring = ScrollSpring(value: 80, target: 0,
                                  settings: ScrollSettleSettings(dampingFraction: 1))
        for _ in 0..<240 {
            spring.advance(deltaTime: 1.0 / 60.0)
            #expect(spring.value >= -0.001)
        }
        #expect(spring.value == 0)
        #expect(spring.isAtRest)
    }

    @Test("An underdamped spring crosses the bound before settling")
    func underdampedOvershoots() {
        var spring = ScrollSpring(value: 80, target: 0,
                                  settings: ScrollSettleSettings(dampingFraction: 0.45))
        var crossed = false
        for _ in 0..<600 {
            spring.advance(deltaTime: 1.0 / 60.0)
            if spring.value < -0.5 { crossed = true }
        }
        #expect(crossed)
        #expect(spring.value == 0)
    }

    @Test("Both directions converge on the same rest state")
    func negativeDisplacement() {
        var spring = ScrollSpring(value: -30, target: -100,
                                  settings: ScrollSettleSettings())
        for _ in 0..<240 { spring.advance(deltaTime: 1.0 / 60.0) }
        #expect(spring.value == -100)
    }

    @Test("A large frame follows the same trajectory as many small frames")
    func largeFramesAreAnalytic() {
        var coarse = ScrollSpring(value: 100, target: 0, settings: ScrollSettleSettings())
        var fine = ScrollSpring(value: 100, target: 0, settings: ScrollSettleSettings())
        coarse.advance(deltaTime: 0.25)
        for _ in 0..<15 { fine.advance(deltaTime: 0.25 / 15) }
        #expect(abs(coarse.value - fine.value) < 0.0001)
        #expect(coarse.value < 100)
        #expect(coarse.value >= 0)
    }

    @Test("Starting velocity is carried into the first frames")
    func velocityIsRespected() {
        var away = ScrollSpring(value: 0, velocity: 400, target: 100,
                                settings: ScrollSettleSettings())
        away.advance(deltaTime: 1.0 / 60.0)
        #expect(away.value > 4)

        var still = ScrollSpring(value: 0, target: 100, settings: ScrollSettleSettings())
        still.advance(deltaTime: 1.0 / 60.0)
        #expect(still.value < away.value)
    }

    @Test("Rest detection snaps to the target and clears velocity")
    func restDetection() {
        var spring = ScrollSpring(value: 0.02, velocity: 0.2, target: 0,
                                  settings: ScrollSettleSettings())
        #expect(spring.isAtRest)
        spring.advance(deltaTime: 1.0 / 60.0)
        #expect(spring.value == 0)
        #expect(spring.velocity == 0)
    }
    @Test("Zero, negative and nonfinite frame durations leave the spring unchanged")
    func invalidTimeDoesNotSnap() {
        for time: Float in [0, -1, .nan, .infinity] {
            var spring = ScrollSpring(value: 80, velocity: 120, target: 0)
            let before = spring
            spring.advance(deltaTime: time)
            #expect(spring == before)
        }
    }

    @Test("All damping regimes follow the same path across uneven frames", arguments: [Float(0.5), 1, 1.8])
    func unevenFramePartition(ratio: Float) {
        let settings = ScrollSettleSettings(dampingFraction: ratio)
        var coarse = ScrollSpring(value: 80, velocity: 420, target: 0, settings: settings)
        var uneven = coarse
        coarse.advance(deltaTime: 0.3)
        for dt: Float in [0.005, 0.045, 0.1, 0.002, 0.148] { uneven.advance(deltaTime: dt) }
        #expect(abs(coarse.value - uneven.value) < 0.0001)
        #expect(abs(coarse.velocity - uneven.velocity) < 0.001)
    }

}
