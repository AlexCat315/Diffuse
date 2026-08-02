import Testing
@testable import EditorCore

@Suite("EditorCore resources")
struct EditorCoreResourceBundleTests {
    @Test("localization bundle resolves through the packaged resource locator")
    func localizationBundleResolves() {
        #expect(EditorCoreResourceBundle.bundle.path(
            forResource: "en",
            ofType: "lproj"
        ) != nil)
    }
}
