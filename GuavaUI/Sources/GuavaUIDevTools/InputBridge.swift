import Foundation
import EngineKernel
import GuavaUIRuntime

/// Configuration sent by the client when it wants to start receiving mirror
/// frames. The server picks the actual size based on the host's logical
/// surface size; the client just declares whether it is ready to receive.
public struct MirrorStartPayload: Codable, Sendable {
    public var fps: Double?
    public var quality: Double?
}

public struct MirrorStoppedPayload: Codable, Sendable {
    public var reason: String
}

/// Mirror frame payload. The pixel buffer is base64-encoded JPEG; encoding
/// happens on the host so the client only has to decode once via
/// `createImageBitmap`.
public struct MirrorFramePayload: Codable, Sendable {
    public var seq: UInt64
    public var width: Int
    public var height: Int
    /// Logical (DIP) viewport width the host rendered against; lets clients
    /// map node-tree frames into mirror-canvas pixels.
    public var logicalWidth: Double
    public var logicalHeight: Double
    public var jpegBase64: String
}

// MARK: - Input bridge wire types

public struct MirrorInputPayload: Codable, Sendable {
    /// One of: pointerMove, pointerDown, pointerUp, wheel, keyDown, keyUp, text.
    public var kind: String
    public var x: Float?
    public var y: Float?
    public var deltaX: Float?
    public var deltaY: Float?
    public var button: Int?
    public var key: String?
    public var keyCode: Int?
    public var text: String?
    public var modifiers: Int?
    public var clickCount: Int?
    public var isRepeat: Bool?
}

/// Translates `MirrorInputPayload` into `InputEvent` and injects them into
/// the host's main `PlatformWindowSession`. Keyboard support maps common Web
/// `KeyboardEvent.code` values to SDL/USB-HID scancodes used by GuavaUI.
public enum InputBridge {

    public static func event(from payload: MirrorInputPayload) -> InputEvent? {
        switch payload.kind {
        case "pointerMove":
            return .mouseMotion(MouseMotionEvent(
                x: payload.x ?? 0,
                y: payload.y ?? 0,
                deltaX: payload.deltaX ?? 0,
                deltaY: payload.deltaY ?? 0
            ))
        case "pointerDown":
            return .mouseButtonDown(MouseButtonEvent(
                button: mouseButton(payload.button ?? 0),
                x: payload.x ?? 0,
                y: payload.y ?? 0,
                clicks: UInt8(min(255, max(1, payload.clickCount ?? 1))),
                modifiers: keyModifiers(payload.modifiers ?? 0)
            ))
        case "pointerUp":
            return .mouseButtonUp(MouseButtonEvent(
                button: mouseButton(payload.button ?? 0),
                x: payload.x ?? 0,
                y: payload.y ?? 0,
                clicks: UInt8(min(255, max(1, payload.clickCount ?? 1))),
                modifiers: keyModifiers(payload.modifiers ?? 0)
            ))
        case "wheel":
            return .mouseWheel(MouseWheelEvent(
                x: payload.deltaX ?? 0,
                y: payload.deltaY ?? 0,
                mouseX: payload.x,
                mouseY: payload.y
            ))
        case "text":
            guard let text = payload.text, !text.isEmpty else { return nil }
            return .textInput(text)
        case "keyDown":
            guard let scancode = keyScancode(from: payload.key) else { return nil }
            return .keyDown(KeyEvent(scancode: scancode,
                                     keycode: UInt32(max(0, payload.keyCode ?? 0)),
                                     modifiers: keyModifiers(payload.modifiers ?? 0),
                                     isRepeat: payload.isRepeat ?? false))
        case "keyUp":
            guard let scancode = keyScancode(from: payload.key) else { return nil }
            return .keyUp(KeyEvent(scancode: scancode,
                                   keycode: UInt32(max(0, payload.keyCode ?? 0)),
                                   modifiers: keyModifiers(payload.modifiers ?? 0),
                                   isRepeat: payload.isRepeat ?? false))
        default:
            return nil
        }
    }

    private static func mouseButton(_ raw: Int) -> MouseButton {
        // Web pointer buttons: 0 left, 1 middle, 2 right.
        switch raw {
        case 0: return .left
        case 1: return .middle
        case 2: return .right
        case 3: return .x1
        case 4: return .x2
        default: return .left
        }
    }

    private static func keyModifiers(_ raw: Int) -> KeyModifiers {
        var mods: KeyModifiers = []
        if raw & 1 != 0 { mods.insert(.shift) }
        if raw & 2 != 0 { mods.insert(.ctrl) }
        if raw & 4 != 0 { mods.insert(.alt) }
        if raw & 8 != 0 { mods.insert(.gui) }
        return mods
    }

    private static func keyScancode(from webCode: String?) -> UInt32? {
        guard let webCode, !webCode.isEmpty else { return nil }
        if webCode.count == 4,
           webCode.hasPrefix("Key"),
           let scalar = webCode.dropFirst(3).unicodeScalars.first,
           scalar.value >= 65,
           scalar.value <= 90 {
            return 4 + scalar.value - 65
        }
        if webCode.hasPrefix("Digit"),
           let value = UInt32(String(webCode.dropFirst(5))),
           value <= 9 {
            return value == 0 ? 39 : 29 + value
        }
        if webCode.hasPrefix("F"),
           let value = UInt32(String(webCode.dropFirst())),
           value >= 1,
           value <= 12 {
            return 57 + value
        }
        if webCode.hasPrefix("Numpad"),
           let value = UInt32(String(webCode.dropFirst(6))),
           value <= 9 {
            return value == 0 ? 98 : 88 + value
        }
        switch webCode {
        case "Enter", "NumpadEnter":
            return webCode == "NumpadEnter" ? 88 : 40
        case "Escape": return 41
        case "Backspace": return 42
        case "Tab": return 43
        case "Space": return 44
        case "Minus": return 45
        case "Equal": return 46
        case "BracketLeft": return 47
        case "BracketRight": return 48
        case "Backslash": return 49
        case "Semicolon": return 51
        case "Quote": return 52
        case "Backquote": return 53
        case "Comma": return 54
        case "Period": return 55
        case "Slash": return 56
        case "CapsLock": return 57
        case "PrintScreen": return 70
        case "ScrollLock": return 71
        case "Pause": return 72
        case "Insert": return 73
        case "Home": return 74
        case "PageUp": return 75
        case "Delete": return 76
        case "End": return 77
        case "PageDown": return 78
        case "ArrowRight": return 79
        case "ArrowLeft": return 80
        case "ArrowDown": return 81
        case "ArrowUp": return 82
        case "NumLock": return 83
        case "NumpadDivide": return 84
        case "NumpadMultiply": return 85
        case "NumpadSubtract": return 86
        case "NumpadAdd": return 87
        case "NumpadDecimal": return 99
        default: return nil
        }
    }
}
