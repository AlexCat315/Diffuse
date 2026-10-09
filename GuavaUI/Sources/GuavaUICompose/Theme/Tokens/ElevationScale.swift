import GuavaUIRuntime

/// A single drop shadow specification. The Phase 7 renderer does not yet
/// emit blurred shadows; until then `DrawList` may downgrade these to a
/// 1px border. The token shape is forward-compatible.
public struct Shadow: Sendable {
    public var color: Color
    public var offsetX: Float
    public var offsetY: Float
    public var blur: Float

    public init(color: Color, offsetX: Float, offsetY: Float, blur: Float) {
        self.color = color
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.blur = blur
    }

    public static let none = Shadow(color: .clear, offsetX: 0, offsetY: 0, blur: 0)
}

/// Four-step elevation scale matching common surface tiers in tooling UI:
/// no shadow, panel edge, floating popover, and dragged / context-menu.
public struct ElevationScale: Sendable {
    public var none: Shadow
    public var low: Shadow
    public var medium: Shadow
    public var high: Shadow

    public init(none: Shadow, low: Shadow, medium: Shadow, high: Shadow) {
        self.none = none
        self.low = low
        self.medium = medium
        self.high = high
    }
}
