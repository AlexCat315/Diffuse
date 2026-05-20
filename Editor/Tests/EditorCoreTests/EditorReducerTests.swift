import EditorCore
import IntentRuntime
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

    @Test("Appending console messages assigns stable increasing IDs")
    func appendingConsoleMessagesAssignsIDs() {
        var state = EditorState()

        EditorReducer.reduce(state: &state, action: .appendConsoleMessage(" First "))
        EditorReducer.reduce(state: &state, action: .appendConsoleMessage("Second", severity: .warning))

        #expect(state.consoleEntries.map(\.id) == [1, 2])
        #expect(state.consoleEntries.map(\.message) == ["First", "Second"])
        #expect(state.consoleEntries.last?.severity == .warning)
    }

    @Test("Empty console messages are ignored")
    func emptyConsoleMessagesAreIgnored() {
        var state = EditorState()

        EditorReducer.reduce(state: &state, action: .appendConsoleMessage("   \n\t"))

        #expect(state.consoleEntries.isEmpty)
        #expect(state.nextConsoleEntryID == 1)
    }

    @Test("Console history keeps the latest 200 entries")
    func consoleHistoryIsBounded() {
        var state = EditorState()

        for index in 0..<205 {
            EditorReducer.reduce(state: &state, action: .appendConsoleMessage("entry \(index)"))
        }

        #expect(state.consoleEntries.count == 200)
        #expect(state.consoleEntries.first?.message == "entry 5")
        #expect(state.consoleEntries.last?.message == "entry 204")
    }

    @Test("Capability settings update release gate state")
    func capabilitySettingsUpdateReleaseGateState() {
        var state = EditorState()

        EditorReducer.reduce(state: &state,
                             action: .setCapabilitySettings(EditorCapabilitySettings(releasePhase: .beta)))

        #expect(state.capabilitySettings.releasePhase == .beta)
    }
}
