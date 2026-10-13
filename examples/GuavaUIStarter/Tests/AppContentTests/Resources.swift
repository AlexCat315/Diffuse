import Testing
@testable import AppContent

@Test func welcomeResourceIsPackaged() {
    #expect(AppResources.welcome == "Welcome to GuavaUI · 你好，GuavaUI")
}
