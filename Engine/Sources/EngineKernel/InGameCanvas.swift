import Foundation

/// A simple RGBA color for in-game UI, using Float components in [0, 1].
public struct InGameUIColor: Sendable, Equatable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(r: Float, g: Float, b: Float, a: Float = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let white  = InGameUIColor(r: 1, g: 1, b: 1)
    public static let black  = InGameUIColor(r: 0, g: 0, b: 0)
    public static let red    = InGameUIColor(r: 1, g: 0, b: 0)
    public static let green  = InGameUIColor(r: 0, g: 0.8, b: 0)
    public static let blue   = InGameUIColor(r: 0, g: 0.4, b: 1)
    public static let yellow = InGameUIColor(r: 1, g: 0.9, b: 0)
    public static let clear  = InGameUIColor(r: 0, g: 0, b: 0, a: 0)
    public static func gray(_ brightness: Float, alpha: Float = 1) -> InGameUIColor {
        InGameUIColor(r: brightness, g: brightness, b: brightness, a: alpha)
    }
}

/// A single draw command emitted by a game script into the overlay canvas.
public enum InGameCanvasCommand: Sendable {
    case label(text: String, x: Float, y: Float, fontSize: Float, color: InGameUIColor)
    case rect(x: Float, y: Float, w: Float, h: Float, color: InGameUIColor, cornerRadius: Float)
    case progressBar(
        x: Float, y: Float, w: Float, h: Float,
        value: Float, maxValue: Float,
        fillColor: InGameUIColor, bgColor: InGameUIColor,
        cornerRadius: Float
    )
}

/// Per-frame immediate-mode 2D canvas for in-game UI.
///
/// Coordinates are in screen pixels (top-left origin).
/// Scripts accumulate draw commands each frame via `ctx.drawUI { ... }`;
/// the renderer consumes and clears this at the start of the next frame.
public struct InGameCanvas: Sendable {
    public var commands: [InGameCanvasCommand]

    public init() {
        commands = []
    }

    // MARK: - Drawing API

    public mutating func label(
        _ text: String,
        x: Float, y: Float,
        fontSize: Float = 16,
        color: InGameUIColor = .white
    ) {
        commands.append(.label(text: text, x: x, y: y, fontSize: fontSize, color: color))
    }

    public mutating func rect(
        x: Float, y: Float, w: Float, h: Float,
        color: InGameUIColor,
        cornerRadius: Float = 0
    ) {
        commands.append(.rect(x: x, y: y, w: w, h: h, color: color, cornerRadius: cornerRadius))
    }

    public mutating func progressBar(
        x: Float, y: Float, w: Float, h: Float,
        value: Float, maxValue: Float = 1,
        fillColor: InGameUIColor = InGameUIColor(r: 0.2, g: 0.8, b: 0.2),
        bgColor: InGameUIColor = InGameUIColor(r: 0.15, g: 0.15, b: 0.15, a: 0.85),
        cornerRadius: Float = 3
    ) {
        commands.append(.progressBar(
            x: x, y: y, w: w, h: h,
            value: value, maxValue: maxValue,
            fillColor: fillColor, bgColor: bgColor,
            cornerRadius: cornerRadius
        ))
    }
}
