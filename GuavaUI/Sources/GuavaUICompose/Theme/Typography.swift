import GuavaUIRuntime

/// One typography slot — pairs a `Font` with the line-height and letter
/// spacing that should travel with it. Components consume the entire token
/// rather than just `font` so vertical rhythm stays stable across themes.
public struct TextStyleToken: Sendable {
    public var font: Font
    public var lineHeight: Float
    public var letterSpacing: Float

    public init(font: Font, lineHeight: Float, letterSpacing: Float = 0) {
        self.font = font
        self.lineHeight = lineHeight
        self.letterSpacing = letterSpacing
    }
}

/// Type scale slots covering display through caption plus a monospace slot
/// for consoles and code listings. Slot names describe role, not size.
public struct Typography: Sendable {
    public var display: TextStyleToken
    public var title: TextStyleToken
    public var headline: TextStyleToken
    public var body: TextStyleToken
    public var bodyStrong: TextStyleToken
    public var caption: TextStyleToken
    public var label: TextStyleToken
    public var mono: TextStyleToken

    public init(display: TextStyleToken,
                title: TextStyleToken,
                headline: TextStyleToken,
                body: TextStyleToken,
                bodyStrong: TextStyleToken,
                caption: TextStyleToken,
                label: TextStyleToken,
                mono: TextStyleToken) {
        self.display = display
        self.title = title
        self.headline = headline
        self.body = body
        self.bodyStrong = bodyStrong
        self.caption = caption
        self.label = label
        self.mono = mono
    }
}
