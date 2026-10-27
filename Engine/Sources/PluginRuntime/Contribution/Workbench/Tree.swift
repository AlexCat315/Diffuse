import Foundation

/// One component of a plugin view. The host draws it in its own style; the
/// plugin only says what it is, what it holds and which action it raises.
public struct UINode: Sendable, Equatable {
    public enum Tone: String, Codable, Sendable { case normal, muted, accent, success, warning, danger }
    public enum Align: String, Codable, Sendable { case start, center, end, stretch }
    public enum TextStyle: String, Codable, Sendable { case body, caption, label, strong, mono, title }
    public enum ButtonStyle: String, Codable, Sendable { case primary, secondary, ghost, danger }
    public enum Background: String, Codable, Sendable { case canvas, surface, raised }

    public struct Stack: Sendable, Equatable {
        public var children: [UINode]
        public var spacing = 0
        public var padding = 0
        public var align = Align.stretch
    }

    public struct Text: Sendable, Equatable {
        public var text: String
        public var style = TextStyle.body
        public var tone = Tone.normal
    }

    public struct Button: Sendable, Equatable {
        public var title: String?
        public var icon: String?
        public var style = ButtonStyle.secondary
        public var action: String
        public var arguments: PluginJSON?
        public var disabled = false
        public var align = Align.center
    }

    public struct TextField: Sendable, Equatable {
        public var id: String
        public var placeholder: String?
        public var value: String?
        public var secure = false
        public var multiline = false
        /// Raised on Return.
        public var submit: String?
        /// Raised while typing, debounced by the host.
        public var change: String?
    }

    public struct Toggle: Sendable, Equatable {
        public var id: String
        public var label: String?
        public var value: Bool
        public var action: String?
    }

    public struct Select: Sendable, Equatable {
        public struct Option: Codable, Sendable, Equatable {
            public var value: String
            public var label: String
        }
        public var id: String
        public var options: [Option]
        public var value: String
        public var action: String?
    }

    public struct Disclosure: Sendable, Equatable {
        public var title: String
        public var expanded: Bool
        public var action: String
        public var arguments: PluginJSON?
        public var children: [UINode]
    }

    public struct Table: Sendable, Equatable {
        public struct Row: Sendable, Equatable {
            public var cells: [String]
            public var action: String?
            public var arguments: PluginJSON?
        }
        public var columns: [String]
        public var rows: [Row]
    }

    public indirect enum Kind: Sendable, Equatable {
        case column(Stack), row(Stack), scroll(UINode), section(title: String?, children: [UINode]), spacer
        case text(Text), badge(text: String, tone: Tone), icon(name: String, tone: Tone), progress(percent: Int?)
        case button(Button), textField(TextField), toggle(Toggle), select(Select)
        case disclosure(Disclosure), table(Table)
    }

    /// Keeps a component's identity, and its host-held state, across renders.
    public var key: String?
    public var flex: Int?
    public var width: Int?
    public var fillWidth: Bool?
    public var maxWidth: Int?
    public var minHeight: Int?
    public var background: Background?
    public var cornerRadius: Int?
    public var kind: Kind

    public init(_ kind: Kind, key: String? = nil, flex: Int? = nil) {
        self.kind = kind
        self.key = key
        self.flex = flex
    }

    public static let maximumNodes = 4_000
    public static let maximumDepth = 24
    public static let maximumText = 4 * 1_024
    public static let maximumInputBytes = 64 * 1_024
}

extension UINode: Decodable {
    private enum Keys: String, CodingKey {
        case type, key, flex, children, child, spacing, padding, align, title, text, style, tone, name, percent
        case icon, action, arguments, disabled, id, placeholder, value, secure, submit, change, label, options
        case expanded, columns, rows, cells, width, fillWidth, maxWidth, minHeight, background, cornerRadius, multiline
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        flex = try c.decodeIfPresent(Int.self, forKey: .flex)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        fillWidth = try c.decodeIfPresent(Bool.self, forKey: .fillWidth)
        maxWidth = try c.decodeIfPresent(Int.self, forKey: .maxWidth)
        minHeight = try c.decodeIfPresent(Int.self, forKey: .minHeight)
        background = try c.decodeIfPresent(Background.self, forKey: .background)
        cornerRadius = try c.decodeIfPresent(Int.self, forKey: .cornerRadius)
        func string(_ key: Keys) throws -> String { try c.decode(String.self, forKey: key) }
        func optional(_ key: Keys) throws -> String? { try c.decodeIfPresent(String.self, forKey: key) }
        func children() throws -> [UINode] { try c.decodeIfPresent([UINode].self, forKey: .children) ?? [] }
        func tone() throws -> Tone { try c.decodeIfPresent(Tone.self, forKey: .tone) ?? .normal }
        func stack() throws -> Stack {
            Stack(children: try children(), spacing: try c.decodeIfPresent(Int.self, forKey: .spacing) ?? 0,
                  padding: try c.decodeIfPresent(Int.self, forKey: .padding) ?? 0,
                  align: try c.decodeIfPresent(Align.self, forKey: .align) ?? .stretch)
        }
        switch try string(.type) {
        case "column": kind = .column(try stack())
        case "row": kind = .row(try stack())
        case "scroll": kind = .scroll(try c.decode(UINode.self, forKey: .child))
        case "section": kind = .section(title: try optional(.title), children: try children())
        case "spacer": kind = .spacer
        case "text":
            kind = .text(Text(text: try string(.text), style: try c.decodeIfPresent(TextStyle.self, forKey: .style) ?? .body,
                              tone: try tone()))
        case "badge": kind = .badge(text: try string(.text), tone: try tone())
        case "icon": kind = .icon(name: try string(.name), tone: try tone())
        case "progress": kind = .progress(percent: try c.decodeIfPresent(Int.self, forKey: .percent))
        case "button":
            kind = .button(Button(title: try optional(.title), icon: try optional(.icon),
                                  style: try c.decodeIfPresent(ButtonStyle.self, forKey: .style) ?? .secondary,
                                  action: try string(.action),
                                  arguments: try c.decodeIfPresent(PluginJSON.self, forKey: .arguments),
                                  disabled: try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false,
                                  align: try c.decodeIfPresent(Align.self, forKey: .align) ?? .center))
        case "textField":
            kind = .textField(TextField(id: try string(.id), placeholder: try optional(.placeholder),
                                        value: try optional(.value),
                                        secure: try c.decodeIfPresent(Bool.self, forKey: .secure) ?? false,
                                        multiline: try c.decodeIfPresent(Bool.self, forKey: .multiline) ?? false,
                                        submit: try optional(.submit), change: try optional(.change)))
        case "toggle":
            kind = .toggle(Toggle(id: try string(.id), label: try optional(.label),
                                  value: try c.decode(Bool.self, forKey: .value), action: try optional(.action)))
        case "select":
            kind = .select(Select(id: try string(.id), options: try c.decode([Select.Option].self, forKey: .options),
                                  value: try string(.value), action: try optional(.action)))
        case "disclosure":
            kind = .disclosure(Disclosure(title: try string(.title), expanded: try c.decode(Bool.self, forKey: .expanded),
                                          action: try string(.action),
                                          arguments: try c.decodeIfPresent(PluginJSON.self, forKey: .arguments),
                                          children: try children()))
        case "table":
            let rows = try c.decode([RowCoding].self, forKey: .rows)
            kind = .table(Table(columns: try c.decode([String].self, forKey: .columns),
                                rows: rows.map { Table.Row(cells: $0.cells, action: $0.action, arguments: $0.arguments) }))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown component")
        }
    }

    private struct RowCoding: Decodable {
        var cells: [String]
        var action: String?
        var arguments: PluginJSON?
    }
}

extension UINode {
    /// Whether the tree stays within the host's bounds and every name it uses is well formed.
    func isValid() -> Bool {
        var count = 0
        var ids = Set<String>()
        return validate(depth: 1, count: &count, ids: &ids)
    }

    private func validate(depth: Int, count: inout Int, ids: inout Set<String>) -> Bool {
        count += 1
        guard depth <= Self.maximumDepth, count <= Self.maximumNodes,
              key.map { Self.isText($0) } ?? true, flex.map({ (0...100).contains($0) }) ?? true,
              width.map({ (1...4096).contains($0) }) ?? true,
              minHeight.map({ (0...4096).contains($0) }) ?? true,
              cornerRadius.map({ (0...32).contains($0) }) ?? true,
              maxWidth.map({ (1...4096).contains($0) }) ?? true else { return false }
        func all(_ nodes: [UINode]) -> Bool {
            nodes.allSatisfy { $0.validate(depth: depth + 1, count: &count, ids: &ids) }
        }
        func claim(_ id: String) -> Bool { Self.isName(id) && ids.insert(id).inserted }
        switch kind {
        case let .column(stack), let .row(stack):
            return (0...32).contains(stack.spacing) && (0...32).contains(stack.padding) && all(stack.children)
        case let .scroll(child):
            return child.validate(depth: depth + 1, count: &count, ids: &ids)
        case let .section(title, children):
            return (title.map { Self.isText($0) } ?? true) && all(children)
        case .spacer:
            return true
        case let .text(text):
            return Self.isText(text.text, allowsEmpty: true)
        case let .badge(text, _):
            return Self.isText(text) && text.count <= 32
        case let .icon(name, _):
            return Self.isIcon(name)
        case let .progress(percent):
            return percent.map { (0...100).contains($0) } ?? true
        case let .button(button):
            return (button.title != nil || button.icon != nil) && (button.title.map { Self.isText($0) } ?? true)
                && (button.icon.map(Self.isIcon) ?? true) && Self.isName(button.action)
                && Self.isArguments(button.arguments)
        case let .textField(field):
            return claim(field.id) && (field.placeholder.map { Self.isText($0) } ?? true)
                && (field.value.map { $0.utf8.count <= Self.maximumInputBytes } ?? true)
                && (field.submit.map(Self.isName) ?? true) && (field.change.map(Self.isName) ?? true)
        case let .toggle(toggle):
            return claim(toggle.id) && (toggle.label.map { Self.isText($0) } ?? true) && (toggle.action.map(Self.isName) ?? true)
        case let .select(select):
            return claim(select.id) && !select.options.isEmpty && select.options.count <= 256
                && select.options.allSatisfy({ Self.isText($0.value) && Self.isText($0.label) })
                && select.options.contains { $0.value == select.value } && (select.action.map(Self.isName) ?? true)
        case let .disclosure(disclosure):
            return Self.isText(disclosure.title) && Self.isName(disclosure.action)
                && Self.isArguments(disclosure.arguments) && all(disclosure.children)
        case let .table(table):
            count += table.rows.count
            return !table.columns.isEmpty && table.columns.count <= 16 && table.columns.allSatisfy({ Self.isText($0) })
                && count <= Self.maximumNodes
                && table.rows.allSatisfy { row in
                    row.cells.count == table.columns.count && row.cells.allSatisfy { Self.isText($0, allowsEmpty: true) }
                        && (row.action.map(Self.isName) ?? true) && Self.isArguments(row.arguments)
                }
        }
    }

    static func isText(_ value: String, allowsEmpty: Bool = false) -> Bool {
        (allowsEmpty || !value.isEmpty) && value.utf8.count <= maximumText
    }

    /// Component IDs and action names.
    static func isName(_ value: String) -> Bool {
        value.range(of: #"^[a-z][a-zA-Z0-9_.-]{0,63}$"#, options: .regularExpression) != nil
    }

    static func isIcon(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9_-]{1,64}$"#, options: .regularExpression) != nil
    }

    static func isArguments(_ value: PluginJSON?) -> Bool {
        guard let value else { return true }
        guard case .object = value, let data = try? JSONEncoder().encode(value) else { return false }
        return data.count <= 4 * 1_024
    }
}
