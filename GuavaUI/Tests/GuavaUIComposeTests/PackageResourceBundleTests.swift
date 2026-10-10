import Testing
@testable import GuavaUICompose

@Suite("GuavaUICompose resources")
struct GuavaUIComposeResourceBundleTests {
    @Test("built-in icons resolve outside SwiftPM's generated accessor")
    func builtInIconResolves() {
        #expect(UIIcons.Navigation.chevronDown.url != nil)
        #expect(UIIcons.Action.check.url != nil)
    }
}
