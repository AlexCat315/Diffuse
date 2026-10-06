import Foundation

public struct InspectionInsets: Codable, Sendable {
    public var top, right, bottom, left: Double
    public init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top; self.right = right; self.bottom = bottom; self.left = left
    }
}
public struct NodeLayoutInfo: Codable, Sendable {
    public var padding, margin, border: InspectionInsets
    public var contentWidth, contentHeight: Double
    public var direction, flexDirection, justifyContent, alignItems: String
    public var flexGrow, flexShrink: Double
    public init(padding: InspectionInsets, margin: InspectionInsets, border: InspectionInsets,
                contentWidth: Double, contentHeight: Double, direction: String, flexDirection: String,
                justifyContent: String, alignItems: String, flexGrow: Double, flexShrink: Double) {
        self.padding = padding; self.margin = margin; self.border = border
        self.contentWidth = contentWidth; self.contentHeight = contentHeight
        self.direction = direction; self.flexDirection = flexDirection; self.justifyContent = justifyContent
        self.alignItems = alignItems; self.flexGrow = flexGrow; self.flexShrink = flexShrink
    }
}
public struct NodeStyleInfo: Codable, Sendable {
    public var backgroundColor, foregroundColor: String?
    public var overrides: [String]
    public init(backgroundColor: String?, foregroundColor: String?, overrides: [String]) {
        self.backgroundColor = backgroundColor; self.foregroundColor = foregroundColor; self.overrides = overrides
    }
}
public struct InspectionState: Codable, Sendable {
    public var selectedID, hoveredID: String?
    public var picking, canUndo, canRedo: Bool
    public var overrideCount: Int
    public init(selectedID: String?, hoveredID: String?, picking: Bool, canUndo: Bool, canRedo: Bool, overrideCount: Int) {
        self.selectedID = selectedID; self.hoveredID = hoveredID; self.picking = picking
        self.canUndo = canUndo; self.canRedo = canRedo; self.overrideCount = overrideCount
    }
}

public enum InspectionValidation {
    public static let commands: Set<String> = ["inspect.pick.start", "inspect.pick.stop", "inspect.hover", "inspect.pick",
        "inspect.style.set", "inspect.style.undo", "inspect.style.redo", "inspect.style.clear", "inspect.style.clearAll"]
    public static func validID(_ value: JSONValue?) -> Bool {
        guard let s = value?.stringValue else { return false }
        return !s.isEmpty && s.utf8.count <= 128
    }
    public static func validColor(_ value: JSONValue) -> Bool {
        guard let s = value.stringValue, s.first == "#", s.utf8.count == 7 || s.utf8.count == 9 else { return false }
        return s.utf8.dropFirst().allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    public static func number(_ value: JSONValue?) -> Double? {
        if case .number(let n) = value, n.isFinite { return n }
        return nil
    }
    public static func error(_ request: DevToolsEnvelope) -> String? {
        guard commands.contains(request.type) else { return "Unknown inspection command" }
        let p = request.payload?.objectValue
        switch request.type {
        case "inspect.hover", "inspect.pick":
            guard let p, Set(p.keys) == ["x", "y"],
                  let x = number(p["x"]), let y = number(p["y"]), abs(x) <= 1_000_000, abs(y) <= 1_000_000 else {
                return "Expected finite window coordinates x/y"
            }
        case "inspect.style.clear":
            guard let p, Set(p.keys) == ["id"], validID(p["id"]) else { return "Expected node id" }
        case "inspect.style.set":
            guard let p, Set(p.keys) == ["id", "properties"], validID(p["id"]),
                  let props = p["properties"]?.objectValue, !props.isEmpty,
                  Set(props.keys).isSubset(of: ["padding", "backgroundColor", "foregroundColor"]) else { return "Expected node id and supported properties" }
            for (key, value) in props {
                if case .null = value { continue }
                if key == "padding" {
                    guard let edges = value.objectValue, Set(edges.keys) == ["top", "right", "bottom", "left"],
                          edges.values.allSatisfy({ number($0).map { (0...4096).contains($0) } == true }) else {
                        return "Padding requires top/right/bottom/left in 0…4096 points"
                    }
                } else if !validColor(value) { return "Colors require #RRGGBB or #RRGGBBAA; null removes an override" }
            }
        default:
            if let payload = request.payload {
                if case .null = payload {} else if payload.objectValue?.isEmpty != true { return "This command takes no properties" }
            }
        }
        return nil
    }
}
