import EditorCore
import EngineKernel
import SceneRuntime
import Testing

@Suite("Editor input state")
struct InputStateTests {
    @Test("focus loss clears held controls, modifiers, and transient deltas")
    func focusLossClearsInput() {
        let state = InputState()
        state.process([
            .keyDown(KeyEvent(scancode: Scancode.space,
                              keycode: 0,
                              modifiers: [.shift],
                              isRepeat: false)),
            .mouseButtonDown(MouseButtonEvent(button: .left, x: 12, y: 24, clicks: 1)),
            .mouseMotion(MouseMotionEvent(x: 14, y: 25, deltaX: 2, deltaY: 1)),
            .mouseWheel(MouseWheelEvent(x: 1, y: -2)),
            .windowFocusLost,
        ])

        #expect(state.pressedKeys.isEmpty)
        #expect(state.pressedMouseButtons.isEmpty)
        #expect(state.modifiers.isEmpty)
        #expect(state.mouseDeltaX == 0)
        #expect(state.mouseDeltaY == 0)
        #expect(state.scrollDeltaX == 0)
        #expect(state.scrollDeltaY == 0)
    }

    @Test("minimization clears held controls")
    func minimizationClearsInput() {
        let state = InputState()
        state.process([
            .keyDown(KeyEvent(scancode: Scancode.space,
                              keycode: 0,
                              modifiers: [],
                              isRepeat: false)),
            .mouseButtonDown(MouseButtonEvent(button: .right, x: 0, y: 0, clicks: 1)),
            .windowMinimized,
        ])

        #expect(!state.isKeyPressed(Scancode.space))
        #expect(!state.isMouseButtonPressed(.right))
    }
}
