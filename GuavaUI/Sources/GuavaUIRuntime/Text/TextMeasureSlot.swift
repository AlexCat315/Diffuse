import Foundation

/// Phase 6: typed measure slot for text-bearing layout nodes.
///
/// Before Phase 6 the per-`LayoutNode` text measure cache lived in two
/// separate places:
///   1. `LayoutTree.textMeasureCache` — an NSMapTable keyed by LayoutNode.
///   2. `LayoutNode.attachments["__text_measure_inputs"]` — a stringly-keyed
///      side table holding `TextMeasureInputs`.
///
/// Both were needed because the cache types lived in `GuavaUICompose` while
/// `LayoutNode` lives in Runtime. Phase 6 lifts the small shared types into
/// Runtime so the cache can be a typed stored property on `LayoutNode`,
/// removing one level of indirection and one Objective-C bridge.

/// Inputs to text shaping/layout that we use to detect "the measurement
/// would change" between recompose passes (so we know when to mark the
/// LayoutNode dirty).
public struct TextMeasureInputs: Equatable {
    public let text: String
    public let alignment: TextAlignment

    public init(text: String, alignment: TextAlignment) {
        self.text = text
        self.alignment = alignment
    }
}

/// Cache key covering every input that can change a `TextLayoutResult`.
public struct TextLayoutCacheKey: Hashable {
    public let text: String
    public let font: Font
    public let lineHeight: Float
    public let alignment: TextAlignment
    public let maxWidth: Float
    public let atlasID: ObjectIdentifier

    public init(text: String,
                font: Font,
                lineHeight: Float,
                alignment: TextAlignment,
                maxWidth: Float,
                atlasID: ObjectIdentifier) {
        self.text = text
        self.font = font
        self.lineHeight = lineHeight
        self.alignment = alignment
        self.maxWidth = maxWidth
        self.atlasID = atlasID
    }
}

/// Cached pair of `(key, result)` stored on a `LayoutNode`.
public struct TextLayoutCacheEntry {
    public let key: TextLayoutCacheKey
    public let result: TextLayoutResult

    public init(key: TextLayoutCacheKey, result: TextLayoutResult) {
        self.key = key
        self.result = result
    }
}
