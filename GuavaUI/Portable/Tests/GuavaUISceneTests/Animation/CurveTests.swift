import Testing
import GuavaUIScene

@Suite("Timing curve shapes and scheduling")
struct AnimationCurveTests {
    private static let points = LinearTimingCurve([
        .init(time: 0, progress: 0), .init(time: 0.25, progress: 0.5),
        .init(time: 0.5, progress: 0.5), .init(time: 0.75, progress: 1.25), .init(time: 1, progress: 1)
    ])
    private static let curves: [AnimationCurve] = [
        .steps(5), .steps(5, position: .start), .piecewiseLinear(points), .bounceOut, .elasticOut
    ]

    @Test("All added curves clamp time, tolerate nonfinite time and end exactly at one", arguments: curves)
    func endpoints(curve: AnimationCurve) {
        #expect(curve.evaluate(-1) == curve.evaluate(0))
        #expect(curve.evaluate(-.infinity) == curve.evaluate(0))
        #expect(curve.evaluate(.nan) == curve.evaluate(0))
        #expect(curve.evaluate(1) == 1 && curve.evaluate(2) == 1 && curve.evaluate(.infinity) == 1)
        #expect(curve.evaluate(0).isFinite)
    }

    @Test("Steps jump on the specified interval edge and remain monotone", arguments: [1, 2, 5, 10])
    func stepEdges(count: Int) {
        let end = AnimationCurve.steps(count), start = AnimationCurve.steps(count, position: .start)
        #expect(end.evaluate(0) == 0 && start.evaluate(0) == 1 / Float(count))
        for index in 1..<count {
            let boundary = Float(index) / Float(count)
            #expect(end.evaluate(boundary) == Float(index) / Float(count))
            #expect(end.evaluate(boundary.nextDown) == Float(index - 1) / Float(count))
            #expect(start.evaluate(boundary) == Float(index + 1) / Float(count))
            #expect(start.evaluate(boundary.nextDown) == Float(index) / Float(count))
        }
        for curve in [start, end] {
            var previous: Float = 0
            for sample in 0...1_000 {
                let progress = curve.evaluate(Float(sample) / 1_000)
                #expect(progress >= previous && progress <= 1)
                previous = progress
            }
        }
        #expect(end.evaluate(Float(1).nextDown) == Float(count - 1) / Float(count))
    }

    @Test("Invalid step counts resolve to one step; very large counts remain finite")
    func stepCounts() {
        for count in [0, -1, Int.min] {
            #expect(AnimationCurve.steps(count).evaluate(0.5) == 0)
            #expect(AnimationCurve.steps(count, position: .start).evaluate(0) == 1)
        }
        for time: Float in [0, 0.1, 0.5, 0.9, 1] {
            #expect(AnimationCurve.steps(Int.max).evaluate(time).isFinite)
            #expect(AnimationCurve.steps(Int.max, position: .start).evaluate(time) <= 1)
        }
    }

    @Test("Linear points interpolate each segment, including plateaus, reversal and overshoot")
    func linearSegments() {
        let curve = AnimationCurve.piecewiseLinear(Self.points)
        for (time, expected): (Float, Float) in [
            (0, 0), (0.125, 0.25), (0.25, 0.5), (0.375, 0.5), (0.5, 0.5),
            (0.625, 0.875), (0.75, 1.25), (0.875, 1.125), (1, 1)
        ] { #expect(curve.evaluate(time) == expected) }
        let linear = AnimationCurve.piecewiseLinear(LinearTimingCurve([
            .init(time: 0, progress: 0), .init(time: 1, progress: 1)
        ]))
        for sample in 0...1_000 {
            let time = Float(sample) / 1_000
            #expect(linear.evaluate(time) == time)
        }
    }

    @Test("Large point lists retain value semantics and finite interpolation between extreme progress values")
    func linearValues() {
        var points = (0...1_000).map { index in
            let time = Float(index) / 1_000
            return LinearTimingCurve.Point(time: time, progress: time * time)
        }
        let value = LinearTimingCurve(points), curve = AnimationCurve.piecewiseLinear(value)
        #expect(value == LinearTimingCurve(points))
        points[500] = .init(time: 0.5, progress: 1)
        #expect(curve.evaluate(0.5) == 0.25 && value != LinearTimingCurve(points))
        for sample in 0...2_000 {
            let time = Float(sample) / 2_000
            #expect(abs(curve.evaluate(time) - time * time) < 0.000001)
        }
        let extremes = AnimationCurve.piecewiseLinear(LinearTimingCurve([
            .init(time: 0, progress: 0), .init(time: 0.25, progress: .greatestFiniteMagnitude),
            .init(time: 0.5, progress: -.greatestFiniteMagnitude), .init(time: 1, progress: 1)
        ]))
        #expect(extremes.evaluate(0.375) == 0)
        #expect(extremes.evaluate(0.3125) == Float.greatestFiniteMagnitude / 2)
    }

    @Test("Bounce is continuous at impacts and has diminishing bounded valleys")
    func bounceShape() {
        let curve = AnimationCurve.bounceOut
        for impact: Float in [1 / 2.75, 2 / 2.75, 2.5 / 2.75] {
            #expect(abs(curve.evaluate(impact) - 1) < 0.000001)
            #expect(abs(curve.evaluate(impact - 0.000001) - curve.evaluate(impact + 0.000001)) < 0.00002)
        }
        for (time, expected): (Float, Float) in [(1.5 / 2.75, 0.75), (2.25 / 2.75, 0.9375), (2.625 / 2.75, 0.984375)] {
            #expect(abs(curve.evaluate(time) - expected) < 0.000001)
        }
        #expect(curve.evaluate(0) == 0)
        for sample in 0...5_000 {
            let progress = curve.evaluate(Float(sample) / 5_000)
            #expect(progress >= 0 && progress <= 1)
        }
    }

    @Test("Elastic preserves overshoot while oscillations decay toward the exact endpoint")
    func elasticShape() {
        let curve = AnimationCurve.elasticOut
        #expect(curve.evaluate(0) == 0 && curve.evaluate(1) == 1)
        for (time, expected): (Float, Float) in [(0.2, 1.25), (0.4, 0.9375), (0.6, 1.015625), (0.8, 0.99609375)] {
            #expect(abs(curve.evaluate(time) - expected) < 0.000001)
        }
        #expect(curve.evaluate(0.2) > 1 && curve.evaluate(0.4) < 1)
        for sample in 0...1_000 { #expect(curve.evaluate(Float(sample) / 1_000).isFinite) }
    }

    @Test("New curves preserve delay, overshooting numeric values, exact finish and scheduler cleanup", arguments: curves)
    func controllers(curve: AnimationCurve) {
        var value: Float = 80, writes = 0
        let controller = AnimationController(from: Float(80), to: Float(200),
            animation: Animation(duration: 1, curve: curve, delay: 0.1)) { value = $0; writes += 1 }
        let scheduler = AnimatorScheduler()
        scheduler.register(controller)
        scheduler.tick(deltaTime: 0.1)
        #expect(value == 80 && !controller.isFinished)
        scheduler.tick(deltaTime: 0.2)
        #expect(abs(value - (80 + 120 * curve.evaluate(0.2))) < 0.0001)
        if curve == .elasticOut { #expect(value > 200) }
        scheduler.tick(deltaTime: 1)
        #expect(value == 200 && controller.isFinished && scheduler.activeCount == 0)
        let finishedWrites = writes
        scheduler.tick(deltaTime: 1)
        #expect(writes == finishedWrites)
    }
}
