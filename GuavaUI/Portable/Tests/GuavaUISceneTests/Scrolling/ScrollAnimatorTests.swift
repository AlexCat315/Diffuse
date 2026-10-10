#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
import GuavaUIScene

/// Tests that let a glide or spring run do so on their own scheduler: tests in
/// a suite run in parallel, and `AnimatorScheduler.shared` is not safe to tick
/// from several of them at once.
private func withIsolatedScheduler<Value>(_ body: () throws -> Value) rethrows -> Value {
    let scheduler = AnimatorScheduler()
    return try AnimatorScheduler.$current.withValue(scheduler, operation: body)
}

private func tick(frames: Int = 240, duration: Double = 1.0 / 60.0) {
    for _ in 0..<frames { AnimatorScheduler.current.tick(deltaTime: duration) }
}

/// Drives time by hand. Real time would make these tests race, and both the
/// idle window and the glide are defined in elapsed seconds.
private final class ManualClock {
    var now: TimeInterval = 0

    func run(frames: Int, interval: TimeInterval = 1.0 / 60.0) {
        for _ in 0..<frames {
            now += interval
            AnimatorScheduler.current.tick(deltaTime: interval)
        }
    }
}

@Suite struct ScrollAnimatorTests {

    private func makeAnimator(physics: ScrollPhysics = .default,
                              maximum: CGFloat = 100,
                              viewportHeight: CGFloat = 100) -> ScrollAnimator {
        ScrollAnimator(
            physics: physics,
            maximumOffset: CGPoint(x: 0, y: maximum),
            viewportSize: CGSize(width: 200, height: viewportHeight)
        )
    }

    /// An animator bound to a hand-driven clock, with room to coast.
    private func makeCoastingAnimator(clock: ManualClock,
                                      physics: ScrollPhysics = .default,
                                      maximum: CGFloat = 1_000) -> ScrollAnimator {
        let animator = makeAnimator(physics: physics,
                                    maximum: maximum,
                                    viewportHeight: 100)
        animator.clock = { clock.now }
        return animator
    }

    /// Deliver `count` wheel samples `step` points apart, one frame apart —
    /// the shape a trackpad flick has, and what a fast burst of mouse notches
    /// approximates.
    private func wheel(_ animator: ScrollAnimator,
                       _ clock: ManualClock,
                       samples: Int,
                       step: CGFloat = 8) {
        for _ in 0..<samples {
            clock.now += 1.0 / 60.0
            animator.scroll(by: CGPoint(x: 0, y: step))
        }
    }

    // MARK: - Rubber band

    @Test("Movement inside the range is passed through untouched")
    func insideRangeIsUnchanged() {
        withIsolatedScheduler {
            let animator = makeAnimator()
            #expect(animator.scroll(by: CGPoint(x: 0, y: 40)).y == 40)
            #expect(animator.scroll(by: CGPoint(x: 0, y: 40)).y == 80)
            #expect(!animator.isSettling)
        }
    }

    @Test("Pushing past the end moves further, but less than the input")
    func pastTheEndCompresses() {
        withIsolatedScheduler {
            let animator = makeAnimator()
            _ = animator.scroll(by: CGPoint(x: 0, y: 100))
            let visible = animator.scroll(by: CGPoint(x: 0, y: 30)).y
            #expect(visible > 100)
            #expect(visible < 130)
            #expect(visible < 100 + 100) // never more than one viewport past the end
        }
    }

    @Test("The leading bound stretches downwards too")
    func pastTheStartCompresses() {
        withIsolatedScheduler {
            let animator = makeAnimator()
            let visible = animator.scroll(by: CGPoint(x: 0, y: -30)).y
            #expect(visible < 0)
            #expect(visible > -30)
        }
    }

    @Test("Input that stops leaves the offset springing back to the bound")
    func springsBackAfterInput() {
        withIsolatedScheduler {
            let animator = makeAnimator()
            _ = animator.scroll(by: CGPoint(x: 0, y: 140))
            #expect(animator.offset.y > 100)
            #expect(animator.isSettling)
            tick()
            #expect(animator.offset.y == 100)
            #expect(!animator.isSettling)
            #expect(animator.isFinished)
        }
    }

    @Test("A range that shrinks snaps in place instead of animating")
    func shrinkingRangeSnaps() {
        withIsolatedScheduler {
            let animator = makeAnimator()
            _ = animator.scroll(by: CGPoint(x: 0, y: 140))
            animator.update(maximumOffset: CGPoint(x: 0, y: 20),
                            viewportSize: CGSize(width: 200, height: 100))
            #expect(animator.offset.y == 20)
            #expect(!animator.isSettling)
        }
    }

    @Test("Growth does not interrupt an in-flight stretch")
    func growingRangeKeepsStretching() {
        withIsolatedScheduler {
            let animator = makeAnimator()
            _ = animator.scroll(by: CGPoint(x: 0, y: 140))
            let stretched = animator.offset.y
            animator.update(maximumOffset: CGPoint(x: 0, y: 160),
                            viewportSize: CGSize(width: 200, height: 100))
            #expect(animator.offset.y == stretched)
            #expect(animator.isSettling)
        }
    }

    @Test("New input during the return spring moves continuously")
    func inputDuringSettleHasNoJump() {
        withIsolatedScheduler {
            let animator = makeAnimator()
            _ = animator.scroll(by: CGPoint(x: 0, y: 140))
            tick(frames: 3)
            let recovered = animator.offset.y
            #expect(recovered < 140)
            let after = animator.scroll(by: CGPoint(x: 0, y: 1)).y

            // Without folding the recovered travel back through the inverse
            // curve the visible offset would snap straight back out to ~118.
            #expect(after > recovered)
            #expect(after - recovered < 1)
        }
    }

    @Test("An authoritative write wins over the return spring")
    func adoptCancelsSettling() {
        withIsolatedScheduler {
            let animator = makeAnimator()
            _ = animator.scroll(by: CGPoint(x: 0, y: 140))
            animator.adopt(CGPoint(x: 0, y: 10))
            #expect(animator.offset.y == 10)
            #expect(!animator.isSettling)
            tick()
            #expect(animator.offset.y == 10)
        }
    }

    @Test("Each axis is independent")
    func perAxisIndependence() {
        withIsolatedScheduler {
            let animator = ScrollAnimator(
                physics: .default,
                maximumOffset: CGPoint(x: 50, y: 50),
                viewportSize: CGSize(width: 60, height: 60)
            )
            _ = animator.scroll(by: CGPoint(x: 80, y: 10))
            #expect(animator.offset.x > 50)
            #expect(animator.offset.y == 10)
            tick()
            #expect(animator.offset.x == 50)
            #expect(animator.offset.y == 10)
        }
    }

    @Test("Clamped physics restores hard boundaries")
    func clampedPhysics() {
        withIsolatedScheduler {
            let animator = makeAnimator(physics: .clamped)
            #expect(animator.scroll(by: CGPoint(x: 0, y: 140)).y == 100)
            #expect(!animator.isSettling)
            #expect(animator.scroll(by: CGPoint(x: 0, y: -140)).y == 0)
            tick()
            #expect(animator.offset.y == 0)
        }
    }

    @Test("Bouncy physics overshoots the bound on the way back")
    func bouncyPhysics() {
        withIsolatedScheduler {
            let animator = makeAnimator(physics: .bouncy)
            _ = animator.scroll(by: CGPoint(x: 0, y: 140))
            var dippedBelowBound = false
            for _ in 0..<240 {
                AnimatorScheduler.current.tick(deltaTime: 1.0 / 60.0)
                if animator.offset.y < 99.5 { dippedBelowBound = true }
            }
            #expect(dippedBelowBound)
            #expect(animator.offset.y == 100)
        }
    }

    @Test("A drag past the end holds until the gesture ends")
    func dragThenRelease() {
        withIsolatedScheduler {
            let animator = makeAnimator()
            _ = animator.move(to: CGPoint(x: 0, y: 160))
            #expect(animator.offset.y > 100)
            #expect(!animator.isSettling)
            _ = animator.move(to: CGPoint(x: 0, y: 200))
            #expect(animator.offset.y > 100)

            animator.settle()
            #expect(animator.isSettling)
            tick()
            #expect(animator.offset.y == 100)
        }
    }

    @Test("Finishing immediately lands on the bound")
    func finishImmediately() {
        withIsolatedScheduler {
            let animator = makeAnimator()
            _ = animator.scroll(by: CGPoint(x: 0, y: 140))
            animator.finishImmediately()
            #expect(animator.offset.y == 100)
            #expect(animator.isFinished)
        }
    }

    // MARK: - Momentum

    @Test("A burst of wheel input keeps coasting once it stops")
    func wheelBurstCoasts() {
        withIsolatedScheduler {
            let clock = ManualClock()
            let animator = makeCoastingAnimator(clock: clock)
            wheel(animator, clock, samples: 10)
            let delivered = animator.offset.y
            #expect(delivered == 80)

            // One frame later nothing has moved: the last notch may yet be
            // followed by another.
            clock.run(frames: 1)
            #expect(animator.offset.y == delivered)
            #expect(!animator.isGliding)

            clock.run(frames: 400)
            #expect(animator.offset.y > delivered + 60)
            // (v - minimumVelocity) / deceleration: how far 480 pt/s travels
            // before it dies. A flick carries content on, it does not launch it.
            #expect(animator.offset.y < delivered + 130)
            #expect(animator.isFinished)
            #expect(animator.velocity == .zero)
        }
    }

    @Test("One or two notches are a nudge, not a throw")
    func nudgesDoNotCoast() {
        withIsolatedScheduler {
            let clock = ManualClock()
            let animator = makeCoastingAnimator(clock: clock)
            wheel(animator, clock, samples: 2, step: 30)

            clock.run(frames: 400)
            #expect(animator.offset.y == 60)
            #expect(animator.isFinished)
        }
    }

    @Test("Deliberate slow notches rest where they land")
    func slowNotchesDoNotCoast() {
        withIsolatedScheduler {
            let clock = ManualClock()
            let animator = makeCoastingAnimator(clock: clock)

            clock.now += 0.25
            _ = animator.scroll(by: CGPoint(x: 0, y: 30))
            clock.now += 0.25
            _ = animator.scroll(by: CGPoint(x: 0, y: 30))

            clock.run(frames: 400)
            #expect(animator.offset.y == 60)
            #expect(animator.isFinished)
        }
    }

    @Test("A notch while coasting brakes and does not relaunch")
    func notchDuringGlideBrakes() {
        withIsolatedScheduler {
            let clock = ManualClock()
            let animator = makeCoastingAnimator(clock: clock)
            wheel(animator, clock, samples: 10)

            // Well past the quiet window: the glide is under way.
            clock.run(frames: 30)
            #expect(animator.isGliding)

            clock.now += 1.0 / 60.0
            let braked = animator.scroll(by: CGPoint(x: 0, y: 30)).y
            #expect(!animator.isGliding)

            // The brake has to hold: relaunching from the samples behind the
            // glide is what made stopping impossible.
            clock.run(frames: 400)
            #expect(animator.offset.y == braked)
            #expect(animator.isFinished)
        }
    }

    @Test("Stopping a glide leaves the offset where it was")
    func stopCoastingHoldsPosition() {
        withIsolatedScheduler {
            let clock = ManualClock()
            let animator = makeCoastingAnimator(clock: clock)
            wheel(animator, clock, samples: 10)

            clock.run(frames: 20)
            #expect(animator.isGliding)
            let caught = animator.offset.y

            animator.stopCoasting()
            #expect(!animator.isGliding)
            clock.run(frames: 200)
            #expect(animator.offset.y == caught)
        }
    }

    @Test("How far a flick travels does not depend on the frame rate")
    func glideIsFrameRateIndependent() {
        let atThirty = coastDistance(frameInterval: 1.0 / 30.0)
        let atTwoForty = coastDistance(frameInterval: 1.0 / 240.0)
        #expect(abs(atThirty - atTwoForty) < 2)
    }

    private func coastDistance(frameInterval: TimeInterval) -> CGFloat {
        withIsolatedScheduler {
            let clock = ManualClock()
            let animator = makeCoastingAnimator(clock: clock)
            wheel(animator, clock, samples: 10)
            let delivered = animator.offset.y
            clock.run(frames: Int(6.0 / frameInterval), interval: frameInterval)
            return animator.offset.y - delivered
        }
    }

    @Test("Coasting into the end of the range bounces instead of stopping")
    func glideIntoTheBoundBounces() {
        withIsolatedScheduler {
            let clock = ManualClock()
            let animator = makeCoastingAnimator(clock: clock, maximum: 200)
            wheel(animator, clock, samples: 10, step: 10)

            var furthest: CGFloat = 0
            for _ in 0..<600 {
                clock.run(frames: 1)
                furthest = max(furthest, animator.offset.y)
            }

            #expect(furthest > 200)
            // However hard it was thrown, never further than one viewport.
            #expect(furthest < 200 + 100)
            #expect(animator.offset.y == 200)
            #expect(animator.isFinished)
        }
    }

    @Test("Clamped physics stops dead at the edge with nothing left over")
    func clampedGlideStopsAtTheEdge() {
        withIsolatedScheduler {
            let clock = ManualClock()
            let animator = makeCoastingAnimator(clock: clock,
                                                physics: .clamped,
                                                maximum: 200)
            wheel(animator, clock, samples: 10, step: 10)

            for _ in 0..<600 { clock.run(frames: 1) }
            #expect(animator.offset.y == 200)
            #expect(animator.position.y == 200)
            #expect(animator.isFinished)
        }
    }

    @Test(".precise lands every notch and nothing else")
    func preciseDoesNotCoast() {
        withIsolatedScheduler {
            let clock = ManualClock()
            let animator = makeCoastingAnimator(clock: clock, physics: .precise)
            wheel(animator, clock, samples: 10)

            clock.run(frames: 400)
            #expect(animator.offset.y == 80)
            #expect(animator.isFinished)
        }
    }

    @Test("Letting go of a moving thumb keeps the content moving")
    func dragReleaseFlicks() {
        withIsolatedScheduler {
            let clock = ManualClock()
            let animator = makeCoastingAnimator(clock: clock)
            for index in 1...8 {
                clock.now += 1.0 / 60.0
                _ = animator.move(to: CGPoint(x: 0, y: CGFloat(index) * 12))
            }
            let released = animator.offset.y
            #expect(released == 96)

            animator.settle()
            #expect(animator.isGliding)
            clock.run(frames: 400)
            #expect(animator.offset.y > released + 100)
            #expect(animator.isFinished)
        }
    }

    @Test("Holding still before letting go does not fling")
    func dragReleaseWithoutMotionDoesNotFling() {
        withIsolatedScheduler {
            let clock = ManualClock()
            let animator = makeCoastingAnimator(clock: clock)
            for index in 1...8 {
                clock.now += 1.0 / 60.0
                _ = animator.move(to: CGPoint(x: 0, y: CGFloat(index) * 12))
            }
            // The pointer stops moving, then the button comes up.
            clock.run(frames: 30)
            animator.settle()
            #expect(!animator.isGliding)
            #expect(animator.offset.y == 96)
        }
    }

    @Test("An authoritative write during a glide stops it where it is")
    func adoptStopsTheGlide() {
        withIsolatedScheduler {
            let clock = ManualClock()
            let animator = makeCoastingAnimator(clock: clock)
            wheel(animator, clock, samples: 10)

            clock.run(frames: 20)
            #expect(animator.isGliding)
            let midFlight = animator.offset.y
            #expect(midFlight > 80)

            animator.adopt(.zero)
            #expect(!animator.isGliding)
            clock.run(frames: 200)
            #expect(animator.offset.y == 0)
        }
    }

    @Test("A flick into either bound never escapes the rubber band")
    func flingStaysWithinRubberBandRange() {
        withIsolatedScheduler {
            let clock = ManualClock()
            let animator = makeCoastingAnimator(clock: clock, maximum: 40)
            wheel(animator, clock, samples: 20, step: 40)

            for _ in 0..<600 {
                clock.run(frames: 1)
                #expect(animator.offset.y <= 40 + 100)
                #expect(animator.offset.y >= -100)
            }
            #expect(animator.offset.y == 40)
        }
    }

    @Test("Launch velocity is clamped so a burst cannot fling far")
    func launchVelocityIsClamped() {
        withIsolatedScheduler {
            let clock = ManualClock()
            let animator = makeCoastingAnimator(clock: clock, maximum: 100_000)
            // Samples a thousandth of a second apart, 10 points apart: a slope
            // no human hand produced, and exactly what a burst of wheel
            // notches arriving in the same millisecond looks like.
            for _ in 0..<4 {
                clock.now += 0.001
                _ = animator.scroll(by: CGPoint(x: 0, y: 10))
            }

            let velocity = animator.currentVelocity()
            #expect(abs(velocity.y - 1_100) < 1)

            // And so the whole throw stays within a fraction of a viewport,
            // rather than the several thousand points the raw slope would
            // have travelled.
            let delivered = animator.offset.y
            clock.run(frames: 600)
            #expect(animator.offset.y - delivered < 300)
        }
    }
}
