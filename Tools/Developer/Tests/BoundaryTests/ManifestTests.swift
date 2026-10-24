import Foundation
import XCTest
@testable import Boundaries

final class ManifestTests: XCTestCase {
  func testAbsoluteSDKPathDoesNotAcquireTheStudioPrefix() {
    let sdk = URL(fileURLWithPath: #filePath).deletingLastPathComponent().standardizedFileURL
    let studio = FileManager.default.temporaryDirectory.appendingPathComponent("studio")
    XCTAssertEqual(canonicalPath(sdk.path, relativeTo: studio), sdk.resolvingSymlinksInPath())
  }
}
