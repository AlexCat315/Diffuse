import Foundation
import XCTest

@testable import ToolSupport

final class ToolSupportTests: XCTestCase {
  func testKnownSHA256Vectors() {
    XCTAssertEqual(
      SHA256.hex(Data("".utf8)), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    XCTAssertEqual(
      SHA256.hex(Data("abc".utf8)),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let long = String(repeating: "a", count: 1_000_000)
    XCTAssertEqual(
      SHA256.hex(Data(long.utf8)),
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
  }

  func testFileDigestMatchesBuffer() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "guava-sha-\(UUID().uuidString)")
    try Data("pinned artifact".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertEqual(try SHA256.hex(file: url), SHA256.hex(Data("pinned artifact".utf8)))
  }

  func testRelativePathsUseForwardSlashes() {
    let root = URL(fileURLWithPath: "/tmp/guava")
    let file = URL(fileURLWithPath: "/tmp/guava/Engine/vendor/info.json")
    XCTAssertEqual(Fs.relative(file, to: root), "Engine/vendor/info.json")
  }
}
