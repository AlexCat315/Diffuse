internal import Foundation
private import ImageCodec
private import ToolSupport

/// One decoded screenshot pixel in straight RGBA order, matching Pillow's
/// `Image.convert("RGBA").getdata()` tuples.
struct Pixel: Sendable {
  let r: UInt8
  let g: UInt8
  let b: UInt8
  let a: UInt8
}

/// A decoded screenshot with RGBA rows. Pillow is replaced by ImageIO and
/// CoreGraphics, which ship with the operating system.
struct RGBAImage: Sendable {
  let width: Int
  let height: Int
  let pixels: [UInt8]

  /// Copies the half-open pixel rectangle, clamping it to the image.
  func subimage(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> RGBAImage {
    let left = max(0, min(x0, width))
    let right = max(0, min(x1, width))
    let top = max(0, min(y0, height))
    let bottom = max(0, min(y1, height))
    guard left < right, top < bottom else { return RGBAImage(width: 0, height: 0, pixels: []) }
    var out = [UInt8]()
    out.reserveCapacity((right - left) * (bottom - top) * 4)
    for y in top..<bottom {
      let start = (y * width + left) * 4
      out.append(contentsOf: pixels[start..<(start + (right - left) * 4)])
    }
    return RGBAImage(width: right - left, height: bottom - top, pixels: out)
  }

  /// Reads the half-open pixel rectangle, clamping it to the image, exactly
  /// like slicing a Pillow image and calling `getdata()`.
  func crop(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> [Pixel] {
    let image = subimage(x0, y0, x1, y1)
    var out: [Pixel] = []
    out.reserveCapacity(image.width * image.height)
    for index in stride(from: 0, to: image.pixels.count, by: 4) {
      out.append(
        Pixel(
          r: image.pixels[index], g: image.pixels[index + 1],
          b: image.pixels[index + 2], a: image.pixels[index + 3]))
    }
    return out
  }
}

extension RGBAImage {
  init(png data: Data) throws {
    let image = try DecodedImage(data: data)
    self.init(width: image.width, height: image.height, pixels: image.pixels)
  }
}

/// The region passed to `wait_pixels`: either a fixed rectangle or a script that
/// recomputes it from the live snapshot each iteration.
enum PixelRegion: Sendable {
  case rect([Double])
  case script(String)

  var description: String {
    switch self {
    case .rect(let values):
      return "[" + values.map { String(Int($0)) }.joined(separator: ", ") + "]"
    case .script(let expression): return expression
    }
  }
}

/// Polls the presented canvas image until `predicate` accepts the decoded
/// pixels, including WebGPU's shown image, which must be read from a screenshot
/// rather than copied after presentation.
func waitPixels(
  _ page: Page, _ region: PixelRegion, timeout: Double = 10,
  predicate: ([Pixel]) -> Bool
) throws {
  let deadline = Date(timeIntervalSinceNow: timeout)
  var backend = ""
  while Date() < deadline {
    let rect: [Double]
    switch region {
    case .rect(let values):
      rect = values
    case .script(let expression):
      rect = ((try? page.evaluate(expression))?.array ?? []).compactMap(\.number)
    }
    backend = (try? page.evaluate("guavaDebug.backend").string) ?? ""
    let selector = backend == "webgpu" ? "#gpu" : "#fallback"
    guard let image = try? page.elementImage(selector) else {
      page.waitForTimeout(50)
      continue
    }
    let logicalWidth = (try? page.evaluate("guavaDebug.snapshot.width").number) ?? 0
    let ratio = logicalWidth > 0 ? Double(image.width) / logicalWidth : 1
    let x = rect.count > 0 ? rect[0] : 0
    let y = rect.count > 1 ? rect[1] : 0
    let width = rect.count > 2 ? rect[2] : 0
    let height = rect.count > 3 ? rect[3] : 0
    let pixels = image.crop(
      Int(floor(x * ratio)), Int(floor(y * ratio)),
      Int(ceil((x + width) * ratio)), Int(ceil((y + height) * ratio)))
    if predicate(pixels) { return }
    page.waitForTimeout(50)
  }
  let gpu = (try? page.evaluate("guavaDebug.gpuInfo"))?.serialized ?? "null"
  throw ToolError.message(
    "Expected displayed canvas pixels in \(region.description); backend=\(backend), gpu=\(gpu)")
}
