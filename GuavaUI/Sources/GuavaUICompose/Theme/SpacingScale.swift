/// Six-step linear spacing scale in logical pixels. Components compose
/// padding, gap and inset using these tokens so themes can rescale density
/// (e.g. a “compact” theme halves every value) without touching call sites.
public struct SpacingScale: Sendable {
    public var xs: Float
    public var sm: Float
    public var md: Float
    public var lg: Float
    public var xl: Float
    public var xxl: Float

    public init(xs: Float, sm: Float, md: Float, lg: Float, xl: Float, xxl: Float) {
        self.xs = xs
        self.sm = sm
        self.md = md
        self.lg = lg
        self.xl = xl
        self.xxl = xxl
    }
}
