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
/// the host's main `PlatformWindowSession`. v1 supports the most common
/// pointer + wheel + textual key path; full keyboard mapping is intentionally
/// limited because the wire format does not yet carry SDL3 scancodes.
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
                clicks: UInt8(min(255, max(1, payload.clickCount ?? 1)))
            ))
        case "pointerUp":
            return .mouseButtonUp(MouseButtonEvent(
                button: mouseButton(payload.button ?? 0),
                x: payload.x ?? 0,
                y: payload.y ?? 0,
                clicks: UInt8(min(255, max(1, payload.clickCount ?? 1)))
            ))
        case "wheel":
            return .mouseWheel(MouseWheelEvent(
                x: payload.deltaX ?? 0,
                y: payload.deltaY ?? 0
            ))
        case "text":
            guard let text = payload.text, !text.isEmpty else { return nil }
            return .textInput(text)
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
}
