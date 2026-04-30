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
                                                  primaryModifierBehavior: .subtract)

        #expect(result == [1, 2, 3])
    }

    @Test("Primary modifier subtract behavior removes picked entities")
    func primaryModifierSubtractRemovesPickedEntities() {
        let result = EditorSelectionReducer.merge(base: [1, 2, 3],
                                                  picked: [2, 4],
                                                  modifiers: .gui,
                                                  primaryModifierBehavior: .subtract)

        #expect(result == [1, 3])
    }

    @Test("Primary modifier toggle behavior flips picked entities")
    func primaryModifierToggleFlipsPickedEntities() {
        let result = EditorSelectionReducer.merge(base: [1, 2],
                                                  picked: [2, 3],
                                                  modifiers: .ctrl,
                                                  primaryModifierBehavior: .toggle)

        #expect(result == [1, 3])
    }
}
