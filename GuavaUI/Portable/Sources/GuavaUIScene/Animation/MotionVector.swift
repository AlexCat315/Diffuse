/// A displacement represented using ordinary interpolatable values. This keeps
/// velocity componentwise without requiring callers to adopt a vector protocol.
struct MotionVector<Value: Interpolatable> {
    let from: Value
    let to: Value
    let rate: Float

    func adding(to base: Value, seconds: Float) -> Value {
        let displaced = Value.interpolate(from, to, t: rate * seconds)
        let midpoint = Value.interpolate(base, displaced, t: 0.5)
        return Value.interpolate(from, midpoint, t: 2)
    }
}
