import EngineKernel
import SceneRuntime

final class InputStateProcessor: @unchecked Sendable {
    private var heldKeys: Set<UInt32> = []
    private var heldMouseButtons: Set<MouseButton> = []
    private var heldGamepadButtons: Set<GamepadButton> = []
    private var gamepadAxes: [GamepadAxis: Float] = [:]

    func process(context: inout RuntimeScriptPhaseContext) {
        let frame = context.resource(InputFrameResource.self) ?? InputFrameResource()
        let map   = context.resource(InputActionMap.self) ?? InputActionMap()

        var keysJustPressed:   Set<UInt32>      = []
        var keysJustReleased:  Set<UInt32>      = []
        var buttonsJustPressed: Set<MouseButton> = []
        var buttonsJustReleased: Set<MouseButton> = []
        var gpadButtonsJustPressed: Set<GamepadButton> = []
        var gpadButtonsJustReleased: Set<GamepadButton> = []

        for event in frame.events {
            switch event {
            case let .keyDown(e) where !e.isRepeat:
                keysJustPressed.insert(e.scancode)
                heldKeys.insert(e.scancode)
            case let .keyUp(e):
                keysJustReleased.insert(e.scancode)
                heldKeys.remove(e.scancode)
            case let .mouseButtonDown(e):
                buttonsJustPressed.insert(e.button)
                heldMouseButtons.insert(e.button)
            case let .mouseButtonUp(e):
                buttonsJustReleased.insert(e.button)
                heldMouseButtons.remove(e.button)
            case let .gamepadButtonDown(e):
                gpadButtonsJustPressed.insert(e.button)
                heldGamepadButtons.insert(e.button)
            case let .gamepadButtonUp(e):
                gpadButtonsJustReleased.insert(e.button)
                heldGamepadButtons.remove(e.button)
            case let .gamepadAxisMotion(e):
                gamepadAxes[e.axis] = e.value
            default:
                break
            }
        }

        var held: Set<String>         = []
        var justPressed: Set<String>  = []
        var justReleased: Set<String> = []
        var axes: [String: Float]     = [:]

        for (action, bindings) in map.bindings {
            var isHeld = false
            var wasJustPressed = false
            var wasJustReleased = false

            for binding in bindings {
                switch binding {
                case let .key(sc):
                    if heldKeys.contains(sc)        { isHeld = true }
                    if keysJustPressed.contains(sc) { wasJustPressed = true }
                    if keysJustReleased.contains(sc){ wasJustReleased = true }

                case let .mouseButton(btn):
                    if heldMouseButtons.contains(btn)        { isHeld = true }
                    if buttonsJustPressed.contains(btn)      { wasJustPressed = true }
                    if buttonsJustReleased.contains(btn)     { wasJustReleased = true }

                case let .keyAxis(neg, pos):
                    let n: Float = heldKeys.contains(neg) ? -1 : 0
                    let p: Float = heldKeys.contains(pos) ?  1 : 0
                    let v = (p + n).clamped(to: -1...1)
                    axes[action] = (axes[action] ?? 0) + v

                case let .gamepadButton(btn):
                    if heldGamepadButtons.contains(btn)        { isHeld = true }
                    if gpadButtonsJustPressed.contains(btn)    { wasJustPressed = true }
                    if gpadButtonsJustReleased.contains(btn)   { wasJustReleased = true }

                case let .gamepadAxis(axis):
                    let v = gamepadAxes[axis] ?? 0
                    axes[action] = (axes[action] ?? 0) + v
                }
            }

            if isHeld        { held.insert(action) }
            if wasJustPressed { justPressed.insert(action) }
            if wasJustReleased { justReleased.insert(action) }
        }

        context.setResource(InputFrameState(
            held: held,
            justPressed: justPressed,
            justReleased: justReleased,
            axes: axes
        ))
    }

    func reset() {
        heldKeys.removeAll()
        heldMouseButtons.removeAll()
        heldGamepadButtons.removeAll()
        gamepadAxes.removeAll()
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
