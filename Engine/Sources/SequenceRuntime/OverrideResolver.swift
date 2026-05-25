import Foundation

public struct ResolvedOverride: Sendable, Equatable {
    public var override: ShotOverride
    public var weight: Double

    public init(override: ShotOverride, weight: Double) {
        self.override = override
        self.weight = weight
    }
}

public enum OverrideResolver {
    /// Returns all active overrides for `shot` at `sequenceFrame`, with blend weights applied.
    /// Overrides are returned in document order; callers resolve priority by consuming in order
    /// (absolute first, then additive/multiplicative on top).
    public static func activeOverrides(in shot: Shot,
                                       at sequenceFrame: Int64) -> [ResolvedOverride] {
        guard shot.range.contains(sequenceFrame) else { return [] }
        let localPosition = sequenceFrame - shot.range.start
        let shotDuration = shot.range.duration
        return shot.overrides.compactMap { override in
            let w = blendWeight(localPosition: localPosition,
                                shotDuration: shotDuration,
                                blendIn: override.blendInFrames,
                                blendOut: override.blendOutFrames,
                                ease: override.ease)
            guard w > 0 else { return nil }
            return ResolvedOverride(override: override, weight: w)
        }
    }

    // MARK: - Private

    private static func blendWeight(localPosition: Int64,
                                    shotDuration: Int64,
                                    blendIn: Int64,
                                    blendOut: Int64,
                                    ease: ClipEase) -> Double {
        var weight = 1.0
        if blendIn > 0 {
            let t = min(1.0, max(0.0, Double(localPosition) / Double(blendIn)))
            weight = min(weight, applyEase(t, ease: ease))
        }
        if blendOut > 0 {
            let remaining = max(0, shotDuration - localPosition)
            let t = min(1.0, max(0.0, Double(remaining) / Double(blendOut)))
            weight = min(weight, applyEase(t, ease: ease))
        }
        return weight
    }

    private static func applyEase(_ t: Double, ease: ClipEase) -> Double {
        switch ease {
        case .linear:
            return t
        case .easeIn:
            return t * t
        case .easeOut:
            return 1.0 - (1.0 - t) * (1.0 - t)
        case .easeInOut:
            return t < 0.5 ? 2.0 * t * t : 1.0 - 2.0 * (1.0 - t) * (1.0 - t)
        case .step:
            return t >= 1.0 ? 1.0 : 0.0
        }
    }
}
