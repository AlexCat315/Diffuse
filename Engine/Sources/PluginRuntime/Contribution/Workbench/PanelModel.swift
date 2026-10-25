import Foundation

/// What a panel entry point returns: sections of rows and a few actions, which
/// the host renders in its own style. Rows and actions run the package's own
/// commands; the panel describes itself again after each one.
public struct PanelModel: Codable, Sendable, Equatable {
    public enum Tone: String, Codable, Sendable {
        case normal, muted, accent, success, warning, danger
    }

    /// A button in the panel's toolbar.
    public struct Action: Codable, Sendable, Equatable {
        public var title: String
        public var command: String
        public var arguments: PluginJSON?

        public init(title: String, command: String, arguments: PluginJSON? = nil) {
            self.title = title
            self.command = command
            self.arguments = arguments
        }
    }

    /// One line. With a command, clicking it runs that command.
    public struct Item: Codable, Sendable, Equatable {
        public var title: String
        public var detail: String?
        public var badge: String?
        public var tone: Tone?
        public var command: String?
        public var arguments: PluginJSON?

        public init(title: String, detail: String? = nil, badge: String? = nil, tone: Tone? = nil,
                    command: String? = nil, arguments: PluginJSON? = nil) {
            self.title = title
            self.detail = detail
            self.badge = badge
            self.tone = tone
            self.command = command
            self.arguments = arguments
        }
    }

    public struct Section: Codable, Sendable, Equatable {
        public var title: String?
        public var items: [Item]

        public init(title: String? = nil, items: [Item]) {
            self.title = title
            self.items = items
        }
    }

    public var sections: [Section] = []
    public var actions: [Action] = []
    /// Shown when no section has a row.
    public var empty: String?

    public init(sections: [Section] = [], actions: [Action] = [], empty: String? = nil) {
        self.sections = sections
        self.actions = actions
        self.empty = empty
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sections = try values.decodeIfPresent([Section].self, forKey: .sections) ?? sections
        actions = try values.decodeIfPresent([Action].self, forKey: .actions) ?? actions
        empty = try values.decodeIfPresent(String.self, forKey: .empty)
    }

    /// Reads the JSON text a panel entry point returned. Every command a row or
    /// action names must be one of `commands`, the package's own.
    public init(json: String, commands: Set<String>) throws {
        guard json.utf8.count <= Self.maximumBytes,
              let model = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)),
              model.isValid(commands: commands) else {
            throw PluginWorkbenchResultError.invalidPanel
        }
        self = model
    }

    static let maximumBytes = 512 * 1_024

    private func isValid(commands: Set<String>) -> Bool {
        func trigger(_ command: String?, _ arguments: PluginJSON?) -> Bool {
            guard let command else { return arguments == nil }
            guard commands.contains(command) else { return false }
            guard let arguments else { return true }
            guard case .object = arguments, let data = try? JSONEncoder().encode(arguments) else { return false }
            return data.count <= 4 * 1_024
        }
        guard sections.count <= 32, actions.count <= 8,
              sections.reduce(0, { $0 + $1.items.count }) <= 2_000,
              empty.map(Self.isText) ?? true else { return false }
        return actions.allSatisfy { ContributionValidation.title($0.title) && trigger($0.command, $0.arguments) }
            && sections.allSatisfy { section in
                section.title.map(Self.isText) ?? true && section.items.allSatisfy { item in
                    Self.isText(item.title) && item.detail.map(Self.isText) ?? true
                        && item.badge.map({ !$0.isEmpty && $0.count <= 16 }) ?? true
                        && trigger(item.command, item.arguments)
                }
            }
    }

    static func isText(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 512
    }
}
