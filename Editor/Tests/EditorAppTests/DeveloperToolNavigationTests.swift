@testable import EditorApp
import Testing

@Suite("Developer tool navigation")
struct DeveloperToolNavigationTests {
    @Test("diagnostic targets map to visible workbench tabs")
    func mapsInternalTargetsToVisibleTabs() {
        #expect(developerToolTabDestination(for: .frame) == .profiler)
        #expect(developerToolTabDestination(for: .console) == .debugger)
        #expect(developerToolTabDestination(for: .state) == .debugger)
        #expect(developerToolTabDestination(for: .render) == .render)
        #expect(developerToolTabDestination(for: .particles) == .particles)
    }
}
