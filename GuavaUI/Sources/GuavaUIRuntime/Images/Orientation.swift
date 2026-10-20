import Foundation

/// EXIF orientation (1–8) of JPEG data. The portable decoders return pixels
/// in storage order, so the UI applies the camera's intended rotation itself.
public enum ImageOrientation {
    /// Orientation tag from the first APP1 Exif segment, or 1 when absent.
    public static func read(_ data: Data) -> Int {
        let bytes = [UInt8](data.prefix(256 * 1_024))
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return 1 }
        var offset = 2
        while offset + 4 <= bytes.count, bytes[offset] == 0xFF {
            let marker = bytes[offset + 1]
            if marker == 0xD9 || marker == 0xDA { break }
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length >= 2, offset + 2 + length <= bytes.count else { break }
            if marker == 0xE1, length >= 16,
               Array(bytes[(offset + 4)..<(offset + 10)]) == [0x45, 0x78, 0x69, 0x66, 0, 0] {
                return tiffOrientation(bytes, start: offset + 10, end: offset + 2 + length) ?? 1
            }
            offset += 2 + length
        }
        return 1
    }

    /// Orientations 5–8 exchange width and height.
    public static func swapsAxes(_ orientation: Int) -> Bool { (5...8).contains(orientation) }

    /// Pixels rearranged so the image displays upright.
    public static func apply(_ orientation: Int, to image: DecodedImage) -> DecodedImage {
        guard (2...8).contains(orientation) else { return image }
        let w = image.width, h = image.height
        let swaps = swapsAxes(orientation)
        let outWidth = swaps ? h : w, outHeight = swaps ? w : h
        var pixels = [UInt8](repeating: 0, count: image.pixels.count)
        image.pixels.withUnsafeBufferPointer { source in
            pixels.withUnsafeMutableBufferPointer { destination in
                for y in 0..<outHeight {
                    for x in 0..<outWidth {
                        let (sx, sy): (Int, Int)
                        switch orientation {
                        case 2: (sx, sy) = (w - 1 - x, y)
                        case 3: (sx, sy) = (w - 1 - x, h - 1 - y)
                        case 4: (sx, sy) = (x, h - 1 - y)
                        case 5: (sx, sy) = (y, x)
                        case 6: (sx, sy) = (y, h - 1 - x)
                        case 7: (sx, sy) = (w - 1 - y, h - 1 - x)
                        default: (sx, sy) = (w - 1 - y, x)
                        }
                        let from = (sy * w + sx) * 4, to = (y * outWidth + x) * 4
                        destination[to] = source[from]; destination[to + 1] = source[from + 1]
                        destination[to + 2] = source[from + 2]; destination[to + 3] = source[from + 3]
                    }
                }
            }
        }
        return DecodedImage(pixels: pixels, width: outWidth, height: outHeight)
    }

    private static func tiffOrientation(_ bytes: [UInt8], start: Int, end: Int) -> Int? {
        guard start + 8 <= end else { return nil }
        let little: Bool
        switch (bytes[start], bytes[start + 1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        func u16(_ at: Int) -> Int? {
            guard at >= start, at + 2 <= end else { return nil }
            return little ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : Int(bytes[at]) << 8 | Int(bytes[at + 1])
        }
        func u32(_ at: Int) -> Int? {
            guard let a = u16(at), let b = u16(at + 2) else { return nil }
            return little ? a | b << 16 : a << 16 | b
        }
        guard u16(start + 2) == 42, let ifd = u32(start + 4), let count = u16(start + ifd) else { return nil }
        for index in 0..<min(count, 512) {
            let entry = start + ifd + 2 + index * 12
            guard let tag = u16(entry) else { return nil }
            if tag == 0x0112, let value = u16(entry + 8), (1...8).contains(value) { return value }
        }
        return nil
    }
}
