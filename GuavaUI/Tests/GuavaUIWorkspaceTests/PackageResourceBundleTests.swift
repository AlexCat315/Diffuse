import Testing
@testable import GuavaUIWorkspace

@Suite("GuavaUIWorkspace resources")
struct GuavaUIWorkspaceResourceBundleTests {
    @Test("workspace icons resolve through the packaged resource locator")
    func workspaceIconResolves() {
        #expect(GuavaUIWorkspaceResourceBundle.bundle.url(
            forResource: "collapse",
            withExtension: "svg"
        ) != nil)
    }
}
