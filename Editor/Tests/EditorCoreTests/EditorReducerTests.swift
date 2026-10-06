import EditorCore
import IntentRuntime
import Testing

@Suite("EditorReducer")
struct EditorReducerTests {
    @Test("Selecting a single entity replaces the selection set")
    func selectingEntityReplacesSelectionSet() {
        var state = EditorState {
            $0.selection.selectedEntityID = 1
            $0.selection.selectedEntityIDs = [1, 2]
        }

        EditorReducer.reduce(state: &state, action: .setSelectedEntity(42))

        #expect(state.selection.selectedEntityID == 42)
        #expect(state.selection.selectedEntityIDs == [42])
    }

    @Test("Clearing selection empties primary and multi-selection")
    func clearingSelectionEmptiesSelectionSet() {
        var state = EditorState {
            $0.selection.selectedEntityID = 1
            $0.selection.selectedEntityIDs = [1, 2]
        }

        EditorReducer.reduce(state: &state, action: .setSelectedEntity(nil))

        #expect(state.selection.selectedEntityID == nil)
        #expect(state.selection.selectedEntityIDs.isEmpty)
    }

    @Test("Changing workspace switches to that workspace default preset")
    func changingWorkspaceSelectsDefaultPreset() {
        var state = EditorState {
            $0.workspace.mode = .level
            $0.workspace.layoutPreset = .levelCinematics
        }

        EditorReducer.reduce(state: &state, action: .setWorkspaceMode(.animation))

        #expect(state.workspace.mode == .animation)
        #expect(state.workspace.layoutPreset == .animationDefault)
    }

    @Test("Preset changes are ignored when they do not belong to current workspace")
    func presetMustBelongToWorkspace() {
        var state = EditorState {
            $0.workspace.mode = .modeling
            $0.workspace.layoutPreset = .modelingDefault
        }

        EditorReducer.reduce(state: &state, action: .setActiveLayoutPreset(.levelDefault))

        #expect(state.workspace.layoutPreset == .modelingDefault)
    }

    @Test("Appending console messages assigns stable increasing IDs")
    func appendingConsoleMessagesAssignsIDs() {
        var state = EditorState()

        EditorReducer.reduce(state: &state, action: .appendConsoleMessage(" First "))
        EditorReducer.reduce(state: &state, action: .appendConsoleMessage("Second", severity: .warning))

        #expect(state.output.consoleEntries.map(\.id) == [1, 2])
        #expect(state.output.consoleEntries.map(\.message) == ["First", "Second"])
        #expect(state.output.consoleEntries.last?.severity == .warning)
    }

    @Test("Empty console messages are ignored")
    func emptyConsoleMessagesAreIgnored() {
        var state = EditorState()

        EditorReducer.reduce(state: &state, action: .appendConsoleMessage("   \n\t"))

        #expect(state.output.consoleEntries.isEmpty)
        #expect(state.output.nextConsoleEntryID == 1)
    }

    @Test("Console history keeps the latest 200 entries")
    func consoleHistoryIsBounded() {
        var state = EditorState()

        for index in 0..<205 {
            EditorReducer.reduce(state: &state, action: .appendConsoleMessage("entry \(index)"))
        }

        #expect(state.output.consoleEntries.count == 200)
        #expect(state.output.consoleEntries.first?.message == "entry 5")
        #expect(state.output.consoleEntries.last?.message == "entry 204")
    }

    @Test("Capability settings update release gate state")
    func capabilitySettingsUpdateReleaseGateState() {
        var state = EditorState()

        EditorReducer.reduce(state: &state,
                             action: .setCapabilitySettings(EditorCapabilitySettings(releasePhase: .beta)))

        #expect(state.assistant.capabilitySettings.releasePhase == .beta)
    }

    @Test("physics debug overlay options are bounded to known categories")
    func physicsDebugOptionsAreSanitized() {
        var state = EditorState {
            $0.viewport.physicsDebugOverlayOptions = []
        }
        let unknown = EditorPhysicsDebugOverlayOptions(rawValue: 0xFF)

        EditorReducer.reduce(state: &state, action: .setPhysicsDebugOverlayOptions(unknown))

        #expect(state.viewport.physicsDebugOverlayOptions == .all)
    }

    @Test("Inspector section batches collapse and expand in one reducer action")
    func inspectorSectionBatchCollapse() {
        var state = EditorState {
            $0.selection.inspectorCollapsedSectionIDs = ["existing"]
        }

        EditorReducer.reduce(state: &state,
                             action: .setInspectorSectionsCollapsed(
                                ids: ["general", "transform"],
                                isCollapsed: true
                             ))
        #expect(state.selection.inspectorCollapsedSectionIDs == ["existing", "general", "transform"])

        EditorReducer.reduce(state: &state,
                             action: .setInspectorSectionsCollapsed(
                                ids: ["existing", "transform"],
                                isCollapsed: false
                             ))
        #expect(state.selection.inspectorCollapsedSectionIDs == ["general"])
    }
}
