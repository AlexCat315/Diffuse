internal import GuavaUICompose
internal import GuavaUIRuntime

/// Size of one grid cell for a monospaced font, measured with the host's
/// shaper so painting and hit testing agree with the rasterised glyphs.
struct CellMetrics: Equatable {
    var font: Font
    var width: Float
    var height: Float

    init(font: Font, environment: TextEnvironment) {
        self.font = font
        let sample = environment.cachedLayout(text: "MMMMMMMMMM", font: font)
        let advance = sample.totalWidth / 10
        width = advance.isFinite && advance > 0 ? advance : font.size * 0.6
        let lineHeight = environment.resolvedLineHeight(font: font, override: nil)
        height = (lineHeight.isFinite && lineHeight > 0 ? lineHeight : font.size * 1.3).rounded(.up)
    }

    /// Whole cells that fit in `width` × `height` points (at least 1 × 1).
    func grid(width: Float, height: Float) -> (columns: Int, rows: Int) {
        (max(1, Int((width / self.width).rounded(.down))), max(1, Int((height / self.height).rounded(.down))))
    }
}
