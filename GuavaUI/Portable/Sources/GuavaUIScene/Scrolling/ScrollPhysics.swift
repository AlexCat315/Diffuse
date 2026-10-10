import GuavaUICore

/// Tuning for the rubber-band stretch applied when a scroll offset travels
/// past one of its bounds.
///
/// The stretch is *not* linear: the further past the bound the user pushes,
/// the stiffer it gets, asymptotically approaching the viewport extent along
/// the scrolled axis. That is what makes the resistance feel elastic instead
/// of merely "slow".
public struct ScrollRubberBandSettings: Sendable, Equatable {
    /// `false` restores hard clamping — the offset stops dead at the bound.
    public var isEnabled: Bool = true

    /// Fraction of the raw overscroll visible for the first point pushed past
    /// the bound. Lower values feel stiffer. `0.55` matches UIKit/AppKit.
    public var compliance: Float = 0.55

    /// Hard ceiling on the *raw* overscroll, expressed as a multiple of the
    /// viewport extent. The projected distance is bounded anyway, but without
    /// a ceiling the raw position keeps growing forever during a long gesture
    /// and the release spring has an unbound amount of travel to recover.
    public var maximumRawOverscroll: Float = 2

    public init(isEnabled: Bool = true,
                compliance: Float = 0.55,
                maximumRawOverscroll: Float = 2) {
        self.isEnabled = isEnabled
        self.compliance = compliance
        self.maximumRawOverscroll = maximumRawOverscroll
    }
}

/// Tuning for the spring that returns an overscrolled offset back inside its
/// bounds once input stops.
///
/// `response` / `dampingFraction` mirror `AnimationCurve.spring` so motion
/// stays consistent with the rest of the animation system.
public struct ScrollSettleSettings: Sendable, Equatable {
    /// Approximate period, in seconds, of one natural oscillation of the
    /// spring. Smaller is snappier.
    public var response: Float = 0.34

    /// Damping ratio. `1` is critical damping (returns without crossing the
    /// bound); values below `1` overshoot and visibly bounce at the bound.
    public var dampingFraction: Float = 1

    /// Distance below which the spring snaps to its target and stops.
    public var positionTolerance: Float = 0.05

    /// Velocity (points per second) below which the spring stops.
    public var velocityTolerance: Float = 1

    /// Largest frame delta handed to the integrator in one step. Large deltas
    /// are split into several steps so a stalled frame cannot destabilise the
    /// solution.
    public var maximumTimeStep: Float = 1.0 / 120.0

    public init(response: Float = 0.34,
                dampingFraction: Float = 1,
                positionTolerance: Float = 0.05,
                velocityTolerance: Float = 1,
                maximumTimeStep: Float = 1.0 / 120.0) {
        self.response = response
        self.dampingFraction = dampingFraction
        self.positionTolerance = positionTolerance
        self.velocityTolerance = velocityTolerance
        self.maximumTimeStep = maximumTimeStep
    }
}

/// How a scrollable container reacts to input that pushes it past its bounds.
///
/// Split into two independent groups because they answer different questions:
/// how far content *stretches* while being pushed, and how it *returns* once
/// released. Reusable outside `ScrollView` — any component that owns a
/// scrollable offset can share one instance.
public struct ScrollPhysics: Sendable, Equatable {
    public var rubberBand: ScrollRubberBandSettings
    public var settle: ScrollSettleSettings

    public init(rubberBand: ScrollRubberBandSettings = .init(),
                settle: ScrollSettleSettings = .init()) {
        self.rubberBand = rubberBand
        self.settle = settle
    }
}

public extension ScrollPhysics {
    /// Rubber band with a critically damped return — the default everywhere.
    static let `default` = ScrollPhysics()

    /// Hard clamping at both bounds. Opt-in for surfaces where any overshoot
    /// reads as a bug (canvas rulers, scroll-linked timelines).
    static let clamped = ScrollPhysics(rubberBand: ScrollRubberBandSettings(isEnabled: false))

    /// Stretch plus a visible bounce at the bound on release.
    static let bouncy = ScrollPhysics(
        settle: ScrollSettleSettings(response: 0.42, dampingFraction: 0.62)
    )

    /// Stretch only at the far end, with a stiff early curve and a slow return.
    /// Useful for lists where the top edge is anchored to a header.
    static let firm = ScrollPhysics(
        rubberBand: ScrollRubberBandSettings(compliance: 0.25),
        settle: ScrollSettleSettings(response: 0.5)
    )
}
