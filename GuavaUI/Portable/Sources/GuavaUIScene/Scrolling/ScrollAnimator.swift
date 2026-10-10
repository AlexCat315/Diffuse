#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Owns every kind of motion one scrollable offset can have: the inertia that
/// carries content along after input stops, the rubber band it stretches
/// against past its bounds, and the spring that brings it back.
///
/// Components that scroll keep one instance alongside their own state and
/// route every offset change through it:
///
/// ```swift
/// animator.physics = node.scrollPhysics
/// animator.update(maximumOffset: CGPoint(x: maxX, y: maxY), viewportSize: viewSize)
/// // continuous input (wheel notch, trackpad sample):
/// node.contentOffset = animator.scroll(by: delta)
/// // the wheel never reports release — the glide launches on its own once
/// // input has been quiet for `momentum.idleWindow`; a gesture with a real
/// // end (scrollbar thumb) says so:
/// animator.settle()
/// ```
///
/// Two coordinate systems are kept apart on purpose:
/// - **raw position** — where input has pushed the content. Unbounded input
///   pushes it past `0...maximumOffset`.
/// - **visible offset** — what gets written out. Equal to the raw position
///   inside the range, and a compressed version of it past the range.
///
/// Keeping the raw position lets a gesture continue to move the viewport even
/// while it is fully stretched: each new delta is added to where the user is
/// actually pointing, instead of to an already-clamped value that has lost the
/// overflow. It also gives the glide somewhere to run: coasting down a long
/// document must not slow down just because the visible offset is compressed
/// near an edge.
///
/// Phases run in a fixed order — input, then glide, then the return spring —
/// and each one hands its leftover velocity to the next, which is what makes a
/// throw into the end of a list bounce instead of stopping.
///
/// While anything is moving the animator registers itself with
/// `AnimatorScheduler.current` so the host keeps producing frames, and drops
/// out again once it comes to rest.
public final class ScrollAnimator: AnyAnimationController {

    /// Behaviour tuning. May be replaced between interactions; changes take
    /// effect on the next input or settle.
    public var physics: ScrollPhysics

    /// Called whenever the visible offset changes — including once per frame
    /// while gliding or settling. The owner writes the value to wherever it
    /// keeps its scroll offset (`Node.contentOffset` for `ScrollView`).
    public let onChange: (CGPoint) -> Void

    /// The offset that should currently be drawn. May sit outside
    /// `0...maximumOffset` while stretched.
    public private(set) var offset: CGPoint

    /// Where input has pushed the content, before compression.
    public private(set) var position: CGPoint

    public private(set) var maximumOffset: CGPoint
    public private(set) var viewportSize: CGSize

    /// Velocity of the current glide, in points per second. Zero unless
    /// coasting.
    public private(set) var velocity: CGPoint = .zero

    /// Monotonic seconds. Replaceable so tests can drive time instead of
    /// waiting for it; nothing else should need to touch it.
    public var clock: () -> TimeInterval = ScrollAnimator.monotonicClock

    private static let clockOrigin = ContinuousClock.now

    public static var monotonicClock: () -> TimeInterval {
        { (ContinuousClock.now - clockOrigin) / .seconds(1) }
    }

    /// `true` while the return spring owns `offset`.
    public var isSettling: Bool { springX != nil || springY != nil }

    /// `true` while inertia owns `offset`.
    public var isGliding: Bool { glideX != nil || glideY != nil }

    /// `true` while any axis is past its bound, regardless of whether the
    /// return spring has started.
    public var isOverscrolled: Bool {
        RubberBand.excess(of: Float(position.x), maximum: Float(maximumOffset.x)) != 0
            || RubberBand.excess(of: Float(position.y), maximum: Float(maximumOffset.y)) != 0
    }

    public private(set) var isFinished: Bool = true

    private var springX: ScrollSpring?
    private var springY: ScrollSpring?

    private var glideX: Float?
    private var glideY: Float?

    private var trackerX = ScrollVelocityTracker()
    private var trackerY = ScrollVelocityTracker()

    /// Time after which the last wheel sample is treated as the end of the
    /// gesture. `nil` when no release is pending.
    private var releaseDeadline: TimeInterval?

    public init(physics: ScrollPhysics = .default,
                maximumOffset: CGPoint = .zero,
                viewportSize: CGSize = .zero,
                initialOffset: CGPoint = .zero,
                onChange: @escaping (CGPoint) -> Void = { _ in }) {
        self.physics = physics
        self.maximumOffset = maximumOffset
        self.viewportSize = viewportSize
        self.position = Self.constrain(initialOffset, to: maximumOffset)
        self.offset = position
        self.onChange = onChange
    }

    // MARK: - Range

    /// Publish freshly laid-out geometry. Cheap — call before every
    /// interaction so late-measured content still produces correct bounds.
    ///
    /// A range that *shrank* pulls the offset back in immediately and drops the
    /// recorded velocity: the content the glide was aimed at may no longer be
    /// there, so coasting into the new bounds from stale samples would be a
    /// guess (cleared console, filtered list). Growth is left alone, otherwise
    /// this would eat every in-flight motion.
    public func update(maximumOffset: CGPoint, viewportSize: CGSize) {
        let previous = self.maximumOffset
        self.maximumOffset = maximumOffset
        self.viewportSize = viewportSize
        guard maximumOffset.x < previous.x || maximumOffset.y < previous.y else { return }
        let constrained = Self.constrain(position, to: maximumOffset)
        guard constrained != position else { return }
        stopAnimation()
        resetTracking()
        // Whatever was aimed at the old range has nowhere to land now.
        releaseDeadline = nil
        position = constrained
        setOffset(constrained)
    }

    /// Adopt an offset written by someone else — a two-way
    /// `scrollOffset:` binding, a `scrollTo` call, a layout correction.
    ///
    /// Interrupting motion this way is deliberate: an authoritative write wins
    /// over an animation that is only cleaning up after a gesture.
    public func adopt(_ newOffset: CGPoint) {
        guard newOffset != offset else { return }
        stopAnimation()
        resetTracking()
        position = Self.constrain(newOffset, to: maximumOffset)
        setOffset(position)
    }

    // MARK: - Input

    /// Apply one increment of continuous input (wheel notch, trackpad sample)
    /// and return the visible offset.
    ///
    /// Wheel devices never announce that the gesture ended, so instead of
    /// waiting for a release this arms one: if no further input arrives within
    /// `momentum.idleWindow`, the recorded velocity launches a glide. A
    /// discrete mouse wheel therefore coasts after a fast burst of notches,
    /// and a trackpad gets its flick back the moment the fingers lift.
    ///
    /// Landing past a bound skips all of that and starts the return spring
    /// right away, so a single notch at the end of a list produces a short pull
    /// that relaxes back instead of a glide with nowhere to go. Further
    /// increments re-enter through `synchronizeRawPosition`, which folds
    /// whatever the spring has already recovered back into the raw position,
    /// so rapid notches build up smoothly.
    @discardableResult
    public func scroll(by delta: CGPoint) -> CGPoint {
        let time = clock()
        synchronizeRawPosition()
        stopAnimation()
        // The pending release belongs to the previous input: once motion is
        // handed to the return spring there is nothing left to coast into, and
        // leaving it armed would stall that spring until it expired.
        releaseDeadline = nil
        position = capped(CGPoint(x: position.x + delta.x, y: position.y + delta.y))
        recordInput(time: time)
        setOffset(visibleOffset(for: position))

        if isOverscrolled {
            let launch = currentVelocity()
            resetTracking()
            beginSettling(velocity: launch)
        } else if physics.momentum.isEnabled {
            releaseDeadline = time + max(0, physics.momentum.idleWindow)
            isFinished = false
            AnimatorScheduler.current.register(self)
        }
        return offset
    }

    /// Place the raw position directly — used while dragging a scrollbar
    /// thumb, where the pointer maps onto a position rather than a delta.
    ///
    /// Samples are still recorded, so releasing a thumb that was moving
    /// launches the same glide a flick does.
    @discardableResult
    public func move(to newPosition: CGPoint) -> CGPoint {
        releaseDeadline = nil
        synchronizeRawPosition()
        stopAnimation()
        position = capped(newPosition)
        recordInput(time: clock())
        setOffset(visibleOffset(for: position))
        return offset
    }

    /// Release input that has stopped, whether or not anything announced it.
    ///
    /// Content keeps coasting when it was moving fast enough; anything leaning
    /// past a bound springs straight back, carrying whatever speed was left
    /// into the bounce.
    ///
    /// Called at the end of a gesture by both paths: by this animator once
    /// wheel input has been quiet for `momentum.idleWindow`, and by the owner
    /// when a gesture that really does end (a scrollbar thumb) is let go.
    public func settle() {
        releaseDeadline = nil
        let launch = currentVelocity()
        resetTracking()

        let enoughThrow = hypot(launch.x, launch.y) > CGFloat(physics.momentum.minimumVelocity)
        guard physics.momentum.isEnabled, !isOverscrolled, enoughThrow else {
            settleNow(velocity: launch)
            return
        }
        beginGlide(velocity: launch)
    }

    // MARK: - AnyAnimationController

    public func tick(deltaTime: Double) {
        if let deadline = releaseDeadline {
            // Still inside the quiet window — a notch may yet arrive.
            guard clock() >= deadline else { return }
            settle()
            return
        }
        if isGliding {
            advanceGlide(deltaTime: Float(deltaTime))
            return
        }
        guard isSettling else {
            isFinished = true
            return
        }

        let step = Float(deltaTime)
        if var x = springX {
            x.advance(deltaTime: step)
            springX = x
        }
        if var y = springY {
            y.advance(deltaTime: step)
            springY = y
        }

        let xAtRest = springX?.isAtRest ?? true
        let yAtRest = springY?.isAtRest ?? true
        guard xAtRest, yAtRest else {
            setOffset(CGPoint(x: CGFloat(springX?.value ?? Float(offset.x)),
                              y: CGFloat(springY?.value ?? Float(offset.y))))
            return
        }

        position = Self.constrain(position, to: maximumOffset)
        stopSettling()
        setOffset(position)
        isFinished = true
    }

    /// Land immediately on the in-bounds position.
    public func finishImmediately() {
        guard isSettling || isGliding || releaseDeadline != nil else { return }
        releaseDeadline = nil
        position = Self.constrain(position, to: maximumOffset)
        stopAnimation()
        setOffset(position)
        isFinished = true
    }

    /// Drop whatever motion is running without applying anything further.
    public func cancel() {
        releaseDeadline = nil
        stopAnimation()
        isFinished = true
    }

    // MARK: - Velocity

    /// How fast the gesture is moving right now, in points per second, clamped
    /// to `momentum.maximumVelocity`. Axes are measured separately, so flinging
    /// a `.both` container diagonally does not average the two together.
    public func currentVelocity() -> CGPoint {
        let now = clock()
        let staleAfter = max(0, physics.momentum.staleWindow)
        let ceiling = max(0, physics.momentum.maximumVelocity)
        return CGPoint(x: Self.clamp(trackerX.velocity(at: now, staleAfter: staleAfter),
                                     to: ceiling),
                       y: Self.clamp(trackerY.velocity(at: now, staleAfter: staleAfter),
                                     to: ceiling))
    }

    // MARK: - Private

    /// Before new input, fold the distance the spring has already recovered
    /// back into the raw position so there is no visible jump.
    ///
    /// `RubberBand.unproject` exists for exactly this: the displayed offset is
    /// compressed, so re-deriving the raw position from it requires the
    /// inverse curve, not a plain assignment.
    ///
    /// The recovered position is deliberately *not* clamped into the range: it
    /// still sits past the bound, just closer to it. Clamping here would throw
    /// away the remaining stretch and make continued input start from the
    /// bound again.
    private func synchronizeRawPosition() {
        guard isSettling else { return }
        position = capped(rawPosition(for: offset))
    }

    /// Feed both trackers one sample.
    ///
    /// The *raw* position, not the visible one: past either bound the visible
    /// offset is compressed, so measuring against it would under-report the
    /// speed exactly where the throw is most likely to end.
    private func recordInput(time: TimeInterval) {
        trackerX.window = physics.momentum.trackingWindow
        trackerY.window = physics.momentum.trackingWindow
        trackerX.add(time: time, value: Float(position.x))
        trackerY.add(time: time, value: Float(position.y))
    }

    private func resetTracking() {
        trackerX.reset()
        trackerY.reset()
    }

    private func startDrivingFrames() {
        isFinished = false
        AnimatorScheduler.current.register(self)
    }

    private func beginGlide(velocity launch: CGPoint) {
        guard launch.x != 0 || launch.y != 0 else {
            settleNow(velocity: .zero)
            return
        }
        glideX = Float(launch.x)
        glideY = Float(launch.y)
        velocity = launch
        startDrivingFrames()
    }

    private func stopGlide() {
        glideX = nil
        glideY = nil
        velocity = .zero
    }

    /// Per-axis result of one glide frame.
    private struct AxisStep {
        var position: CGFloat
        /// Velocity carried into the next frame; `nil` once this axis is done.
        var velocity: Float?
        /// Speed still left at the moment this axis stopped — handed to the
        /// return spring so the handover has no seam.
        var remaining: Float
    }

    private func advanceGlide(deltaTime: Float) {
        let settings = physics.momentum
        let rate = max(0.1, settings.deceleration)
        let decay = exp(-rate * deltaTime)
        // Exact closed-form integral of `v(t) = v0·e^(-rate·t)`, so the
        // distance travelled does not depend on how frames were cut.
        let travel = (1 - decay) / rate

        let allowsStretch = physics.rubberBand.isEnabled
        let x = glideAxis(position: position.x,
                          maximum: maximumOffset.x,
                          glide: glideX,
                          decay: decay,
                          travel: travel,
                          settings: settings,
                          allowsOverscroll: allowsStretch)
        let y = glideAxis(position: position.y,
                          maximum: maximumOffset.y,
                          glide: glideY,
                          decay: decay,
                          travel: travel,
                          settings: settings,
                          allowsOverscroll: allowsStretch)

        glideX = x.velocity
        glideY = y.velocity
        velocity = CGPoint(x: CGFloat(x.velocity ?? 0), y: CGFloat(y.velocity ?? 0))
        position = capped(CGPoint(x: x.position, y: y.position))
        setOffset(visibleOffset(for: position))

        guard x.velocity == nil && y.velocity == nil else { return }

        let leftover = CGPoint(x: CGFloat(x.remaining), y: CGFloat(y.remaining))
        stopGlide()
        guard allowsStretch else {
            // Nothing may stretch, so the coast ended right at the edge.
            position = Self.constrain(position, to: maximumOffset)
            setOffset(position)
            isFinished = true
            return
        }
        // Whatever overscroll the glide ran into springs back; the leftover
        // speed, small by now, goes along so the handover has no seam.
        settleNow(velocity: leftover)
        if !isSettling { isFinished = true }
    }

    /// Move one axis of the glide by its own share of this frame.
    ///
    /// Each axis keeps coasting in raw space until it runs out of speed — even
    /// past its own bound, which is what lets a flick into the end of a list
    /// lean into it and then rebound rather than stopping short. The raw cap in
    /// `capped(_:)` keeps that lean bounded, and compression turns it into the
    /// visible stretch.
    ///
    /// Without a rubber band to absorb it there is nothing to lean against, so
    /// the axis lands exactly on its bound and stops instead.
    private func glideAxis(position: CGFloat,
                           maximum: CGFloat,
                           glide: Float?,
                           decay: Float,
                           travel: Float,
                           settings: ScrollMomentumSettings,
                           allowsOverscroll: Bool) -> AxisStep {
        guard let glide else {
            return AxisStep(position: position, velocity: nil, remaining: 0)
        }
        let next = position + CGFloat(glide * travel)
        let remaining = glide * decay
        let exhausted = abs(remaining) < settings.minimumVelocity
        let atEdge = !allowsOverscroll && (next < 0 || next > maximum)
        guard exhausted || atEdge else {
            return AxisStep(position: next, velocity: remaining, remaining: remaining)
        }
        let landed = allowsOverscroll ? next : Self.constrainAxis(next, maximum: maximum)
        return AxisStep(position: landed, velocity: nil, remaining: remaining)
    }

    private func settleNow(velocity launch: CGPoint) {
        guard isOverscrolled else {
            stopAnimation()
            position = Self.constrain(position, to: maximumOffset)
            return
        }
        beginSettling(velocity: launch)
    }

    private func beginSettling(velocity: CGPoint = .zero) {
        // One owner of motion at a time: the spring replaces any pending glide.
        releaseDeadline = nil
        let target = Self.constrain(position, to: maximumOffset)
        let settings = physics.settle
        springX = ScrollSpring(value: Float(offset.x),
                               velocity: Float(velocity.x),
                               target: Float(target.x),
                               settings: settings)
        springY = ScrollSpring(value: Float(offset.y),
                               velocity: Float(velocity.y),
                               target: Float(target.y),
                               settings: settings)
        guard physics.rubberBand.isEnabled else {
            // Nothing was ever stretched — land directly to avoid the host
            // producing frames for a spring with zero travel.
            finishImmediately()
            return
        }
        startDrivingFrames()
    }

    private func stopSettling() {
        springX = nil
        springY = nil
    }

    private func stopAnimation() {
        stopSettling()
        stopGlide()
    }

    private func setOffset(_ next: CGPoint) {
        offset = next
        onChange(next)
    }

    /// Project a raw position onto the visible one, applying rubber-band
    /// compression to whatever lands outside `0...maximumOffset`.
    private func visibleOffset(for raw: CGPoint) -> CGPoint {
        CGPoint(x: Self.axisOffset(raw.x,
                                   maximum: maximumOffset.x,
                                   extent: Float(viewportSize.width),
                                   rubberBand: physics.rubberBand),
                y: Self.axisOffset(raw.y,
                                   maximum: maximumOffset.y,
                                   extent: Float(viewportSize.height),
                                   rubberBand: physics.rubberBand))
    }

    private func rawPosition(for visible: CGPoint) -> CGPoint {
        CGPoint(x: Self.axisPosition(visible.x,
                                     maximum: maximumOffset.x,
                                     extent: Float(viewportSize.width),
                                     rubberBand: physics.rubberBand),
                y: Self.axisPosition(visible.y,
                                     maximum: maximumOffset.y,
                                     extent: Float(viewportSize.height),
                                     rubberBand: physics.rubberBand))
    }

    /// Cap the raw overscroll so a long gesture cannot accumulate an unbounded
    /// amount of travel for the return spring to recover.
    private func capped(_ raw: CGPoint) -> CGPoint {
        CGPoint(x: Self.cappedAxis(raw.x,
                                   maximum: maximumOffset.x,
                                   limit: physics.rubberBand.maximumRawOverscroll * Float(viewportSize.width)),
                y: Self.cappedAxis(raw.y,
                                   maximum: maximumOffset.y,
                                   limit: physics.rubberBand.maximumRawOverscroll * Float(viewportSize.height)))
    }

    private static func axisOffset(_ raw: CGFloat,
                                   maximum: CGFloat,
                                   extent: Float,
                                   rubberBand: ScrollRubberBandSettings) -> CGFloat {
        guard rubberBand.isEnabled, extent.isFinite, extent > 0 else {
            return constrainAxis(raw, maximum: maximum)
        }
        let excess = RubberBand.excess(of: Float(raw), maximum: Float(maximum))
        guard excess != 0 else { return raw }
        let projected = RubberBand.project(overscroll: excess,
                                           extent: extent,
                                           compliance: rubberBand.compliance)
        return CGFloat((excess < 0 ? 0 : Float(maximum)) + projected)
    }

    private static func axisPosition(_ visible: CGFloat,
                                     maximum: CGFloat,
                                     extent: Float,
                                     rubberBand: ScrollRubberBandSettings) -> CGFloat {
        guard rubberBand.isEnabled, extent.isFinite, extent > 0 else {
            return constrainAxis(visible, maximum: maximum)
        }
        let excess = RubberBand.excess(of: Float(visible), maximum: Float(maximum))
        guard excess != 0 else { return visible }
        let raw = RubberBand.unproject(visibleOverscroll: excess,
                                       extent: extent,
                                       compliance: rubberBand.compliance)
        return CGFloat((excess < 0 ? 0 : Float(maximum)) + raw)
    }

    private static func cappedAxis(_ value: CGFloat,
                                   maximum: CGFloat,
                                   limit: Float) -> CGFloat {
        guard limit.isFinite else { return constrainAxis(value, maximum: maximum) }
        let excess = RubberBand.excess(of: Float(value), maximum: Float(maximum))
        guard abs(excess) > max(0, limit) else { return value }
        let bounded = max(0, limit) * (excess < 0 ? -1 : 1)
        return CGFloat((excess < 0 ? 0 : Float(maximum)) + bounded)
    }

    private static func clamp(_ value: Float, to magnitude: Float) -> CGFloat {
        guard magnitude.isFinite else { return CGFloat(value) }
        if value > magnitude { return CGFloat(magnitude) }
        if value < -magnitude { return CGFloat(-magnitude) }
        return CGFloat(value)
    }

    private static func constrain(_ value: CGPoint, to maximum: CGPoint) -> CGPoint {
        CGPoint(x: constrainAxis(value.x, maximum: maximum.x),
                y: constrainAxis(value.y, maximum: maximum.y))
    }

    private static func constrainAxis(_ value: CGFloat, maximum: CGFloat) -> CGFloat {
        let upper = max(0, maximum)
        return min(max(value, 0), upper)
    }
}
