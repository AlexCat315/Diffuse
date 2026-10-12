#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if os(Android)
import Android
#endif
import Foundation

/// An axis changes from glide to spring at the time it reaches its edge,
/// independently of the other axis. Positions are raw; springs are visible.
struct ScrollAxisMotion {
    var glide: Float?
    var spring: ScrollSpring?

    mutating func stop() { glide = nil; spring = nil }

    mutating func advance(position: CGFloat, offset: CGFloat, maximum: CGFloat,
                          extent: CGFloat, physics: ScrollPhysics, duration: Float) -> (CGFloat, CGFloat) {
        if var spring {
            spring.advance(deltaTime: duration)
            self.spring = spring.isAtRest ? nil : spring
            let visible = CGFloat(spring.value)
            let excess = RubberBand.excess(of: spring.value, maximum: Float(maximum))
            let raw = excess == 0 ? visible : CGFloat((excess < 0 ? 0 : Float(maximum))
                + RubberBand.unproject(visibleOverscroll: excess, extent: Float(extent),
                                       compliance: physics.rubberBand.compliance))
            return (raw, visible)
        }
        guard let speed = glide else { return (position, offset) }
        let rate = max(0.1, physics.momentum.deceleration)
        let floor = max(0.01, physics.momentum.restVelocity)
        let restTime = max(0, log(max(floor, abs(speed)) / floor) / rate)
        let step = min(duration, restTime)
        let travel = -expm1(-rate * step) / rate
        let next = position + CGFloat(speed * travel)
        let edge: CGFloat = speed < 0 ? 0 : maximum
        if (speed < 0 && next <= 0) || (speed > 0 && next >= maximum) {
            let fraction = Float(edge - position) * rate / speed
            let hitTime = -log(max(0.000001, 1 - fraction)) / rate
            glide = nil
            guard physics.rubberBand.isEnabled else { return (edge, edge) }
            spring = ScrollSpring(value: Float(edge), velocity: speed * exp(-rate * hitTime),
                                  target: Float(edge), settings: physics.settle)
            return advance(position: edge, offset: edge, maximum: maximum, extent: extent,
                           physics: physics, duration: max(0, duration - hitTime))
        }
        glide = duration >= restTime ? nil : speed * exp(-rate * duration)
        return (next, next)
    }
}
