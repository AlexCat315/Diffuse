import Foundation

// MARK: - Sources

/// A script file paired with the text the editor currently holds — which may
/// be newer than what is on disk (unsaved edits).
public struct ScriptLanguageSource: Sendable {
    public let file: DynamicScriptManager.ScriptFile
    public let text: String

    public init(file: DynamicScriptManager.ScriptFile, text: String) {
        self.file = file
        self.text = text
    }
}

// MARK: - Diagnostics

public enum ScriptDiagnosticSeverity: Int, Sendable, Equatable {
    case error = 1
    case warning = 2
    case information = 3
    case hint = 4
}

public struct ScriptLanguageDiagnostic: Sendable, Equatable, Identifiable {
    public let severity: ScriptDiagnosticSeverity
    public let startLine: Int
    public let startCharacter: Int
    public let endLine: Int
    public let endCharacter: Int
    public let message: String
    public let code: String?

    public var id: String {
        "\(startLine):\(startCharacter):\(endLine):\(endCharacter):\(message)"
    }

    public var span: ScriptLanguageSpan {
        ScriptLanguageSpan(startLine: startLine,
                           startCharacter: startCharacter,
                           endLine: endLine,
                           endCharacter: endCharacter)
    }

    public init(severity: ScriptDiagnosticSeverity,
                startLine: Int,
                startCharacter: Int,
                endLine: Int,
                endCharacter: Int,
                message: String,
                code: String? = nil) {
        self.severity = severity
        self.startLine = startLine
        self.startCharacter = startCharacter
        self.endLine = endLine
        self.endCharacter = endCharacter
        self.message = message
        self.code = code
    }
}

public struct ScriptLanguageDiagnosticUpdate: Sendable {
    public let scriptID: String
    public let version: Int?
    public let diagnostics: [ScriptLanguageDiagnostic]

    public init(scriptID: String, version: Int?, diagnostics: [ScriptLanguageDiagnostic]) {
        self.scriptID = scriptID
        self.version = version
        self.diagnostics = diagnostics
    }
}

// MARK: - Hover

/// Result of `textDocument/hover`.
///
/// `contents` keeps the server's markup mostly intact — SourceKit answers with
/// Markdown declaration blocks — while ``plainText`` carries a stripped summary
/// for contexts that render with a single font.
public struct ScriptHoverResult: Sendable, Equatable {
    public let contents: String
    public let kind: ScriptMarkupKind
    public let plainText: String
    public let span: ScriptLanguageSpan?

    public init(contents: String,
                kind: ScriptMarkupKind,
                plainText: String,
                span: ScriptLanguageSpan?) {
        self.contents = contents
        self.kind = kind
        self.plainText = plainText
        self.span = span
    }

    public var isEmpty: Bool { plainText.isEmpty && contents.isEmpty }
}

public enum ScriptMarkupKind: String, Sendable, Equatable {
    case markdown
    case plaintext
}

// MARK: - Completion

/// LSP `CompletionItemKind`. Declared without `RawRepresentable` conformance
/// because every value outside the spec range must fold into ``unknown`` rather
/// than fail to decode — an unconstrained server is more common than a bug.
public enum ScriptCompletionItemKind: Sendable, Equatable {
    case text
    case method
    case function
    case constructor
    case field
    case variable
    case `class`
    case interface
    case module
    case property
    case unit
    case value
    case enumeration
    case keyword
    case snippet
    case color
    case file
    case reference
    case folder
    case enumMember
    case constant
    case `struct`
    case event
    case `operator`
    case typeParameter
    case unknown

    public init(rawValue: Int) {
        switch rawValue {
        case 1: self = .text
        case 2: self = .method
        case 3: self = .function
        case 4: self = .constructor
        case 5: self = .field
        case 6: self = .variable
        case 7: self = .`class`
        case 8: self = .interface
        case 9: self = .module
        case 10: self = .property
        case 11: self = .unit
        case 12: self = .value
        case 13: self = .enumeration
        case 14: self = .keyword
        case 15: self = .snippet
        case 16: self = .color
        case 17: self = .file
        case 18: self = .reference
        case 19: self = .folder
        case 20: self = .enumMember
        case 21: self = .constant
        case 22: self = .`struct`
        case 23: self = .event
        case 24: self = .`operator`
        case 25: self = .typeParameter
        default: self = .unknown
        }
    }

    public var rawValue: Int {
        switch self {
        case .unknown: 0
        case .text: 1
        case .method: 2
        case .function: 3
        case .constructor: 4
        case .field: 5
        case .variable: 6
        case .`class`: 7
        case .interface: 8
        case .module: 9
        case .property: 10
        case .unit: 11
        case .value: 12
        case .enumeration: 13
        case .keyword: 14
        case .snippet: 15
        case .color: 16
        case .file: 17
        case .reference: 18
        case .folder: 19
        case .enumMember: 20
        case .constant: 21
        case .`struct`: 22
        case .event: 23
        case .`operator`: 24
        case .typeParameter: 25
        }
    }
}

public struct ScriptCompletionItem: Sendable, Equatable, Identifiable {
    public let label: String
    public let kind: ScriptCompletionItemKind
    public let detail: String?
    public let documentation: String?
    /// Replacement text once snippet placeholders are expanded.
    public let insertText: String
    /// Characters that must be replaced ahead of the caret — SourceKit emits
    /// edits reaching back over the partially typed identifier.
    public let replaceStart: ScriptLanguagePosition?
    public let filterText: String?
    public let sortText: String?

    public var id: String { "\(label)-\(kind.rawValue)-\(insertText)" }

    public init(label: String,
                kind: ScriptCompletionItemKind,
                detail: String?,
                documentation: String?,
                insertText: String,
                replaceStart: ScriptLanguagePosition?,
                filterText: String?,
                sortText: String?) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
        self.insertText = insertText
        self.replaceStart = replaceStart
        self.filterText = filterText
        self.sortText = sortText
    }
}

public struct ScriptCompletionResult: Sendable, Equatable {
    public let items: [ScriptCompletionItem]
    /// True when the server truncated the list; the editor should re-query as
    /// the user narrows the prefix rather than treating this as final.
    public let isIncomplete: Bool

    public init(items: [ScriptCompletionItem], isIncomplete: Bool) {
        self.items = items
        self.isIncomplete = isIncomplete
    }

    public static let empty = ScriptCompletionResult(items: [], isIncomplete: false)
}

// MARK: - Definition

/// Result of `textDocument/definition`, already mapped back from the shadow
/// workspace onto the project's own script identifiers when the target falls
/// inside the current project.
public struct ScriptDefinitionLocation: Sendable, Equatable {
    public let documentURI: String
    /// Identifier of the owning script when the target is one of the project's
    /// scripts; `nil` for engine sources opened from outside the mapping.
    public let scriptID: String?
    public let span: ScriptLanguageSpan

    public init(documentURI: String, scriptID: String?, span: ScriptLanguageSpan) {
        self.documentURI = documentURI
        self.scriptID = scriptID
        self.span = span
    }
}

// MARK: - Availability

public enum ScriptLanguageSupportError: Error, LocalizedError, Sendable, Equatable {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(reason):
            return "Swift language support is unavailable: \(reason)"
        }
    }
}
