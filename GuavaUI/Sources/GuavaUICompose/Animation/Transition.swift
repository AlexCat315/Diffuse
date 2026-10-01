import Foundation

/// Composable lifecycle effects. Use with AnimatedVisibility so removal retains
/// the subtree until completion. Insertion and removal may use different effects.
public struct Transition: Equatable, Sendable {
    public enum Edge: Sendable { case top, bottom, leading, trailing }
    struct Effect: Equatable, Sendable {
        var opacity: Float = 1
        var x: Float = 0
        var y: Float = 0
        var collapse = false
        func combined(_ other: Effect) -> Effect {
            Effect(opacity: opacity * other.opacity, x: x + other.x, y: y + other.y,
                   collapse: collapse || other.collapse)
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
