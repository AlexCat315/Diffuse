import EngineKernel

@MainActor
public final class InputState {
    public private(set) var pressedKeys: Set<UInt32> = []
    public private(set) var mouseX: Float = 0
    public private(set) var mouseY: Float = 0
    public private(set) var mouseDeltaX: Float = 0
    public private(set) var mouseDeltaY: Float = 0
    public private(set) var pressedMouseButtons: Set<MouseButton> = []
    public private(set) var modifiers: KeyModifiers = []
    public private(set) var scrollDeltaX: Float = 0
    public private(set) var scrollDeltaY: Float = 0

    public init() {}

    public func process(_ events: [InputEvent]) {
        mouseDeltaX = 0
        mouseDeltaY = 0
        scrollDeltaX = 0
        scrollDeltaY = 0

        for event in events {
            switch event {
            case .keyDown(let e):
                pressedKeys.insert(e.scancode)
                modifiers = e.modifiers
            case .keyUp(let e):
                pressedKeys.remove(e.scancode)
                modifiers = e.modifiers
            case .mouseMotion(let e):
                mouseX = e.x
                mouseY = e.y
                mouseDeltaX += e.deltaX
                mouseDeltaY += e.deltaY
            case .mouseButtonDown(let e):
                pressedMouseButtons.insert(e.button)
                mouseX = e.x
                mouseY = e.y
            case .mouseButtonUp(let e):
                pressedMouseButtons.remove(e.button)
                mouseX = e.x
                mouseY = e.y
            case .mouseWheel(let e):
                scrollDeltaX += e.x
                scrollDeltaY += e.y
            default:
                break
            }
        }
    }

    public func isKeyPressed(_ scancode: UInt32) -> Bool {
        pressedKeys.contains(scancode)
    }

    public func isMouseButtonPressed(_ button: MouseButton) -> Bool {
        pressedMouseButtons.contains(button)
    }
}
