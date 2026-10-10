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

    @Test("A single large frame is split and lands the same as 60 small ones")
    func largeFramesAreSubstepped() {
        var coarse = ScrollSpring(value: 100, target: 0, settings: ScrollSettleSettings())
        var fine = ScrollSpring(value: 100, target: 0, settings: ScrollSettleSettings())
        coarse.advance(deltaTime: 0.25)
        for _ in 0..<15 { fine.advance(deltaTime: 0.25 / 15) }
        #expect(abs(coarse.value - fine.value) < 2)
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
}
