// The painter's output: a flat, ordered list of backend-agnostic draw commands
// in paint order (back-to-front). A renderer (wgpu, software, a test) walks this
// list — the core never touches a GPU type. All rects are in absolute (window)
// coordinates so the backend needs no transform stack of its own.

public enum DrawCommand: Equatable, Sendable {
    case fillRect(Rect, Color)
    case fillRoundedRect(Rect, Color, radius: Float)
    case strokeRect(Rect, Color, width: Float)
    case text(String, Rect, Color, size: Float, lineLimit: Int?)
    /// Restrict subsequent drawing to `rect` until the matching `popClip`.
    case pushClip(Rect)
    case popClip
}

public struct DisplayList: Equatable, Sendable {
    public private(set) var commands: [DrawCommand] = []
    public init() {}

    mutating func fill(_ rect: Rect, _ color: Color) { commands.append(.fillRect(rect, color)) }
    mutating func fillRounded(_ rect: Rect, _ color: Color, radius: Float) {
        commands.append(.fillRoundedRect(rect, color, radius: radius))
    }
    mutating func stroke(_ rect: Rect, _ color: Color, width: Float) {
        commands.append(.strokeRect(rect, color, width: width))
    }
    mutating func text(_ string: String, _ rect: Rect, _ color: Color, size: Float, lineLimit: Int? = nil) {
        commands.append(.text(string, rect, color, size: size, lineLimit: lineLimit))
    }
    mutating func pushClip(_ rect: Rect) { commands.append(.pushClip(rect)) }
    mutating func popClip() { commands.append(.popClip) }

    public var count: Int { commands.count }
}
