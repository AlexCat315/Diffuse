@testable import EditorApp
import EditorCore
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
        #expect(developerToolTabDestination(for: .trace) == .trace)
    }

    @Test("debugger console filters messages and keeps the newest match first")
    func debuggerConsoleFiltersAndOrdersNewestFirst() {
        let entries = [
            EditorConsoleEntry(id: 1, severity: .info, message: "Asset import started"),
            EditorConsoleEntry(id: 3, severity: .error, message: "Asset import failed", detail: "Missing source"),
            EditorConsoleEntry(id: 2, severity: .warning, message: "Asset import is slow"),
        ]

        let visible = developerDebuggerConsoleEntries(entries: entries,
                                                      severities: [.warning, .error],
                                                      query: "asset import")

        #expect(visible.map(\.id) == [3, 2])
    }
}
