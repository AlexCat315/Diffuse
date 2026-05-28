import EngineKernel

// MARK: - Scancode constants (SDL3)

public enum Scancode {
    // Letters
    public static let a: UInt32 = 4;  public static let b: UInt32 = 5
    public static let c: UInt32 = 6;  public static let d: UInt32 = 7
    public static let e: UInt32 = 8;  public static let f: UInt32 = 9
    public static let g: UInt32 = 10; public static let h: UInt32 = 11
    public static let i: UInt32 = 12; public static let j: UInt32 = 13
    public static let k: UInt32 = 14; public static let l: UInt32 = 15
    public static let m: UInt32 = 16; public static let n: UInt32 = 17
    public static let o: UInt32 = 18; public static let p: UInt32 = 19
    public static let q: UInt32 = 20; public static let r: UInt32 = 21
    public static let s: UInt32 = 22; public static let t: UInt32 = 23
    public static let u: UInt32 = 24; public static let v: UInt32 = 25
    public static let w: UInt32 = 26; public static let x: UInt32 = 27
    public static let y: UInt32 = 28; public static let z: UInt32 = 29

    // Numbers row
    public static let num1: UInt32 = 30; public static let num2: UInt32 = 31
    public static let num3: UInt32 = 32; public static let num4: UInt32 = 33
    public static let num5: UInt32 = 34; public static let num6: UInt32 = 35
    public static let num7: UInt32 = 36; public static let num8: UInt32 = 37
    public static let num9: UInt32 = 38; public static let num0: UInt32 = 39

    // Control
    public static let `return`: UInt32  = 40
    public static let escape: UInt32    = 41
    public static let backspace: UInt32 = 42
    public static let tab: UInt32       = 43
    public static let space: UInt32     = 44

    // Arrows
    public static let right: UInt32 = 79
    public static let left: UInt32  = 80
    public static let down: UInt32  = 81
    public static let up: UInt32    = 82

    // Modifiers
    public static let lctrl: UInt32  = 224
    public static let lshift: UInt32 = 225
    public static let lalt: UInt32   = 226
    public static let rctrl: UInt32  = 228
    public static let rshift: UInt32 = 229
    public static let ralt: UInt32   = 230

    // Function keys
    public static let f1: UInt32 = 58;  public static let f2: UInt32 = 59
    public static let f3: UInt32 = 60;  public static let f4: UInt32 = 61
    public static let f5: UInt32 = 62;  public static let f6: UInt32 = 63
    public static let f7: UInt32 = 64;  public static let f8: UInt32 = 65
    public static let f9: UInt32 = 66;  public static let f10: UInt32 = 67
    public static let f11: UInt32 = 68; public static let f12: UInt32 = 69
}

// MARK: - Input binding

/// One physical input that can contribute to an action.
public enum InputBinding: Sendable, Equatable {
    /// A keyboard key identified by SDL scancode.
    case key(UInt32)

    /// A mouse button.
    case mouseButton(MouseButton)

    /// A 1-D axis from two keys: negative key → -1.0, positive key → +1.0.
    case keyAxis(negative: UInt32, positive: UInt32)

    /// A gamepad button.
    case gamepadButton(GamepadButton)

    /// A gamepad axis (stick or trigger).
    case gamepadAxis(GamepadAxis)
}

// MARK: - InputActionMap resource

/// Maps logical action names to one or more physical `InputBinding`s.
///
/// Store this as a SceneRuntime resource. Bindings are evaluated each frame by
/// `InputStateProcessor` (inside ScriptRuntime) which writes `InputFrameState`.
///
/// ```swift
/// var map = InputActionMap()
/// map.bind("Jump",  to: .key(Scancode.space))
/// map.bind("MoveX", to: .keyAxis(negative: Scancode.a, positive: Scancode.d))
/// scene.setResource(map)
/// ```
public struct InputActionMap: Sendable {
    public var bindings: [String: [InputBinding]]

    public init(bindings: [String: [InputBinding]] = [:]) {
        self.bindings = bindings
    }

    public mutating func bind(_ action: String, to binding: InputBinding) {
        bindings[action, default: []].append(binding)
    }

    public mutating func unbind(_ action: String) {
        bindings.removeValue(forKey: action)
    }
}

// MARK: - InputFrameState resource

/// Per-frame input state derived from the current `InputActionMap`.
///
/// Written by `InputStateProcessor` each frame before scripts run.
/// Read via `ScriptContext.input`.
public struct InputFrameState: Sendable {
    /// Actions that are currently held down (pressed this frame or earlier).
    public var held: Set<String>
    /// Actions whose button was pressed **this frame** (leading edge).
    public var justPressed: Set<String>
    /// Actions whose button was released **this frame** (trailing edge).
    public var justReleased: Set<String>
    /// Axis values in -1…1 range for keyAxis bindings.
    public var axes: [String: Float]

    public init(
        held: Set<String> = [],
        justPressed: Set<String> = [],
        justReleased: Set<String> = [],
        axes: [String: Float] = [:]
    ) {
        self.held = held
        self.justPressed = justPressed
        self.justReleased = justReleased
        self.axes = axes
    }

    public func isHeld(_ action: String) -> Bool { held.contains(action) }
    public func isJustPressed(_ action: String) -> Bool { justPressed.contains(action) }
    public func isJustReleased(_ action: String) -> Bool { justReleased.contains(action) }
    public func axis(_ action: String) -> Float { axes[action] ?? 0 }
}
