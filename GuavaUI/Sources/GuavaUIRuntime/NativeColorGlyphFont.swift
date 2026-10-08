#if canImport(CoreText) && canImport(CoreGraphics)
import CoreText
import CoreGraphics
import Foundation

/// Native bitmap/color fonts use CoreText for both metrics and rasterization.
/// They share the same positioned-glyph layout as normal HarfBuzz runs.
final class NativeColorGlyphFont {
    private let logicalFont: CTFont
    let size: Float
    let rasterScale: Float
    init(font: CTFont, size: Float, rasterScale: Float) {
        logicalFont = CTFontCreateCopyWithAttributes(font, CGFloat(size), nil, nil)
        self.size = size; self.rasterScale = rasterScale
    }
    var source: ColorGlyphSource {
        ColorGlyphSource(size: size, rasterScale: rasterScale, metrics: metrics,
                         lineMetrics: lineMetrics, rasterize: rasterize)
    }
    private func bounds(_ index: UInt32) -> CGRect? {
        guard index <= UInt16.max else { return nil }
        var glyph = CGGlyph(index)
        let logicalBounds = CTFontGetBoundingRectsForGlyphs(logicalFont, .horizontal, &glyph, nil, 1)
        let bounds = logicalBounds.applying(CGAffineTransform(scaleX: CGFloat(rasterScale), y: CGFloat(rasterScale)))
        guard bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite,
              !bounds.isEmpty else { return nil }
        // One physical pixel of transparent padding protects filtered edges.
        return CGRect(x: floor(bounds.minX) - 1, y: floor(bounds.minY) - 1,
                      width: ceil(bounds.maxX) - floor(bounds.minX) + 2,
                      height: ceil(bounds.maxY) - floor(bounds.minY) + 2)
    }
    func metrics(_ index: UInt32) -> GlyphMetrics? {
        guard let bounds = bounds(index) else { return nil }
        var glyph = CGGlyph(index), advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(logicalFont, .horizontal, &glyph, &advance, 1)
        let scale = CGFloat(rasterScale)
        return GlyphMetrics(glyphIndex: index, width: Float(bounds.width / scale), height: Float(bounds.height / scale),
            bearingX: Float(bounds.minX / scale), bearingY: Float(bounds.maxY / scale), advance: Float(advance.width))
    }
    func lineMetrics() -> GlyphLineMetrics {
        let ascent = Float(CTFontGetAscent(logicalFont)), descent = Float(CTFontGetDescent(logicalFont))
        return .init(ascent: ascent, descent: descent, lineHeight: ascent + descent + Float(CTFontGetLeading(logicalFont)))
    }
    func rasterize(_ index: UInt32) -> ColorGlyphBitmap? {
        guard let bounds = bounds(index), let metrics = metrics(index), bounds.width <= 4_096, bounds.height <= 4_096 else { return nil }
        let width = Int(bounds.width), height = Int(bounds.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            // Keep the font's logical optical size. Scaling the context selects
            // a denser bitmap strike without changing shaping/caret geometry.
            context.scaleBy(x: CGFloat(rasterScale), y: CGFloat(rasterScale))
            var glyph = CGGlyph(index), position = CGPoint.zero
            CTFontDrawGlyphs(logicalFont, &glyph, &position, 1, context)
            return true
        }
        guard rendered else { return nil }
        // The renderer expects straight-alpha sRGB. CoreGraphics produces
        // premultiplied pixels; unpremultiply before atlas upload.
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            guard alpha > 0 else { continue }
            for channel in 0..<3 { pixels[offset + channel] = UInt8(min(255, (Int(pixels[offset + channel]) * 255 + alpha / 2) / alpha)) }
        }
        return .init(pixels: pixels, width: width, height: height, metrics: metrics)
    }
    func shape(_ text: String, fontID: Int, utf8Offset: Int) -> [ShapedGlyph] {
        let string = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): logicalFont])
        let line = CTLineCreateWithAttributedString(string)
        var utf8ByUTF16 = [Int: UInt32](), utf16 = 0, utf8 = UInt32(utf8Offset)
        for scalar in text.unicodeScalars {
            utf8ByUTF16[utf16] = utf8
            utf16 += scalar.utf16.count; utf8 += UInt32(scalar.utf8.count)
        }
        var result = [ShapedGlyph]()
        var penX: CGFloat = 0
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count), indices = [CFIndex](repeating: 0, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for i in 0..<count {
                result.append(.init(glyphID: UInt32(glyphs[i]),
                    xOffset: Float(positions[i].x - penX), yOffset: -Float(positions[i].y),
                    xAdvance: Float(advances[i].width), yAdvance: 0,
                    cluster: utf8ByUTF16[indices[i]] ?? UInt32(utf8Offset), fontID: fontID))
                penX += advances[i].width
            }
        }
        return result
    }
}
#endif
