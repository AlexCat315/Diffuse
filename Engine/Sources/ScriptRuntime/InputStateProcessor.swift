import EngineKernel
import SceneRuntime

/// Processes `InputFrameResource` events against the scene's `InputActionMap`
/// and writes a fresh `InputFrameState` resource before scripts run each frame.
///
/// Call `process(context:)` at the start of `ScriptRuntime.run(context:)`.
final class InputStateProcessor: @unchecked Sendable {
    // Scancodes / mouse buttons currently held across frames.
    private var heldKeys: Set<UInt32> = []
    private var heldMouseButtons: Set<MouseButton> = []

    func process(context: inout RuntimeScriptPhaseContext) {
        let frame = context.resource(InputFrameResource.self) ?? InputFrameResource()
        let map   = context.resource(InputActionMap.self) ?? InputActionMap()

        var keysJustPressed:   Set<UInt32>      = []
        var keysJustReleased:  Set<UInt32>      = []
        var buttonsJustPressed: Set<MouseButton> = []
        var buttonsJustReleased: Set<MouseButton> = []

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
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
