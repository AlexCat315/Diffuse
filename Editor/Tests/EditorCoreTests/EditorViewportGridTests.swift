import EditorCore
import Foundation
import Testing

@Suite("EditorViewportGrid")
struct EditorViewportGridTests {
    @Test("grid defaults on, toggles, and restores with editor state")
    func gridStatePersists() throws {
        var state = EditorState()
        #expect(state.viewport.gridEnabled)
        EditorReducer.reduce(state: &state, action: .setViewportGridEnabled(false))
        #expect(!state.viewport.gridEnabled)
        let data = try JSONEncoder().encode(state)
        #expect(try !JSONDecoder().decode(EditorState.self, from: data).viewport.gridEnabled)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var viewport = try #require(object["viewport"] as? [String: Any])
        viewport.removeValue(forKey: "gridEnabled")
        object["viewport"] = viewport
        let missingFieldData = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(EditorState.self, from: missingFieldData).viewport.gridEnabled)
    }
}
