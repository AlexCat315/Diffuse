import Testing
@testable import PlatformShell

struct DisplayRefreshRateTests {
    @MainActor
    @Test("Frame pacing uses the selected display mode instead of the screen maximum")
    func selectedModeTakesPrecedence() {
        #expect(SDL3Shell.resolvedDisplayRefreshRate(current: 60, fallback: 120) == 60)
        #expect(SDL3Shell.resolvedDisplayRefreshRate(current: 59.94, fallback: 60) == 59.94)
        #expect(SDL3Shell.resolvedDisplayRefreshRate(current: 144, fallback: 120) == 144)
    }

    @MainActor
    @Test("Unavailable or invalid display modes use a valid native fallback")
    func invalidModesUseFallback() {
        let invalidModes: [Double?] = [nil, 0, 11, Double.nan, Double.infinity, 501]
        for current in invalidModes {
            #expect(SDL3Shell.resolvedDisplayRefreshRate(current: current, fallback: 120) == 120)
        }
        #expect(SDL3Shell.resolvedDisplayRefreshRate(current: 60, fallback: nil) == 60)
        #expect(SDL3Shell.resolvedDisplayRefreshRate(current: nil, fallback: 0) == nil)
    }
}
