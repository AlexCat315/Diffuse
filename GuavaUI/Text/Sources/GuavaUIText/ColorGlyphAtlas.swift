import GuavaUICore

/// Lazily allocated color plane; ordinary text keeps its compact alpha atlas.
final class ColorGlyphAtlas {
    let width: Int
    let height: Int
    private var pixels: [UInt8]
    private var shelfX = 0
    private var shelfY = 0
    private var shelfHeight = 0
    private var dirty: FontAtlas.DirtyRegion?
    private(set) var isFull = false
    var isDirty: Bool { dirty != nil }
    init(width: Int, height: Int) {
        self.width = width; self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }
    func insert(_ bitmap: ColorGlyphBitmap) -> GlyphAtlasInfo? {
        let w = bitmap.width, h = bitmap.height
        guard w > 0, h > 0, w < width, h < height, bitmap.pixels.count == w * h * 4 else {
            if w >= width || h >= height { isFull = true }; return nil
        }
        if shelfX + w + 1 > width { shelfY += shelfHeight + 1; shelfX = 0; shelfHeight = 0 }
        guard shelfY + h + 1 <= height else { isFull = true; return nil }
        let x = shelfX, y = shelfY
        shelfX += w + 1; shelfHeight = max(shelfHeight, h)
        for row in 0..<h {
            let source = row * w * 4, target = ((y + row) * width + x) * 4
            pixels.replaceSubrange(target..<(target + w * 4), with: bitmap.pixels[source..<(source + w * 4)])
        }
        mergeDirty(x: x, y: y, width: w, height: h)
        let m = bitmap.metrics
        var info = GlyphAtlasInfo(glyphIndex: m.glyphIndex, width: m.width, height: m.height,
            bearingX: m.bearingX, bearingY: m.bearingY, advance: m.advance,
            uvMinX: Float(x) / Float(width), uvMinY: Float(y) / Float(height),
            uvMaxX: Float(x + w) / Float(width), uvMaxY: Float(y + h) / Float(height))
        info.format = .color
        return info
    }
    func payload() -> (region: FontAtlas.DirtyRegion, pixels: [UInt8])? {
        guard let dirty else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(dirty.width * dirty.height * 4)
        for row in 0..<dirty.height {
            let start = ((dirty.y + row) * width + dirty.x) * 4
            bytes.append(contentsOf: pixels[start..<(start + dirty.width * 4)])
        }
        return (dirty, bytes)
    }
    func markClean() { dirty = nil }
    func reset() {
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        shelfX = 0; shelfY = 0; shelfHeight = 0; isFull = false
        dirty = FontAtlas.DirtyRegion(x: 0, y: 0, width: width, height: height)
    }
    private func mergeDirty(x: Int, y: Int, width: Int, height: Int) {
        guard let previous = dirty else { dirty = .init(x: x, y: y, width: width, height: height); return }
        let left = min(x, previous.x), top = min(y, previous.y)
        dirty = .init(x: left, y: top, width: max(x + width, previous.x + previous.width) - left,
                      height: max(y + height, previous.y + previous.height) - top)
    }
}
