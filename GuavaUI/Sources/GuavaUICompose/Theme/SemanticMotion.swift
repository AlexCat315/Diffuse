import GuavaUIRuntime
import Foundation

/// Late-bound animation reference resolved against the active `Theme`.
///
/// Mirrors `SemanticColorRef` / `SemanticFontRef`: callers write
/// `Animation.semantic(.fast)` instead of hard-coding a duration so theme
/// swaps (or accessibility "reduce motion" passes in the future) can rescale
/// every animation in one place.
public struct SemanticMotionRef: Sendable {
    let resolve: @Sendable (Theme) -> Animation
    public init(_ resolve: @escaping @Sendable (Theme) -> Animation) {
        self.resolve = resolve
    }
}

public extension SemanticMotionRef {
    /// 100 ms in the default themes — micro-interactions, hover/press.
    static let fast = SemanticMotionRef { theme in
        Animation(duration: theme.motion.fast.seconds,
                  curve: theme.motion.standardEasing.asAnimationCurve)
    }

    /// 200 ms in the default themes — surface state changes, default choice.
    static let medium = SemanticMotionRef { theme in
        Animation(duration: theme.motion.standard.seconds,
                  curve: theme.motion.standardEasing.asAnimationCurve)
    }

    /// 320 ms in the default themes — emphasized motion (theme swap, modal
    /// presentation).
    static let slow = SemanticMotionRef { theme in
        Animation(duration: theme.motion.slow.seconds,
                  curve: theme.motion.emphasized.asAnimationCurve)
    }
}

public extension Animation {
    /// Resolve a semantic motion reference against the supplied theme.
    /// Compose-side modifier helpers will call this with the receiver node's
    /// resolved theme; callers who already have a `Theme` value (tests,
    /// non-View code) can use it directly.
    static func semantic(_ ref: SemanticMotionRef, in theme: Theme = .defaultDark) -> Animation {
        ref.resolve(theme)
    }
}

// MARK: - Bridges from Phase 7.5 token types

extension Duration {
    /// Total seconds, double-precision. Acceptable for animation timing where
    /// the wall-clock granularity is well below a frame.
    var seconds: Double {
        let comps = self.components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1e18
    }
}

extension Easing {
    /// Convert the Phase 7.5 cubic-bezier descriptor into a runtime
    /// `AnimationCurve`. The runtime evaluator solves `y(x)` via Newton +
    /// bisection.
    var asAnimationCurve: AnimationCurve {
        .cubicBezier(c1x, c1y, c2x, c2y)
    }
}
