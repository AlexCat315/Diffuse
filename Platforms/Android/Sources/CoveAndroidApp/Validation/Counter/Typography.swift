#if COVE_ANDROID_SHOWCASE
import Foundation
import CoveUICore
import CounterExample
import CoveUIText

/// Android system faces use the same FreeType, HarfBuzz and atlas as other hosts.
final class CounterTypography {
    let fonts = FontCollection()
    private(set) var statistics = TypographyStatistics()

    init() throws {
        for path in ["/system/fonts/Roboto-Regular.ttf", "/system/fonts/NotoSansCJK-Regular.ttc"] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            _ = fonts.append(bytes: Array(data))
        }
        guard fonts.fontCount > 0 else { throw CocoaError(.fileReadNoSuchFile) }
    }

    func beginFrame() {
        statistics.fonts = fonts.fontCount
        statistics.glyphs = 0
        statistics.missingGlyphs = 0
    }

    func paint(_ text: CounterTextRun, into list: DrawList, origin: CGPoint, scale: Float) {
        fonts.configure(size: text.size, rasterScale: scale)
        let glyphs = fonts.shape(text.text)
        statistics.glyphs += glyphs.count
        statistics.missingGlyphs += glyphs.filter { $0.glyphID == 0 }.count
        fonts.draw(text.text, size: text.size, rasterScale: scale, into: list,
                   x: Float(origin.x) + text.inset, y: Float(origin.y) + (text.inset > 0 ? 10 : 2), color: text.color)
    }

    /// Occupancy changes only when glyph pixels change. Keep the cached count
    /// across frames so input and diagnostic snapshots also remain cheap.
    func finishFrame() {
        guard fonts.atlas.isDirty else { return }
        statistics.atlasPixels = fonts.atlas.atlasData.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
    }
}

#endif
