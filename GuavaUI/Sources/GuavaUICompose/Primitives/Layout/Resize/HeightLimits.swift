struct EditorHeightLimits: Equatable {
    let minimum: Float
    let maximum: Float

    init(minimum: Float, maximum: Float) {
        self.minimum = minimum.isFinite ? max(0, minimum) : 96
        self.maximum = maximum.isFinite ? max(self.minimum, maximum) : max(self.minimum, 520)
    }

    func clamp(_ value: Float) -> Float {
        min(maximum, max(minimum, value.isFinite ? value : minimum))
    }
}
