import Foundation

/// What the user did in a plugin view, sent back to its entry point.
public struct UIEvent: Encodable, Sendable, Equatable {
    public var action: String
    public var arguments: PluginJSON?
    /// The new value of the component that raised the event, for fields, toggles and selects.
    public var value: PluginJSON?
    /// The current value of every field, toggle and select in the view, by component ID.
    public var values: [String: PluginJSON]

    public init(action: String, arguments: PluginJSON? = nil, value: PluginJSON? = nil,
                values: [String: PluginJSON] = [:]) {
        self.action = action
        self.arguments = arguments
        self.value = value
        self.values = values
    }
}

/// Something the host does for a plugin after a view event or a command.
public enum UIEffect: Sendable, Equatable {
    case message(String)
    case error(String)
    /// Brings forward one of the package's own panels.
    case panel(String)
    /// Opens a project-relative file in the editor.
    case open(path: String)
}

extension UIEffect: Decodable {
    private enum Keys: String, CodingKey { case type, text, id, path }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "message": self = .message(try c.decode(String.self, forKey: .text))
        case "error": self = .error(try c.decode(String.self, forKey: .text))
        case "panel": self = .panel(try c.decode(String.self, forKey: .id))
        case "open": self = .open(path: try c.decode(String.self, forKey: .path))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown effect")
        }
    }

    /// `panels` are the package's own panel identifiers.
    func isValid(panels: Set<String>) -> Bool {
        switch self {
        case let .message(text), let .error(text): UINode.isText(text)
        case let .panel(id): panels.contains(id)
        case let .open(path):
            !path.isEmpty && path.utf8.count <= 1_024 && !path.hasPrefix("/") && !path.contains("\\")
                && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty }
        }
    }
}

/// What a view entry point returns: the state to hand back next time, the
/// component tree to draw and the effects to carry out.
public struct PluginViewResult: Sendable, Equatable {
    /// Nil keeps the previous state.
    public var state: PluginJSON?
    public var ui: UINode
    public var effects: [UIEffect]

    public init(state: PluginJSON? = nil, ui: UINode, effects: [UIEffect] = []) {
        self.state = state
        self.ui = ui
        self.effects = effects
    }

    /// The largest serialized state, so it fits a string input when handed back.
    public static let maximumStateBytes = 48 * 1_024

    /// Reads the JSON object a view entry point returned. `panels` are the package's own panels.
    public init(json: Data, panels: Set<String>) throws {
        struct Coding: Decodable {
            var state: PluginJSON?
            var ui: UINode
            var effects: [UIEffect]?
        }
        guard json.count <= 1_024 * 1_024, let decoded = try? JSONDecoder().decode(Coding.self, from: json),
              decoded.ui.isValid(), (decoded.effects ?? []).count <= 16,
              (decoded.effects ?? []).allSatisfy({ $0.isValid(panels: panels) }),
              decoded.state.map({ ((try? JSONEncoder().encode($0))?.count ?? .max) <= Self.maximumStateBytes }) ?? true else {
            throw PluginWorkbenchResultError.invalidView
        }
        self.init(state: decoded.state, ui: decoded.ui, effects: decoded.effects ?? [])
    }
}

/// `record { view: string, state: string, event: string, context: string }`:
/// the view's ID, the state it last returned, the event as JSON (empty to
/// render only) and what the host knows about where it is shown.
let viewInputType = WITValueType.record([WITRecordField(name: "view", type: .string),
                                         WITRecordField(name: "state", type: .string),
                                         WITRecordField(name: "event", type: .string),
                                         WITRecordField(name: "context", type: .string)])
