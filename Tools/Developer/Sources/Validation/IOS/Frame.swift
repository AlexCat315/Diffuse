#if canImport(CoreGraphics)
  internal import CoreGraphics
  internal import Foundation
  internal import ImageIO
  internal import ToolSupport

  /// Counts the distinct colors in the upper content band of a simulator
  /// screenshot, which is where the starter draws its controls.
  enum Frame {
    /// The starter must render real controls; a flat background yields almost no
    /// distinct colors. Sampling excludes status bars and safe areas.
    static func distinctColors(in url: URL) throws -> Int {
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else {
        throw ToolError.message("Simulator screenshot could not be decoded")
      }
      let width = image.width
      let height = image.height
      var pixels = [UInt8](repeating: 0, count: width * height * 4)
      return pixels.withUnsafeMutableBytes { bytes -> Int in
        let bitmap =
          CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard
          let context = CGContext(
            data: bytes.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap)
        else {
          return 0
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var colors = Set<UInt32>()
        for y in stride(from: height / 10, to: height / 3, by: 5) {
          for x in stride(from: width / 10, to: width * 9 / 10, by: 5) {
            let offset = (y * width + x) * 4
            colors.insert(
              UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]))
          }
        }
        return colors.count
      }
    }
  }
#endif
