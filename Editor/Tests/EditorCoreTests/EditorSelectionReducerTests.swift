import EditorCore
import EngineKernel
import Testing

@Suite("EditorSelectionReducer")
struct EditorSelectionReducerTests {
    @Test("Shift adds picked entities")
    func shiftAddsPickedEntities() {
        let result = EditorSelectionReducer.merge(base: [1, 2],
                                                  picked: [2, 3],
                                                  modifiers: .shift,
                                                  commandBehavior: .subtract)

        #expect(result == [1, 2, 3])
    }

    @Test("Command subtract behavior removes picked entities")
    func commandSubtractRemovesPickedEntities() {
        let result = EditorSelectionReducer.merge(base: [1, 2, 3],
                                                  picked: [2, 4],
                                                  modifiers: .gui,
                                                  commandBehavior: .subtract)

        #expect(result == [1, 3])
    }

    @Test("Command toggle behavior flips picked entities")
    func commandToggleFlipsPickedEntities() {
        let result = EditorSelectionReducer.merge(base: [1, 2],
                                                  picked: [2, 3],
                                                  modifiers: .ctrl,
                                                  commandBehavior: .toggle)

        #expect(result == [1, 3])
    }
}
