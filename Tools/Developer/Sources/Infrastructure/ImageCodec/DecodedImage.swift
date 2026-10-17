private import CImageDecoder
package import Foundation
private import ToolSupport

/// Top-to-bottom, straight RGBA bytes, independent of the host graphics stack.
package struct DecodedImage: Sendable {
  package let width: Int
  package let height: Int
  package let pixels: [UInt8]

  package init(data: Data) throws {
    guard let count = Int32(exactly: data.count), count > 0 else {
      throw ToolError.message("Image data is empty or too large to decode")
    }
    var width: Int32 = 0
    var height: Int32 = 0
    let buffer = data.withUnsafeBytes { bytes in
      guava_tool_decode_image(bytes.bindMemory(to: UInt8.self).baseAddress, count, &width, &height)
    }
    guard let buffer else { throw ToolError.message("Cannot decode screenshot image") }
    defer { guava_tool_free_image(buffer) }
    self.width = Int(width)
    self.height = Int(height)
    pixels = Array(UnsafeBufferPointer(start: buffer, count: Int(width) * Int(height) * 4))
  }
}
