#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
import GuavaUIScene

/// Tests that let the return spring run do so on their own scheduler: tests in
/// a suite run in parallel, and `AnimatorScheduler.shared` is not safe to tick
/// from several of them at once.
private func withIsolatedScheduler<Value>(_ body: () throws -> Value) rethrows -> Value {
    let scheduler = AnimatorScheduler()
    return try AnimatorScheduler.$current.withValue(scheduler, operation: body)
}

private func tick(frames: Int = 240, duration: Double = 1.0 / 60.0) {
    for _ in 0..<frames { AnimatorScheduler.current.tick(deltaTime: duration) }
}

@Suite struct ScrollRubberBandAnimatorTests {

    private func makeAnimator(physics: ScrollPhysics = .default,
                              maximum: CGFloat = 100,
                              viewportHeight: CGFloat = 100) -> ScrollRubberBandAnimator {
        ScrollRubberBandAnimator(
            physics: physics,
            maximumOffset: CGPoint(x: 0, y: maximum),
            viewportSize: CGSize(width: 200, height: viewportHeight)
        )
    }

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
            let animator = ScrollRubberBandAnimator(
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
}
