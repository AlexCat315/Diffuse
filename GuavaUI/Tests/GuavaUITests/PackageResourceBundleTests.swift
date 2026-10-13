import Testing
@testable import GuavaUI

@Suite("GuavaUI resources")
struct GuavaUIResourceBundleTests {
    @Test("window chrome icons resolve through the packaged resource locator")
    func windowChromeIconResolves() {
        #expect(GuavaUIResourceBundle.bundle.url(
            forResource: "close",
            withExtension: "svg"
        ) != nil)
    }
}
