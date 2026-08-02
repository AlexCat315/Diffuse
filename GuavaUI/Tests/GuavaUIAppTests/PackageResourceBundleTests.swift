import Testing
@testable import GuavaUIApp

@Suite("GuavaUIApp resources")
struct GuavaUIAppResourceBundleTests {
    @Test("window chrome icons resolve through the packaged resource locator")
    func windowChromeIconResolves() {
        #expect(GuavaUIAppResourceBundle.bundle.url(
            forResource: "close",
            withExtension: "svg"
        ) != nil)
    }
}
