#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Owns the rubber-band behaviour of one scrollable offset.
///
/// Components that scroll keep one instance alongside their own state and
/// route every offset change through it:
///
/// ```swift
/// animator.physics = node.scrollPhysics
/// animator.update(maximumOffset: CGPoint(x: maxX, y: maxY), viewportSize: viewSize)
/// // continuous input (wheel, two-finger trackpad):
/// node.contentOffset = animator.scroll(by: delta)
/// // gesture end:
/// animator.settle()
/// ```
///
/// Two coordinate systems are kept apart on purpose:
/// - **raw position** — where input wants the content to be. Unbounded input
///   pushes it past `0...maximumOffset`.
/// - **visible offset** — what gets written out. Equal to the raw position
///   inside the range, and a compressed version of it past the range.
///
/// Keeping the raw position lets a gesture continue to move the viewport even
/// while it is fully stretched: each new delta is added to where the user is
/// actually pointing, instead of to an already-clamped value that has lost the
/// overflow.
///
/// While settling the animator registers itself with
/// `AnimatorScheduler.current` so the host keeps producing frames, and drops
/// out again once it comes to rest.
public final class ScrollRubberBandAnimator: AnyAnimationController {

    /// Behaviour tuning. May be replaced between interactions; changes take
    /// effect on the next input or settle.
    public var physics: ScrollPhysics

    /// Called whenever the visible offset changes — including once per frame
    /// while settling. The owner writes the value to wherever it keeps its
    /// scroll offset (`Node.contentOffset` for `ScrollView`).
    public let onChange: (CGPoint) -> Void

    /// The offset that should currently be drawn. May sit outside
    /// `0...maximumOffset` while stretched.
    public private(set) var offset: CGPoint

    /// Where input has pushed the content, before compression.
    public private(set) var position: CGPoint

    public private(set) var maximumOffset: CGPoint
    public private(set) var viewportSize: CGSize

    /// `true` while the return spring owns `offset`.
    public var isSettling: Bool { springX != nil || springY != nil }

    /// `true` while any axis is past its bound, regardless of whether the
    /// return spring has started.
    public var isOverscrolled: Bool {
        RubberBand.excess(of: Float(position.x), maximum: Float(maximumOffset.x)) != 0
            || RubberBand.excess(of: Float(position.y), maximum: Float(maximumOffset.y)) != 0
    }

    public private(set) var isFinished: Bool = true

    private var springX: ScrollSpring?
    private var springY: ScrollSpring?

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
    /// A range that *shrank* pulls the offset back in immediately: the content
    /// the overscroll was leaning against is gone, so there is nothing to
    /// bounce back from, and leaving the viewport stranded past the new end
    /// (cleared console, filtered list) is worse than an abrupt jump. Growth
    /// is left alone, otherwise this would eat every in-flight rubber band.
    public func update(maximumOffset: CGPoint, viewportSize: CGSize) {
        let previous = self.maximumOffset
        self.maximumOffset = maximumOffset
        self.viewportSize = viewportSize
        guard maximumOffset.x < previous.x || maximumOffset.y < previous.y else { return }
        let constrained = Self.constrain(position, to: maximumOffset)
        guard constrained != position else { return }
        stopSettling()
        position = constrained
        setOffset(constrained)
    }

    /// Adopt an offset written by someone else — a two-way
    /// `scrollOffset:` binding, a `scrollTo` call, a layout correction.
    ///
    /// Interrupting a settle this way is deliberate: an authoritative write
    /// wins over an animation that is only cleaning up after a gesture.
    public func adopt(_ newOffset: CGPoint) {
        guard newOffset != offset else { return }
        stopSettling()
        position = Self.constrain(newOffset, to: maximumOffset)
        setOffset(position)
    }

    // MARK: - Input

    /// Apply one increment of continuous input (wheel notch, trackpad sample)
    /// and return the visible offset.
    ///
    /// When the increment lands past a bound the return spring starts right
    /// away, so a single notch at the end of a list produces a short pull that
    /// relaxes back. Further increments re-enter through `synchronize`, which
    /// folds whatever the spring has already recovered back into the raw
    /// position — so rapid notches build up smoothly instead of snapping back
    /// to the same full stretch each time.
    @discardableResult
    public func scroll(by delta: CGPoint) -> CGPoint {
        synchronizeRawPosition()
        stopSettling()
        position = capped(CGPoint(x: position.x + delta.x, y: position.y + delta.y))
        setOffset(visibleOffset(for: position))
        if isOverscrolled { beginSettling() }
        return offset
    }

    /// Place the raw position directly — used while dragging a scrollbar
    /// thumb, where the pointer maps onto a position rather than a delta.
    @discardableResult
    public func move(to newPosition: CGPoint) -> CGPoint {
        stopSettling()
        position = capped(newPosition)
        setOffset(visibleOffset(for: position))
        return offset
    }

    /// Release drawn content back inside its bounds with the configured
    /// spring. No-op when already inside.
    ///
    /// - Parameter velocity: initial velocity in points per second, for
    ///   callers that track gesture velocity. Defaults to zero, i.e. the
    ///   spring starts from rest.
    public func settle(velocity: CGPoint = .zero) {
        guard isOverscrolled else {
            stopSettling()
            position = Self.constrain(position, to: maximumOffset)
            return
        }
        beginSettling(velocity: velocity)
    }

    // MARK: - AnyAnimationController

    public func tick(deltaTime: Double) {
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
        guard isSettling else { return }
        position = Self.constrain(position, to: maximumOffset)
        stopSettling()
        setOffset(position)
        isFinished = true
    }

    /// Drop the return spring without applying anything further.
    public func cancel() {
        stopSettling()
        isFinished = true
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

    private func beginSettling(velocity: CGPoint = .zero) {
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
        isFinished = false
        AnimatorScheduler.current.register(self)
    }

    private func stopSettling() {
        springX = nil
        springY = nil
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

    private static func constrain(_ value: CGPoint, to maximum: CGPoint) -> CGPoint {
        CGPoint(x: constrainAxis(value.x, maximum: maximum.x),
                y: constrainAxis(value.y, maximum: maximum.y))
    }

    private static func constrainAxis(_ value: CGFloat, maximum: CGFloat) -> CGFloat {
        let upper = max(0, maximum)
        return min(max(value, 0), upper)
    }
}
