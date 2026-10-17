internal import Foundation
private import ImageCodec
internal import ToolSupport

/// RGB raster mirroring the Pillow operations the harness relied on:
/// `Image.open(path).convert('RGB')`, `crop`, `tobytes`, `getpixel`, and the
/// per-band population standard deviation of `ImageStat.Stat`.
struct Bitmap {
  let width: Int
  let height: Int
  /// Row-major RGB, three bytes per pixel, exactly `Image.tobytes()`.
  private let pixels: [UInt8]

  var data: Data { Data(pixels) }

  /// Decodes a PNG/JPEG into a straight RGB raster, dropping the alpha band
  /// like `convert('RGB')`.
  static func load(_ url: URL) throws -> Bitmap {
    let decoded = try DecodedImage(data: Data(contentsOf: url))
    var rgb: [UInt8] = []
    rgb.reserveCapacity(decoded.width * decoded.height * 3)
    for index in stride(from: 0, to: decoded.pixels.count, by: 4) {
      rgb.append(contentsOf: decoded.pixels[index..<(index + 3)])
    }
    return Bitmap(width: decoded.width, height: decoded.height, pixels: rgb)
  }

  /// `Image.crop((left, upper, right, lower))`; areas outside the source are
  /// padded with black, as Pillow does.
  func cropped(_ left: Int, _ top: Int, _ right: Int, _ bottom: Int) -> Bitmap {
    let width = max(0, right - left)
    let height = max(0, bottom - top)
    guard width > 0, height > 0 else { return Bitmap(width: 0, height: 0, pixels: []) }
    var rgb = [UInt8](repeating: 0, count: width * height * 3)
    for row in 0..<height {
      for column in 0..<width {
        let x = left + column
        let y = top + row
        guard x >= 0, x < self.width, y >= 0, y < self.height else { continue }
        let source = (y * self.width + x) * 3
        let destination = (row * width + column) * 3
        rgb[destination] = pixels[source]
        rgb[destination + 1] = pixels[source + 1]
        rgb[destination + 2] = pixels[source + 2]
      }
    }
    return Bitmap(width: width, height: height, pixels: rgb)
  }

  func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    guard x >= 0, x < width, y >= 0, y < height else { return (0, 0, 0) }
    let index = (y * width + x) * 3
    return (pixels[index], pixels[index + 1], pixels[index + 2])
  }

  /// `max(image.getpixel((x, y)))` across the three bands.
  func maxChannel(_ x: Int, _ y: Int) -> UInt8 {
    let value = pixel(x, y)
    return max(value.r, max(value.g, value.b))
  }

  /// `max(ImageStat.Stat(image).stddev)`: the largest per-band population
  /// standard deviation, used as a blank-surface guard.
  var maxChannelStdDev: Double {
    guard width > 0, height > 0 else { return 0 }
    let total = Double(width * height)
    var sum = [Double](repeating: 0, count: 3)
    var sumSquares = [Double](repeating: 0, count: 3)
    var index = 0
    while index < pixels.count {
      for band in 0..<3 {
        let value = Double(pixels[index + band])
        sum[band] += value
        sumSquares[band] += value * value
      }
      index += 3
    }
    var deviation = 0.0
    for band in 0..<3 {
      let mean = sum[band] / total
      let variance = sumSquares[band] / total - mean * mean
      deviation = max(deviation, variance > 0 ? variance.squareRoot() : 0)
    }
    return deviation
  }

  /// Counts "ink" pixels for the counter glyphs: the harness' dark-glyph test.
  func inkCount(r: UInt8 = 100, g: UInt8 = 120, b: UInt8 = 160) -> Int {
    var count = 0
    var index = 0
    while index < pixels.count {
      if pixels[index] < r, pixels[index + 1] < g, pixels[index + 2] < b { count += 1 }
      index += 3
    }
    return count
  }

  func sha256Hex() -> String { SHA256.hex(data) }
}
