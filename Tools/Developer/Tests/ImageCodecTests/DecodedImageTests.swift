import Foundation
import ImageCodec
import XCTest

final class DecodedImageTests: XCTestCase {
  func testPNGKeepsRowOrderAndUnpremultipliedColor() throws {
    let png = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAF0lEQVR4nAXBAQEAAACCIKb33EAkQxUHQdUHepwfNGcAAAAASUVORK5CYII="
    )!
    let image = try DecodedImage(data: png)
    XCTAssertEqual(image.width, 2)
    XCTAssertEqual(image.height, 2)
    XCTAssertEqual(image.pixels, [255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 255, 255, 0, 0])
  }

  func testMalformedImageFailsInsteadOfProducingBlankPixels() {
    XCTAssertThrowsError(try DecodedImage(data: Data()))
    XCTAssertThrowsError(try DecodedImage(data: Data("not a PNG".utf8)))
  }
}
