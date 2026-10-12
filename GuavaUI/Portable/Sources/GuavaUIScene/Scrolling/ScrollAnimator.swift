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
/// // Platform wheel/trackpad packets already include OS momentum:
/// node.contentOffset = animator.scrollDirectly(by: delta)
/// // An application-owned gesture can explicitly use scroll(by:),
/// // move(to:) and settle() when it needs framework physics instead.
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
/// Each axis runs input, glide, then its own return spring —
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
    public var velocity: CGPoint {
        CGPoint(x: CGFloat(xMotion.glide ?? 0), y: CGFloat(yMotion.glide ?? 0))
    }

    /// Monotonic seconds. Replaceable so tests can drive time instead of
    /// waiting for it; nothing else should need to touch it.
    public var clock: () -> TimeInterval = ScrollAnimator.monotonicClock

    private static let clockOrigin = ContinuousClock.now

    public static var monotonicClock: () -> TimeInterval {
        { (ContinuousClock.now - clockOrigin) / .seconds(1) }
    }

    /// `true` while the return spring owns `offset`.
    public var isSettling: Bool { xMotion.spring != nil || yMotion.spring != nil }

    /// `true` while inertia owns `offset`.
    public var isGliding: Bool { xMotion.glide != nil || yMotion.glide != nil }

    /// `true` while any axis is past its bound, regardless of whether the
    /// return spring has started.
    public var isOverscrolled: Bool {
        RubberBand.excess(of: Float(position.x), maximum: Float(maximumOffset.x)) != 0
            || RubberBand.excess(of: Float(position.y), maximum: Float(maximumOffset.y)) != 0
    }

    public private(set) var isFinished: Bool = true

    private var xMotion = ScrollAxisMotion()
    private var yMotion = ScrollAxisMotion()
    private weak var scheduler: AnimatorScheduler? = AnimatorScheduler.current

    private var trackerX = ScrollVelocityTracker()
    private var trackerY = ScrollVelocityTracker()

    /// Release deadline for an explicitly managed custom gesture.
    /// Platform input never arms this timer.
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
        releaseDeadline = nil
        stopAnimation()
        resetTracking()
        position = Self.constrain(newOffset, to: maximumOffset)
        setOffset(position)
    }

    // MARK: - Input

    /// Follow a platform-owned wheel/trackpad stream exactly. Its packets
    /// already include acceleration and OS momentum. Never arm a quiet-window
    /// fling or insert a spring between packets, including phase-only packets.
    @discardableResult
    public func scrollDirectly(by delta: CGPoint) -> CGPoint {
        guard delta.x.isFinite, delta.y.isFinite else { return offset }
        cancel()
        position = Self.constrain(CGPoint(x: offset.x + delta.x, y: offset.y + delta.y), to: maximumOffset)
        setOffset(position)
        return offset
    }

    /// Apply one increment from an application-owned gesture and return its
    /// visible offset. With momentum enabled, silence for `idleWindow` infers
    /// release. Do not use this method for platform wheel/trackpad packets;
    /// use `scrollDirectly(by:)` to avoid adding inertia to OS momentum.
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
        // Input arriving while content is still coasting is a brake, not a
        // continuation. The samples behind that glide belong to a gesture the
        // user just ended by scrolling again, and keeping them would relaunch
        // the glide the moment this notch stopped it — the reason a notch used
        // to feel like it made things worse instead of stopping them.
        let wasCoasting = isGliding
        stopAnimation()
        // The pending release belongs to the previous input: once motion is
        // handed to the return spring there is nothing left to coast into, and
        // leaving it armed would stall that spring until it expired.
        releaseDeadline = nil
        if wasCoasting { resetTracking() }
        position = capped(CGPoint(x: position.x + delta.x, y: position.y + delta.y))
        recordInput(time: time)
        setOffset(visibleOffset(for: position))

        if isOverscrolled {
            let launch = currentVelocity()
            resetTracking()
            beginSettling(velocity: launch)
        } else if physics.momentum.isEnabled {
            releaseDeadline = time + max(0, physics.momentum.idleWindow)
            startDrivingFrames()
        }
        return offset
    }

    /// Place an application-owned gesture's raw position while recording
    /// velocity for `settle()`. A scrollbar thumb instead uses direct,
    /// clamped placement, without recording a throw.
    @discardableResult
    public func move(to newPosition: CGPoint) -> CGPoint {
        releaseDeadline = nil
        synchronizeRawPosition()
        // A thumb landing on coasting content is a grab, not a continuation:
        // see `scroll(by:)`.
        let wasCoasting = isGliding
        stopAnimation()
        if wasCoasting { resetTracking() }
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
    /// Called by the custom gesture owner, or after `scroll(by:)` has been
    /// quiet for `momentum.idleWindow`. Platform wheel and scrollbar thumb
    /// handlers do not launch this physics path.
    public func settle() {
        releaseDeadline = nil
        let launch = currentVelocity()
        // A nudge is not a throw. One or two samples describe the gap between
        // two events rather than a gesture, and launching from them is what
        // made a notch meant to stop the content send it off again.
        let floor = physics.momentum.minimumSampleCount
        var thrown = launch
        if trackerX.sampleCount < floor { thrown.x = 0 }
        if trackerY.sampleCount < floor { thrown.y = 0 }
        resetTracking()

        let enoughThrow = hypot(thrown.x, thrown.y) > CGFloat(physics.momentum.minimumVelocity)
        guard physics.momentum.isEnabled, !isOverscrolled, enoughThrow else {
            settleNow(velocity: thrown)
            return
        }
        beginGlide(velocity: thrown)
    }

    /// Stop a glide dead where it is, leaving the current offset alone.
    ///
    /// Touching content that is still moving is how a user says "here", so the
    /// pointer going down anywhere inside the container counts. The return
    /// spring is deliberately left running: it already knows where it is
    /// going, and stopping it would strand the content out of bounds.
    public func stopCoasting() {
        releaseDeadline = nil
        resetTracking()
        stopGlide()
        if !isSettling { stopDrivingFrames() }
    }

    // MARK: - AnyAnimationController

    public func tick(deltaTime: Double) {
        if let deadline = releaseDeadline {
            // Still inside the quiet window — a notch may yet arrive.
            guard clock() >= deadline else { return }
            settle()
            return
        }
        guard deltaTime.isFinite, deltaTime > 0 else { return }
        let step = Float(deltaTime)
        let x = xMotion.advance(position: position.x, offset: offset.x, maximum: maximumOffset.x,
                                extent: viewportSize.width, physics: physics, duration: step)
        let y = yMotion.advance(position: position.y, offset: offset.y, maximum: maximumOffset.y,
                                extent: viewportSize.height, physics: physics, duration: step)
        position = CGPoint(x: x.0, y: y.0)
        setOffset(CGPoint(x: x.1, y: y.1))
        if !isGliding && !isSettling { stopDrivingFrames() }
    }

    /// Land immediately on the in-bounds position.
    public func finishImmediately() {
        guard isSettling || isGliding || isOverscrolled || releaseDeadline != nil else { return }
        releaseDeadline = nil
        position = Self.constrain(position, to: maximumOffset)
        stopAnimation()
        landAtCurrentPosition()
        isFinished = true
    }

    /// Drop whatever motion is running without applying anything further.
    public func cancel() {
        releaseDeadline = nil
        resetTracking()
        stopAnimation()
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
        scheduler?.register(self)
    }

    private func beginGlide(velocity launch: CGPoint) {
        guard launch.x != 0 || launch.y != 0 else {
            settleNow(velocity: .zero)
            return
        }
        xMotion.glide = Float(launch.x)
        yMotion.glide = Float(launch.y)
        startDrivingFrames()
    }

    private func stopGlide() {
        xMotion.glide = nil
        yMotion.glide = nil
    }

    private func settleNow(velocity launch: CGPoint) {
        guard isOverscrolled else {
            // Braking is not coming to rest: the user put the content here, so
            // it stays exactly here. Aligning it would move it by up to half a
            // point under them, which reads as a stutter on the notch they
            // meant as a stop.
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
        stopGlide()
        xMotion.spring = position.x < 0 || position.x > maximumOffset.x ? ScrollSpring(value: Float(offset.x),
                               velocity: Float(velocity.x),
                               target: Float(target.x),
                               settings: settings) : nil
        yMotion.spring = position.y < 0 || position.y > maximumOffset.y ? ScrollSpring(value: Float(offset.y),
                               velocity: Float(velocity.y),
                               target: Float(target.y),
                               settings: settings) : nil
        guard physics.rubberBand.isEnabled else {
            // Nothing was ever stretched — land directly to avoid the host
            // producing frames for a spring with zero travel.
            finishImmediately()
            return
        }
        startDrivingFrames()
    }

    private func stopSettling() {
        xMotion.spring = nil
        yMotion.spring = nil
    }

    private func stopAnimation() {
        stopSettling()
        stopGlide()
        stopDrivingFrames()
    }

    private func stopDrivingFrames() {
        isFinished = true
        scheduler?.unregister(self)
    }

    private func setOffset(_ next: CGPoint) {
        guard next != offset else { return }
        offset = next
        onChange(next)
    }

    private func landAtCurrentPosition() {
        // Preserve the final subpixel position. Rounding here causes a visible
        // backward nudge on Retina displays and on interrupted motion.
        position = Self.constrain(position, to: maximumOffset)
        setOffset(position)
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
