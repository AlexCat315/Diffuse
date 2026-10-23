import Foundation

/// Ordered regular-expression rules that colour a document. The host applies
/// them natively; a plugin cannot contribute colours, only these tokens.
public struct SyntaxGrammarContribution: Codable, Sendable, Equatable {
    public var rules: [SyntaxRuleContribution]

    public init(rules: [SyntaxRuleContribution]) {
        self.rules = rules
    }
}

public struct SyntaxRuleContribution: Codable, Sendable, Equatable {
    public var pattern: String
    public var token: String

    public init(pattern: String, token: String) {
        self.pattern = pattern
        self.token = token
    }
}

/// Ordered regular-expression rules that list a document's headings. The
/// first capture group is the title; the match start is the jump target.
public struct OutlineContribution: Codable, Sendable, Equatable {
    public var rules: [OutlineRuleContribution]

    public init(rules: [OutlineRuleContribution]) {
        self.rules = rules
    }
}

public struct OutlineRuleContribution: Codable, Sendable, Equatable {
    public var pattern: String
    public var level: Int

    public init(pattern: String, level: Int) {
        self.pattern = pattern
        self.level = level
    }
}

/// A capability that formats a whole document. The entry point takes
/// ``documentFormatInputType`` and returns the formatted text.
public struct FormatContribution: Codable, Sendable, Equatable {
    public var entryPoint: String

    public init(entryPoint: String) {
        self.entryPoint = entryPoint
    }
}

public enum SyntaxToken: String, CaseIterable, Sendable {
    case keyword, type, function, string, number, comment, attribute, directive
}

/// A language the editor edits: the files that are written in it and, when
/// the package runs one, its language server. The server is a process
/// permission of the package; its traffic flows through the permission's
/// entry point.
public struct LanguageContribution: Codable, Sendable, Equatable {
    /// The LSP language identifier, such as `swift`.
    public var id: String
    public var title: String
    /// File name extensions without the dot.
    public var extensions: [String]
    /// The icon key, when it differs from `id`; such as `text` for `plaintext`.
    public var icon: String?
    public var server: LanguageServerContribution?
    /// Declarative colouring rules the host runs natively.
    public var grammar: SyntaxGrammarContribution?
    /// Declarative heading rules the host runs natively.
    public var outline: OutlineContribution?
    /// The capability that formats this language's whole document.
    public var format: FormatContribution?

    public init(id: String, title: String, extensions: [String], icon: String? = nil,
                server: LanguageServerContribution? = nil,
                grammar: SyntaxGrammarContribution? = nil,
                outline: OutlineContribution? = nil,
                format: FormatContribution? = nil) {
        self.id = id
        self.title = title
        self.extensions = extensions
        self.icon = icon
        self.server = server
        self.grammar = grammar
        self.outline = outline
        self.format = format
    }
}

public struct LanguageServerContribution: Codable, Sendable, Equatable {
    /// The id of the process permission that starts the server.
    public var process: String
    /// Sent as `initializationOptions`; the editor may add host facts to it.
    public var initializationOptions: PluginJSON?
    /// Answers `workspace/configuration`, keyed by section.
    public var settings: PluginJSON?
    /// File names, beside the language's extensions, whose changes on disk the
    /// server is told about, such as a package manifest.
    public var watchedFiles: [String]?

    public init(process: String, initializationOptions: PluginJSON? = nil, settings: PluginJSON? = nil,
                watchedFiles: [String]? = nil) {
        self.process = process
        self.initializationOptions = initializationOptions
        self.settings = settings
        self.watchedFiles = watchedFiles
    }
}

