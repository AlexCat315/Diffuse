import Foundation
import GuavaUICore
import GuavaUISharedDemo
import GuavaUIText

/// Android system faces use the same FreeType, HarfBuzz and atlas as other hosts.
final class DemoTypography {
    struct Statistics: Codable {
        var fonts = 0
        var glyphs = 0
        var missingGlyphs = 0
        var atlasPixels = 0
    }
    let fonts = FontCollection()
    private(set) var statistics = Statistics()

    init() throws {
        for path in ["/system/fonts/Roboto-Regular.ttf", "/system/fonts/NotoSansCJK-Regular.ttc"] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            _ = fonts.append(bytes: Array(data))
        }
        guard fonts.fontCount > 0 else { throw CocoaError(.fileReadNoSuchFile) }
    }

    func beginFrame() { statistics = Statistics(fonts: fonts.fontCount) }

    func paint(_ text: DemoText, into list: DrawList, origin: CGPoint, scale: Float) {
        fonts.configure(size: text.size, rasterScale: scale)
        let glyphs = fonts.shape(text.text)
        statistics.glyphs += glyphs.count
        statistics.missingGlyphs += glyphs.filter { $0.glyphID == 0 }.count
        fonts.draw(text.text, size: text.size, rasterScale: scale, into: list,
                   x: Float(origin.x) + text.inset, y: Float(origin.y) + (text.inset > 0 ? 10 : 2), color: text.color)
    }

    func finishFrame() {
        statistics.atlasPixels = fonts.atlas.atlasData.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
    }
}
