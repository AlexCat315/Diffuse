import EditorCore
import Foundation
import Testing

@Suite("EditorViewportGrid")
struct EditorViewportGridTests {
    @Test("grid defaults on, toggles, and restores with editor state")
    func gridStatePersists() throws {
        var state = EditorState()
        #expect(state.viewportGridEnabled)
        EditorReducer.reduce(state: &state, action: .setViewportGridEnabled(false))
        #expect(!state.viewportGridEnabled)
        let data = try JSONEncoder().encode(state)
        #expect(try !JSONDecoder().decode(EditorState.self, from: data).viewportGridEnabled)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "viewportGridEnabled")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try JSONDecoder().decode(EditorState.self, from: legacyData).viewportGridEnabled)
    }
}
