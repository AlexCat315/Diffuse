#if canImport(CoreGraphics)
import CoreGraphics

extension ImageDecoder {
    /// Draw a `CGImage` into a normalized RGBA8 buffer, then un-premultiply so
    /// the bytes match the renderer's straight-alpha blend convention (the
    /// native bridge already returns straight alpha).
    static func rasterize(_ cg: CGImage, targetSize: (Int, Int)?) -> DecodedImage {
        let w = targetSize?.0 ?? cg.width
        let h = targetSize?.1 ?? cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
                               | CGBitmapInfo.byteOrder32Big.rawValue
        bytes.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: w, height: h,
                                      bitsPerComponent: 8,
                                      bytesPerRow: w * 4,
                                      space: cs,
                                      bitmapInfo: bitmapInfo) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        unpremultiplyInPlace(&bytes)
        return DecodedImage(pixels: bytes, width: w, height: h)
    }

    private static func unpremultiplyInPlace(_ bytes: inout [UInt8]) {
        let count = bytes.count
        var i = 0
        while i + 3 < count {
            let a = bytes[i + 3]
            if a != 0 && a != 255 {
                let af = Float(a)
                bytes[i + 0] = UInt8(min(255, (Float(bytes[i + 0]) * 255.0 / af).rounded()))
                bytes[i + 1] = UInt8(min(255, (Float(bytes[i + 1]) * 255.0 / af).rounded()))
                bytes[i + 2] = UInt8(min(255, (Float(bytes[i + 2]) * 255.0 / af).rounded()))
            } else if a == 0 {
                bytes[i + 0] = 0
                bytes[i + 1] = 0
                bytes[i + 2] = 0
            }
            i += 4
        }
    }
}
#endif
