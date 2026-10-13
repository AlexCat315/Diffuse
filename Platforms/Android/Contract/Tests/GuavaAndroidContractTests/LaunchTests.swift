import Foundation
import Testing
import GuavaAndroidContract

@Test func launchRoundTripsForEveryHostMode() throws {
    for mode in [SceneLaunch.Mode.gallery, .counter, .game, .application] {
        let original = SceneLaunch(mode: mode, component: "textField", project: mode == .game ? "Game" : nil)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(SceneLaunch.self, from: data) == original)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(fields.keys).isSubset(of: ["mode", "component", "project"]))
    }
}
