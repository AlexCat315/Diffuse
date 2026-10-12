import Foundation
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

    public init(response: Float = 0.34,
                dampingFraction: Float = 1,
                positionTolerance: Float = 0.05,
                velocityTolerance: Float = 1) {
        self.response = response
        self.dampingFraction = dampingFraction
        self.positionTolerance = positionTolerance
        self.velocityTolerance = velocityTolerance
    }
}

/// Tuning for inertial scrolling — the glide that carries content along after
/// the input that produced it has stopped.
///
/// Applies to explicitly managed custom gestures using `ScrollAnimator`.
/// `idleWindow` infers release only for that API; native wheel/trackpad input
/// follows the platform stream directly and does not use these settings.
public struct ScrollMomentumSettings: Sendable, Equatable {
    /// `false` stops content dead the moment input stops.
    public var isEnabled: Bool = true

    /// Decay rate in nepers per second: velocity is multiplied by `e^-rate`
    /// each second. Together with `maximumVelocity` this decides how far the
    /// hardest possible throw travels — `(v₀ - restVelocity) / rate`, so
    /// `4.2` and `1100` take a full-strength flick about 261pt further, with
    /// a gradual tail reaching 2pt/s after about 1.5 seconds. iOS'
    /// `DecelerationRate.normal` (≈ e^-2.0 per second) is tuned for a finger on
    /// glass and reads as "launched" with a mouse: several viewports of travel
    /// and a tail that drifts for two seconds. Higher stops sooner.
    public var deceleration: Float = 4.2

    /// Launch speed, in points per second, below which the gesture counts as
    /// placed rather than thrown and no glide starts. High enough that nudging
    /// content into place — the thing you do once it is nearly right — never
    /// sets it moving again.
    public var minimumVelocity: Float = 50

    /// Speed at which an existing glide comes to rest. Kept separate from the
    /// launch threshold: stopping at 50pt/s visibly cuts off the slow tail.
    public var restVelocity: Float = 2

    /// Ceiling on the launch speed. Wheel notches arrive milliseconds apart, so
    /// the measured slope of even a modest burst is enormous; without a ceiling
    /// one such burst throws the viewport across the whole document.
    public var maximumVelocity: Float = 1_100

    /// Samples a gesture must have produced inside `trackingWindow` before it
    /// counts as a throw.
    ///
    /// A short sample pair can exaggerate velocity; require enough samples
    /// from the custom gesture to distinguish a throw from a placement.
    public var minimumSampleCount: Int = 3

    /// Quiet period, in seconds, after the newest wheel sample before the
    /// glide launches. Must outlast the gap between two notches of the same
    /// burst, or every burst turns into several glides fighting each other.
    public var idleWindow: TimeInterval = 0.09

    /// Age limit, in seconds, of samples contributing to the launch velocity.
    public var trackingWindow: TimeInterval = 0.1

    /// How long the newest sample keeps describing the gesture, in seconds.
    ///
    /// A drag lets go whenever the user lets go, so silence is not a signal on
    /// its own: holding a thumb still for a while and *then* releasing must not
    /// fling, while the wheel — whose samples always stop `idleWindow` before
    /// the release is noticed — must. Anything quiet for this long was released
    /// earlier. Sits comfortably clear of `idleWindow` on purpose.
    public var staleWindow: TimeInterval = 0.25

    public init(isEnabled: Bool = true,
                deceleration: Float = 4.2,
                minimumVelocity: Float = 50,
                restVelocity: Float = 2,
                maximumVelocity: Float = 1_100,
                minimumSampleCount: Int = 3,
                idleWindow: TimeInterval = 0.09,
                trackingWindow: TimeInterval = 0.1,
                staleWindow: TimeInterval = 0.25) {
        self.isEnabled = isEnabled
        self.deceleration = deceleration
        self.minimumVelocity = minimumVelocity
        self.restVelocity = restVelocity
        self.maximumVelocity = maximumVelocity
        self.minimumSampleCount = minimumSampleCount
        self.idleWindow = idleWindow
        self.trackingWindow = trackingWindow
        self.staleWindow = staleWindow
    }
}

/// How a scrollable container reacts to input that pushes it past its bounds.
///
/// Split into independent groups because they answer different questions: how
/// far content *stretches* while being pushed, how it *returns* once released,
/// and how long it keeps *coasting* once input stops. Reusable outside
/// `ScrollView` — any component that owns a scrollable offset can share one
/// instance.
public struct ScrollPhysics: Sendable, Equatable {
    public var rubberBand: ScrollRubberBandSettings
    public var settle: ScrollSettleSettings
    public var momentum: ScrollMomentumSettings

    public init(rubberBand: ScrollRubberBandSettings = .init(),
                settle: ScrollSettleSettings = .init(),
                momentum: ScrollMomentumSettings = .init()) {
        self.rubberBand = rubberBand
        self.settle = settle
        self.momentum = momentum
    }
}

public extension ScrollPhysics {
    /// Default physics for custom gestures: rubber band, critically damped
    /// return and momentum. Platform scrolling always follows direct input.
    static let `default` = ScrollPhysics()

    /// Hard clamping at both bounds: content stops dead instead of stretching.
    /// Momentum still carries it there; the coast just ends at the edge.
    /// Opt-in for surfaces where any overshoot reads as a bug (canvas rulers,
    /// scroll-linked timelines).
    static let clamped = ScrollPhysics(rubberBand: ScrollRubberBandSettings(isEnabled: false))

    /// Stretch plus a visible bounce at the bound on release.
    static let bouncy = ScrollPhysics(
        settle: ScrollSettleSettings(response: 0.42, dampingFraction: 0.62)
    )

    /// Stiff early curve, slow return, no bounce.
    /// Useful for lists where the top edge is anchored to a header.
    static let firm = ScrollPhysics(
        rubberBand: ScrollRubberBandSettings(compliance: 0.25),
        settle: ScrollSettleSettings(response: 0.5)
    )

    /// Nothing that was not asked for: every wheel notch lands where it lands
    /// and the content stays there. For stepper-like surfaces where both
    /// coasting and stretching read as lost control (numeric scrubbers,
    /// frame-accurate timelines).
    static let precise = ScrollPhysics(
        rubberBand: ScrollRubberBandSettings(isEnabled: false),
        momentum: ScrollMomentumSettings(isEnabled: false)
    )
}
