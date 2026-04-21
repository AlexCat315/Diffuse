import Foundation

// MARK: - Keyboard

public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let lshift = KeyModifiers(rawValue: 1 << 0)
    public static let rshift = KeyModifiers(rawValue: 1 << 1)
    public static let lctrl  = KeyModifiers(rawValue: 1 << 2)
    public static let rctrl  = KeyModifiers(rawValue: 1 << 3)
    public static let lalt   = KeyModifiers(rawValue: 1 << 4)
    public static let ralt   = KeyModifiers(rawValue: 1 << 5)
    public static let lgui   = KeyModifiers(rawValue: 1 << 6)
    public static let rgui   = KeyModifiers(rawValue: 1 << 7)

    public static let shift: KeyModifiers = [.lshift, .rshift]
    public static let ctrl:  KeyModifiers = [.lctrl, .rctrl]
    public static let alt:   KeyModifiers = [.lalt, .ralt]
    public static let gui:   KeyModifiers = [.lgui, .rgui]
}

public struct KeyEvent: Sendable {
    public var scancode: UInt32
    public var keycode: UInt32
    public var modifiers: KeyModifiers
    public var isRepeat: Bool

    public init(scancode: UInt32, keycode: UInt32, modifiers: KeyModifiers, isRepeat: Bool) {
        self.scancode = scancode
        self.keycode = keycode
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }
}

public struct TextEditingEvent: Sendable, Equatable {
    public var text: String
    public var start: Int32
    public var length: Int32

    public init(text: String, start: Int32, length: Int32) {
        self.text = text
        self.start = start
        self.length = length
    }
}

public struct TextInputArea: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float
    public var cursorX: Float

    public init(x: Float, y: Float, width: Float, height: Float, cursorX: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.cursorX = cursorX
    }
}

// MARK: - Mouse

public enum MouseButton: UInt8, Sendable, Hashable {
    case left   = 1
    case middle = 2
    case right  = 3
    case x1     = 4
    case x2     = 5
}

public struct MouseMotionEvent: Sendable {
    public var x: Float
    public var y: Float
    public var deltaX: Float
    public var deltaY: Float

    public init(x: Float, y: Float, deltaX: Float, deltaY: Float) {
        self.x = x; self.y = y; self.deltaX = deltaX; self.deltaY = deltaY
    }
}

public struct MouseButtonEvent: Sendable {
    public var button: MouseButton
    public var x: Float
    public var y: Float
    public var clicks: UInt8

    public init(button: MouseButton, x: Float, y: Float, clicks: UInt8) {
        self.button = button; self.x = x; self.y = y; self.clicks = clicks
    }
}

public struct MouseWheelEvent: Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x; self.y = y
    }
}

// MARK: - Input Event

public enum InputEvent: Sendable {
    case keyDown(KeyEvent)
    case keyUp(KeyEvent)

    /// IME / OS-composed text. The string is decoded UTF-8 from SDL3 and may
    /// contain multiple grapheme clusters per event (e.g. dead-key composed
    /// accents or pasted text).
    case textInput(String)

    /// Active IME preedit text and its selection range within the composition.
    case textEditing(TextEditingEvent)

    case mouseMotion(MouseMotionEvent)
    case mouseButtonDown(MouseButtonEvent)
    case mouseButtonUp(MouseButtonEvent)
    case mouseWheel(MouseWheelEvent)

    case windowFocusGained
    case windowFocusLost
    case windowMinimized
    case windowRestored
    case windowOccluded
    case windowExposed
    case windowResized(width: Int32, height: Int32)
    case windowPixelSizeChanged(width: Int32, height: Int32)
}
