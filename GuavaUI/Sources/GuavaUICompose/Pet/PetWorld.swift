//
//  PetWorld.swift
//  GuavaUI · Software Pet
//
//  Layer 2/3 — the brain + the clock.
//
//  The world owns the pet's situation and drives ONE continuous timeline.
//  Transitions are NOT discrete timers: every frame evaluates the current
//  timeline (entrance / jump / perched) at its elapsed time. Phase boundaries
//  are crossed by the evaluation itself, so nothing can drift or desync.
//
//  It is BOTH:
//  • an `_ObservableObject` (the view observes `render`), and
//  • an `AnyAnimationController` (the host's AnimatorScheduler ticks it).
//

import Foundation
#if os(Android)
import Android
#endif
import GuavaUICore
import GuavaUIScene
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public final class PetWorld: _ObservableObject, AnyAnimationController {

    // MARK: Configuration

    public let spriteSheet: PetSpriteSheet
    /// Horizontal travel speed, points per second (drives jump duration).
    public var travelSpeed: Double = 430
    /// Minimum jump duration (s).
    public var minJumpDuration: Double = 0.58

    // MARK: Situation

    /// Registered perch frames (window space), keyed by anchor id.
    public private(set) var anchors: [String: CGRect] = [:]
    /// The anchor the pet currently rests on / travels from.
    public private(set) var currentAnchorID: String
    /// Resting silhouette when perched.
    public private(set) var perchPose: PetPose = .idle

    // MARK: Timelines

    private struct Entrance: Sendable {
        let anchorID: String
        let duration: Double
    }
    private var entrance: Entrance?
    private var entranceElapsed: Double = 0
    private var hasEntered = false

    private var trip: PetTrip?
    private var tripElapsed: Double = 0

    /// The single value the view renders. Recomputed each tick.
    public private(set) var render: PetRenderState

    // MARK: Clock state (AnyAnimationController)

    public var isFinished: Bool = true

    // MARK: Observation (_ObservableObject)

    private let publisher = _ObservablePublisher<PetWorld>()

    public func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable {
        publisher.register(on: self, handler: handler)
    }

    public func _unregisterObserver(_ token: AnyHashable) {
        publisher.unregister(token)
    }

    // MARK: Init

    public init(spriteSheet: PetSpriteSheet, initialAnchorID: String, perchPose: PetPose = .idle) {
        self.spriteSheet = spriteSheet
        self.currentAnchorID = initialAnchorID
        self.perchPose = perchPose
        self.render = PetRenderState(position: .zero, pose: perchPose,
                                    scaleX: 1, scaleY: 1, facing: 1, presence: 0)
    }

    // MARK: - Public intents (the "brain")

    /// Jump to another anchor. No-op if the target is unknown / identical /
    /// not yet laid out.
    @discardableResult
    public func go(to targetID: String) -> Bool {
        guard !isBusy, targetID != currentAnchorID else { return false }
        guard let start = perchPoint(for: currentAnchorID),
              let end = perchPoint(for: targetID) else { return false }

        let dx = Float(end.x - start.x)
        let dy = Float(end.y - start.y)
        let distance = max(1, hypot(dx, dy))
        let peak = max(64, distance * 0.34 + abs(dy) * 0.15)
        let facing: Float = dx >= 0 ? 1 : -1
        let duration = max(minJumpDuration, Double(distance) / travelSpeed)

        let arc = JumpArc(start: start, end: end, peakHeight: peak)
        let t = PetTrip(fromAnchor: currentAnchorID, toAnchor: targetID,
                        arc: arc, totalDuration: duration, facing: facing)
        trip = t
        tripElapsed = 0
        startClock()
        return true
    }

    /// Toggle the resting silhouette between standing and sitting.
    public func toggleRest() {
        guard !isBusy else { return }
        perchPose = (perchPose == .sit) ? .idle : .sit
        render.pose = perchPose
        publisher.send()
    }

    /// Pick a random other anchor and jump there. Returns the chosen id.
    @discardableResult
    public func wander() -> String? {
        let candidates = anchors.keys.filter { $0 != currentAnchorID }
        guard let target = candidates.randomElement() else { return nil }
        return go(to: target) ? target : nil
    }

    /// True while the pet is mid-entrance or mid-jump.
    public var isBusy: Bool { trip != nil || entrance != nil }

    // MARK: - Anchor registration (called by PetAnchor after layout)

    public func updateAnchor(id: String, frame: CGRect) {
        let changed = anchors[id] != frame
        anchors[id] = frame

        // First time the initial anchor is laid out → begin entrance.
        if !hasEntered, id == currentAnchorID, frame != .zero {
            beginEntrance(at: id)
            return
        }

        // While perched, the pet is glued to its anchor: any reflow moves it.
        if !isBusy, id == currentAnchorID, changed,
           let point = perchPoint(for: id) {
            render.position = point
            publisher.send()
        }
    }

    public func removeAnchor(id: String) {
        anchors[id] = nil
    }

    // MARK: - Clock

    private func startClock() {
        if isFinished {
            isFinished = false
            AnimatorScheduler.current.register(self)
        }
    }

    private func stopClockIfIdle() {
        guard !isBusy else { return }
        isFinished = true
    }

    // MARK: - Tick (evaluates the active timeline)

    public func tick(deltaTime: Double) {
        var changed = false

        if let e = entrance {
            entranceElapsed += deltaTime
            let nt = Float(entranceElapsed / e.duration)
            if nt >= 1 {
                finishEntrance(e)
            } else {
                render = PetWorld.evaluate(entrance: e, normalizedTime: nt,
                                           point: perchPoint(for: e.anchorID) ?? render.position,
                                           pose: perchPose)
            }
            changed = true
        } else if let t = trip {
            tripElapsed += deltaTime
            let nt = Float(tripElapsed / t.totalDuration)
            if nt >= 1 {
                finishTrip(t)
            } else {
                render = PetWorld.evaluate(trip: t, normalizedTime: nt)
            }
            changed = true
        }

        if changed { publisher.send() }
        stopClockIfIdle()
    }

    public func finishImmediately() {
        if let e = entrance { finishEntrance(e) }
        if let t = trip { finishTrip(t) }
        publisher.send()
    }

    public func cancel() {
        entrance = nil
        trip = nil
        stopClockIfIdle()
    }

    // MARK: - Timeline completion

    private func beginEntrance(at anchorID: String) {
        hasEntered = true
        let e = Entrance(anchorID: anchorID, duration: 0.6)
        entrance = e
        entranceElapsed = 0
        render.pose = perchPose
        startClock()
    }

    private func finishEntrance(_ e: Entrance) {
        entrance = nil
        if let point = perchPoint(for: e.anchorID) {
            render.position = point
        }
        render.scaleX = 1
        render.scaleY = 1
        render.presence = 1
        render.pose = perchPose
    }

    private func finishTrip(_ t: PetTrip) {
        trip = nil
        currentAnchorID = t.toAnchor
        // Land, then settle into a seated rest.
        perchPose = .sit
        render.pose = .sit
        render.scaleX = 1
        render.scaleY = 1
        render.facing = t.facing
        render.presence = 1
        if let point = perchPoint(for: t.toAnchor) {
            render.position = point
        }
    }

    // MARK: - Geometry

    private func perchPoint(for anchorID: String) -> CGPoint? {
        guard let frame = anchors[anchorID] else { return nil }
        return CGPoint(x: frame.midX, y: frame.minY)
    }

    // MARK: - Evaluation (pure functions)

    private static func evaluate(entrance e: Entrance, normalizedTime nt: Float,
                                 point: CGPoint, pose: PetPose) -> PetRenderState {
        let s = clamp01(nt)
        // Pop in: 0.3 → 1 with a single overshoot.
        let envelope = exp(-6 * s) * cos(9 * s)
        let scale = 1 - 0.7 * envelope
        let presence = clamp01((s - 0.05) / 0.25)
        return PetRenderState(position: point, pose: pose,
                              scaleX: scale, scaleY: scale,
                              facing: 1, presence: presence)
    }

    private static func evaluate(trip t: PetTrip, normalizedTime nt: Float) -> PetRenderState {
        let s = clamp01(nt)
        let arc = t.arc

        // Windup — crouch in place.
        if s < PetTrip.windupEnd {
            let w = clamp01(s / PetTrip.windupEnd)
            let eased = AnimationCurve.easeIn.evaluate(w)
            let sx = 1 + 0.26 * eased
            let sy = 1 - 0.26 * eased
            return PetRenderState(position: arc.start, pose: .windup,
                                  scaleX: sx, scaleY: sy,
                                  facing: t.facing, presence: 1)
        }

        // Airborne — ballistic position + velocity-driven stretch.
        if s < PetTrip.airborneEnd {
            let u = t.airProgress(at: s) ?? 1
            let point = arc.position(at: u)
            let vy = arc.verticalVelocity(at: u)
            // Normalise stretch against the max |vy| at launch/landing.
            let vyLaunch = arc.verticalVelocity(at: 0)
            let vyLand = arc.verticalVelocity(at: 1)
            let vyMax = max(abs(vyLaunch), abs(vyLand), 1)
            let stretch = clamp01(abs(vy) / vyMax)

            let sx = 1 - 0.10 * stretch
            let sy = 1 + 0.13 * stretch

            let pose: PetPose
            if vy < -0.18 * vyMax {      pose = .rise }
            else if vy > 0.18 * vyMax {  pose = .fall }
            else {                         pose = .apex }

            return PetRenderState(position: point, pose: pose,
                                  scaleX: sx, scaleY: sy,
                                  facing: t.facing, presence: 1)
        }

        // Contact — squash.
        if s < PetTrip.landEnd {
            let l = clamp01((s - PetTrip.airborneEnd)
                            / (PetTrip.landEnd - PetTrip.airborneEnd))
            // Quick impact then begin to release.
            let amount = 1 - 0.25 * AnimationCurve.easeOut.evaluate(l)
            let sx = 1 + 0.30 * amount
            let sy = 1 - 0.30 * amount
            return PetRenderState(position: arc.end, pose: .land,
                                  scaleX: sx, scaleY: sy,
                                  facing: t.facing, presence: 1)
        }

        // Settle — spring back from squash to neutral (with overshoot).
        let q = clamp01((s - PetTrip.landEnd) / (1 - PetTrip.landEnd))
        let envelope = exp(-5.5 * q) * cos(7.5 * q)
        let sx = 1 + 0.30 * envelope
        let sy = 1 - 0.30 * envelope
        return PetRenderState(position: arc.end, pose: .sit,
                              scaleX: sx, scaleY: sy,
                              facing: t.facing, presence: 1)
    }
}
