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

    @Test("Changing workspace switches to that workspace default preset")
    func changingWorkspaceSelectsDefaultPreset() {
        var state = EditorState(workspaceMode: .level,
                                activeLayoutPreset: .levelCinematics)

        EditorReducer.reduce(state: &state, action: .setWorkspaceMode(.animation))

        #expect(state.workspaceMode == .animation)
        #expect(state.activeLayoutPreset == .animationDefault)
    }

    @Test("Preset changes are ignored when they do not belong to current workspace")
    func presetMustBelongToWorkspace() {
        var state = EditorState(workspaceMode: .modeling,
                                activeLayoutPreset: .modelingDefault)

        EditorReducer.reduce(state: &state, action: .setActiveLayoutPreset(.levelDefault))

        #expect(state.activeLayoutPreset == .modelingDefault)
    }
}
