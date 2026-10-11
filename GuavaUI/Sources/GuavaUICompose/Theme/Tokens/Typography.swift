import GuavaUIRuntime

/// One typography slot — pairs a `Font` with the line-height and letter
/// spacing that should travel with it. Components consume the entire token
/// rather than just `font` so vertical rhythm stays stable across themes.
public struct TextStyleToken: Equatable, Sendable {
    public var font: Font
    public var lineHeight: Float
    public var letterSpacing: Float

    public init(font: Font, lineHeight: Float, letterSpacing: Float = 0) {
        self.font = font
        self.lineHeight = lineHeight
        self.letterSpacing = letterSpacing
    }

    func resolvingFamily(_ family: String?) -> Self {
        var result = self
        result.font = font.resolvingFamily(family)
        return result
    }

    func value<T>(for key: String, fontOverride: Font? = nil) -> T? {
        switch key {
        case StyleAttachmentKey.font: return font as? T
        case StyleAttachmentKey.lineHeight:
            return (lineHeight * (fontOverride?.size ?? font.size) / font.size) as? T
        case StyleAttachmentKey.letterSpacing: return letterSpacing as? T
        default: return nil
        }
    }
}

extension Font {
    func resolvingFamily(_ family: String?) -> Self {
        guard self.family == nil, design == .standard, let family else { return self }
        return .named(family, size: size, weight: weight)
    }
}

/// Type scale slots covering display through caption plus a monospace slot
/// for consoles and code listings. Slot names describe role, not size.
public struct Typography: Sendable {
    /// Applies to standard semantic roles unless a token names its own family.
    public var family: String? = nil
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
