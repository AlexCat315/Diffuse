/// Inline presentation traits of one `RichTextRun`.
public struct RichTextTraits: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let bold = RichTextTraits(rawValue: 1 << 0)
    public static let italic = RichTextTraits(rawValue: 1 << 1)
    /// Monospaced type on a tinted chip, as for inline code.
    public static let code = RichTextTraits(rawValue: 1 << 2)
    public static let strikethrough = RichTextTraits(rawValue: 1 << 3)
}

/// One styled span of a `RichText` paragraph. Runs wrap together as a single
/// paragraph; a `"\n"` inside a run is a hard line break.
public struct RichTextRun: Hashable, Sendable {
    public var text: String
    public var traits: RichTextTraits
    /// The destination handed to `RichText`'s link handler. Adjacent runs
    /// with the same destination form one link.
    public var link: String?

    public init(_ text: String, traits: RichTextTraits = [], link: String? = nil) {
        self.text = text
        self.traits = traits
        self.link = link
    }
}
