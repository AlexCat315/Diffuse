import EditorCore
import Testing

@Suite("EditorReducer")
struct EditorReducerTests {
    @Test("Selecting a single entity replaces the selection set")
    func selectingEntityReplacesSelectionSet() {
        var state = EditorState(selectedEntityID: 1, selectedEntityIDs: [1, 2])

        EditorReducer.reduce(state: &state, action: .setSelectedEntity(42))

        #expect(state.selectedEntityID == 42)
        #expect(state.selectedEntityIDs == [42])
    }

    @Test("Clearing selection empties primary and multi-selection")
    func clearingSelectionEmptiesSelectionSet() {
        var state = EditorState(selectedEntityID: 1, selectedEntityIDs: [1, 2])

        EditorReducer.reduce(state: &state, action: .setSelectedEntity(nil))

        #expect(state.selectedEntityID == nil)
        #expect(state.selectedEntityIDs.isEmpty)
    }
}
