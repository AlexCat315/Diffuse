public import Foundation
public import GuavaUIRuntime

/// Composable lifecycle effects. Use with AnimatedVisibility so removal retains
/// the subtree until completion. Insertion and removal may use different effects.
public struct Transition: Equatable, Sendable {
    public enum Edge: Sendable { case top, bottom, leading, trailing }
    struct Effect: Equatable, Sendable {
        var opacity: Float = 1
        var x: Float = 0
        var y: Float = 0
        /// Scale the subtree runs through, and the point it runs about. Carried
        /// as a `NodeTransform` rather than a bare factor so the anchor travels
        /// with the scale instead of being re-derived at each apply site.
        var scale = NodeTransform.identity
        var collapse = false
        func combined(_ other: Effect) -> Effect {
            precondition(scale.isIdentity || other.scale.isIdentity || scale.anchor == other.scale.anchor,
                         "Combine scales with the same anchor; use nested AnimatedVisibility for different anchors")
            let combinedScale: NodeTransform
            if scale.isIdentity { combinedScale = other.scale }
            else if other.scale.isIdentity { combinedScale = scale }
            else {
                combinedScale = NodeTransform(scale: scale.scale * other.scale.scale,
                                              anchor: scale.anchor, scalesShadow: false)
            }
            return Effect(opacity: opacity * other.opacity, x: x + other.x, y: y + other.y,
                          scale: combinedScale,
                          collapse: collapse || other.collapse)
        }
        /// Interpolates every continuous field from `self` toward `goal`.
        ///
        /// `collapse` is a flag rather than a value and so is not interpolated;
        /// Keep the active anchor when either end is identity. For interrupted
        /// asymmetric effects with different active anchors, interpolate the
        /// anchor as well so reversal does not jump to a different origin.
        func interpolating(to goal: Effect, _ amount: Float) -> Effect {
            if amount == 0 { return self }
            if amount == 1 { return goal }
            let anchor: CGPoint
            if goal.scale.isIdentity { anchor = scale.anchor }
            else if scale.isIdentity { anchor = goal.scale.anchor }
            else {
                anchor = CGPoint(x: scale.anchor.x + (goal.scale.anchor.x - scale.anchor.x) * CGFloat(amount),
                                 y: scale.anchor.y + (goal.scale.anchor.y - scale.anchor.y) * CGFloat(amount))
            }
            return Effect(opacity: opacity + (goal.opacity - opacity) * amount,
                   x: x + (goal.x - x) * amount,
                   y: y + (goal.y - y) * amount,
                   scale: NodeTransform(
                       scale: scale.scale + (goal.scale.scale - scale.scale) * amount,
                       anchor: anchor, scalesShadow: false),
                   collapse: goal.collapse)
        }
    }
    var insertion: Effect
    var removal: Effect
    private init(_ effect: Effect) { insertion = effect; removal = effect }
    public static let identity = Transition(Effect())
    public static let opacity = Transition(Effect(opacity: 0))
    public static let collapse = Transition(Effect(collapse: true))
    public static func offset(x: CGFloat = 0, y: CGFloat = 0) -> Transition {
        Transition(Effect(x: Float(x), y: Float(y)))
    }
    public static func move(edge: Edge, distance: Float = 16) -> Transition {
        let d = distance.isFinite ? distance : 0
        switch edge {
        case .top: return Transition(Effect(y: -d))
        case .bottom: return Transition(Effect(y: d))
        case .leading: return Transition(Effect(x: -d))
        case .trailing: return Transition(Effect(x: d))
        }
    }
    /// Grows or shrinks the subtree about a normalized point in its own frame,
    /// `(0, 0)` being the top-left corner and `(0.5, 0.5)` the centre.
    ///
    /// Shadow offsets and blur retain their authored size during the transition.
    /// Combined scale transitions must share an anchor; use nested visibility
    /// containers for independent anchors.
    /// Nonfinite factors resolve to 1; negative factors resolve to 0.
    public static func scale(from factor: CGFloat, anchor: CGPoint) -> Transition {
        let value = Float(factor)
        let safeAnchor = CGPoint(x: anchor.x.isFinite ? anchor.x : 0, y: anchor.y.isFinite ? anchor.y : 0)
        return Transition(Effect(scale: NodeTransform(scale: value.isFinite ? max(0, value) : 1,
                                                      anchor: safeAnchor, scalesShadow: false)))
    }
    public func combined(with other: Transition) -> Transition {
        var result = self
        result.insertion = insertion.combined(other.insertion)
        result.removal = removal.combined(other.removal)
        return result
    }
    public static func asymmetric(insertion: Transition, removal: Transition) -> Transition {
        var result = insertion; result.removal = removal.removal; return result
    }
}
