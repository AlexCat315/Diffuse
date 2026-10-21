import Foundation
import Testing
@testable import GuavaCLI

@Test(arguments: [["../host"], ["host", "host"], ["Application"], ["host/path"], [""]])
func invalidDesktopHelpersFail(names: [String]) {
    var targets = ProjectConfiguration.Targets()
    targets.desktopHelpers = names
    #expect(throws: (any Error).self) { try targets.validate() }
}

@Test func desktopHelpersRoundTrip() throws {
    var targets = ProjectConfiguration.Targets()
    targets.desktopHelpers = ["GuavaPluginHost"]
    try targets.validate()
    #expect(try JSONDecoder().decode(ProjectConfiguration.Targets.self, from: JSONEncoder().encode(targets)) == targets)
}
