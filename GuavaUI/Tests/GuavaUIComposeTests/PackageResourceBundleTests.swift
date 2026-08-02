import Testing
@testable import GuavaUICompose

@Suite("GuavaUICompose resources")
struct GuavaUIComposeResourceBundleTests {
    @Test("built-in icons resolve outside SwiftPM's generated accessor")
    func builtInIconResolves() {
        #expect(UICommonIcons.chevronDown.url != nil)
        #expect(UICommonIcons.checkmark.url != nil)
    }
}
