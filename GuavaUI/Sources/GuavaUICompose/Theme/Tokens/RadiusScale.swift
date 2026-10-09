/// Corner-radius scale in logical pixels. `pill` is large enough to fully
/// round any reasonable control height, used by chip / pill buttons.
public struct RadiusScale: Sendable {
    public var none: Float
    public var sm: Float
    public var md: Float
    public var lg: Float
    public var xl: Float
    public var pill: Float

    public init(none: Float, sm: Float, md: Float, lg: Float, xl: Float, pill: Float) {
        self.none = none
        self.sm = sm
        self.md = md
        self.lg = lg
        self.xl = xl
        self.pill = pill
    }
}
