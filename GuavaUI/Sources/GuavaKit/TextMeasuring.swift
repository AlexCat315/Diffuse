// Text measurement is a *pluggable* dependency, not baked in. GuavaKit ships a
// monospace approximation so it works standalone (and in tests); the editor host
// injects a real implementation backed by the font atlas. Either way `Text` only
// talks to this protocol, so swapping in real metrics touches nothing else.

public protocol TextMeasuring {
    /// Pixel size of `string` rendered at `fontSize`.
    func measure(_ string: String, fontSize: Float) -> Size
}

/// Standalone fallback: assumes a monospace cell of `0.5×1.2 · fontSize`.
public struct ApproxTextMeasurer: TextMeasuring {
    public init() {}
    public func measure(_ string: String, fontSize: Float) -> Size {
        Size(width: Float(string.count) * fontSize * 0.5, height: fontSize * 1.2)
    }
}
