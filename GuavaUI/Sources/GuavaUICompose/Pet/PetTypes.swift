//
//  PetTypes.swift
//  GuavaUI · Software Pet
//
//  Layer 1/2 — the declarative "what" (motion model + sprite table).
//
//  Design contract (see PetScene):
//  • Sprites describe ONLY the in-place silhouette ("what the body looks like").
//  • Translation is a programmatic parameter curve (JumpArc), never baked into
//    a frame — the same clips serve any distance / height.
//  • Final draw = world transform (translation · facing) × local pose
//    (frame · squash/stretch).
//

import Foundation
import GuavaUICore
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Pose

/// A named in-place silhouette. These are the ONLY things a sprite frame
/// encodes; they never carry a position.
public enum PetPose: String, Sendable, CaseIterable, Equatable {
    case idle      // standing, neutral
    case windup    // crouch before launch
    case rise      // launched, ascending
    case apex      // top of the arc, arms spread
    case fall      // descending
    case land      // contact / recovery
    case sit       // perched, seated
}

// MARK: - Sprite sheet

/// Maps a pose to a source image file. Kept as data so the pet core is
/// agnostic to any particular art pack — the demo supplies the files.
public struct PetSpriteSheet: Sendable, Equatable {
    /// On-screen edge length of the (square) sprite, in points.
    public var displaySize: Float
    /// Pose → absolute file path.
    public var frames: [PetPose: String]

    public init(displaySize: Float, frames: [PetPose: String]) {
        self.displaySize = displaySize
        self.frames = frames
    }

    public func path(for pose: PetPose) -> String? { frames[pose] }

    /// Fallback chain used when a pose has no dedicated frame.
    public func resolvedPath(for pose: PetPose) -> String? {
        if let p = frames[pose] { return p }
        for candidate in pose.fallbackChain {
            if let p = frames[candidate] { return p }
        }
        return nil
    }
}

private extension PetPose {
    var fallbackChain: [PetPose] {
        switch self {
        case .rise, .fall:   [.apex, .idle]
        case .windup:        [.sit, .idle]
        case .land:          [.sit, .idle]
        case .apex:          [.idle]
        case .idle, .sit:    [.idle]
        }
    }
}

// MARK: - Jump arc (programmatic motion)

/// A ballistic parabola in window space.
///
/// For air progress u ∈ [0,1]:
///   x(u) = start.x + (end.x − start.x)·u
///   y(u) = lerp(start.y,end.y,u) − 4·peakHeight·u·(1−u)
///
/// `peakHeight` is the EXTRA peak above the straight start→end chord (the
/// 4·u·(1−u) term is 0 at both ends and 1 at u=0.5), so a same-level jump
/// peaks exactly `peakHeight` points above the perch.
public struct JumpArc: Sendable, Equatable {
    public let start: CGPoint
    public let end: CGPoint
    public let peakHeight: Float

    public init(start: CGPoint, end: CGPoint, peakHeight: Float) {
        self.start = start
        self.end = end
        self.peakHeight = peakHeight
    }

    public func position(at u: Float) -> CGPoint {
        let u = clamp01(u)
        let sx = Float(start.x), sy = Float(start.y)
        let ex = Float(end.x),   ey = Float(end.y)
        let x = sx + (ex - sx) * u
        let y = sy + (ey - sy) * u - 4 * peakHeight * u * (1 - u)
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    /// Vertical velocity vs. air progress (dy/du). Negative = ascending
    /// (window y grows downward), positive = falling. Used to pick the
    /// rise/apex/fall silhouette from the SAME curve rather than timers.
    public func verticalVelocity(at u: Float) -> Float {
        let ey = Float(end.y), sy = Float(start.y)
        return (ey - sy) - 4 * peakHeight * (1 - 2 * u)
    }
}

// MARK: - Trip (one continuous timeline)

/// A single "from one perch to another" journey. The whole body of the jump
/// is a deterministic evaluation of `elapsed` over this timeline — there are
/// no discrete per-phase timers to drift or desync.
public struct PetTrip: Sendable, Equatable {
    public let fromAnchor: String
    public let toAnchor: String
    public let arc: JumpArc
    public let totalDuration: Double
    public let facing: Float

    // Normalised phase boundaries (fractions of totalDuration).
    public static let windupEnd:   Float = 0.16
    public static let airborneEnd: Float = 0.72
    public static let landEnd:     Float = 0.84
    // 0.84 → 1.0 is the settle (spring back to seated).

    public init(fromAnchor: String, toAnchor: String, arc: JumpArc,
                totalDuration: Double, facing: Float) {
        self.fromAnchor = fromAnchor
        self.toAnchor = toAnchor
        self.arc = arc
        self.totalDuration = totalDuration
        self.facing = facing
    }

    /// Air progress u ∈ [0,1] while in the airborne band; nil otherwise.
    public func airProgress(at t: Float) -> Float? {
        guard t >= Self.windupEnd, t <= Self.airborneEnd else { return nil }
        let span = Self.airborneEnd - Self.windupEnd
        return clamp01((t - Self.windupEnd) / span)
    }
}

// MARK: - Render state (the only thing the view consumes)

/// Per-frame evaluation of the pet, already in window space. The view is a
/// pure function of this value.
public struct PetRenderState: Sendable, Equatable {
    /// Foot anchor (window space).
    public var position: CGPoint
    public var pose: PetPose
    public var scaleX: Float
    public var scaleY: Float
    /// 1 = facing right, −1 = facing left.
    public var facing: Float
    /// 0 at spawn → 1 once fully present (entrance).
    public var presence: Float

    public init(position: CGPoint, pose: PetPose, scaleX: Float, scaleY: Float,
                facing: Float, presence: Float) {
        self.position = position
        self.pose = pose
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.facing = facing
        self.presence = presence
    }
}

// MARK: - Helpers

@inlinable
public func clamp01(_ v: Float) -> Float { min(1, max(0, v)) }

@inlinable
public func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
