@testable import EditorApp
import XCTest

final class EditorAppResourceBundleTests: XCTestCase {
    func testToolbarIconResolvesThroughPackagedResourceLocator() {
        XCTAssertNotNil(EditorAppResourceBundle.bundle.url(
            forResource: "ai-intent",
            withExtension: "svg"
        ))
    }
}
