internal import EditorCore
import CoveUIRuntime

/// Colours shared by every language the host highlights. Parsing lives in
/// TreeSitterHighlighter and DocumentGrammar.
enum SyntaxCategory: String, Equatable {
    case keyword
    case type
    case function
    case string
    case number
    case comment
    case attribute
    case directive

    func color(light: Bool, palette: [String: Color] = [:]) -> Color {
        if let color = palette[rawValue] { return color }
        if light {
            return switch self {
            case .keyword: Color(red: 0x7B, green: 0x35, blue: 0xAE)
            case .type: Color(red: 0x00, green: 0x64, blue: 0x83)
            case .string: Color(red: 0x2E, green: 0x70, blue: 0x3A)
            case .comment: Color(red: 0x67, green: 0x72, blue: 0x82)
            case .number: Color(red: 0xA5, green: 0x49, blue: 0x16)
            case .attribute, .directive: Color(red: 0x88, green: 0x60, blue: 0x15)
            case .function: Color(red: 0x22, green: 0x57, blue: 0xA0)
            }
        }
        return switch self {
        case .keyword: Color(r: 0.78, g: 0.62, b: 0.96)
        case .type: Color(r: 0.43, g: 0.78, b: 0.92)
        case .string: Color(r: 0.67, g: 0.82, b: 0.57)
        case .comment: Color(r: 0.48, g: 0.54, b: 0.58)
        case .number: Color(r: 0.95, g: 0.70, b: 0.43)
        case .attribute, .directive: Color(r: 0.94, g: 0.77, b: 0.45)
        case .function: Color(r: 0.42, g: 0.77, b: 0.94)
        }
    }
}

/// Syntax categories and their colors for tree-sitter tokens.
enum SwiftSyntaxTokenKind: Equatable {
    case keyword
    case typeName
    case stringLiteral
    case comment
    case number
    case attribute
    case directive
    case functionName

    var category: SyntaxCategory {
        switch self {
        case .keyword: .keyword
        case .typeName: .type
        case .stringLiteral: .string
        case .comment: .comment
        case .number: .number
        case .attribute: .attribute
        case .directive: .directive
        case .functionName: .function
        }
    }

    func color(light: Bool, palette: [String: Color] = [:]) -> Color { category.color(light: light, palette: palette) }
}

extension LanguageSyntaxRule.Token {
    var category: SyntaxCategory {
        switch self {
        case .keyword: .keyword
        case .type: .type
        case .function: .function
        case .string: .string
        case .number: .number
        case .comment: .comment
        case .attribute, .directive: .attribute
        }
    }
}
