import GuavaUIRuntime

/// Syntax categories and the shared light/dark palette. Parsing lives in TreeSitterHighlighter.
enum SwiftSyntaxTokenKind: Equatable {
    case keyword
    case typeName
    case stringLiteral
    case comment
    case number
    case attribute
    case directive
    case functionName

    func color(light: Bool) -> Color {
        if light {
            return switch self {
            case .keyword: Color(red: 0x7B, green: 0x35, blue: 0xAE)
            case .typeName: Color(red: 0x00, green: 0x64, blue: 0x83)
            case .stringLiteral: Color(red: 0x2E, green: 0x70, blue: 0x3A)
            case .comment: Color(red: 0x67, green: 0x72, blue: 0x82)
            case .number: Color(red: 0xA5, green: 0x49, blue: 0x16)
            case .attribute, .directive: Color(red: 0x88, green: 0x60, blue: 0x15)
            case .functionName: Color(red: 0x22, green: 0x57, blue: 0xA0)
            }
        }
        return switch self {
        case .keyword: Color(r: 0.78, g: 0.62, b: 0.96)
        case .typeName: Color(r: 0.43, g: 0.78, b: 0.92)
        case .stringLiteral: Color(r: 0.67, g: 0.82, b: 0.57)
        case .comment: Color(r: 0.48, g: 0.54, b: 0.58)
        case .number: Color(r: 0.95, g: 0.70, b: 0.43)
        case .attribute, .directive: Color(r: 0.94, g: 0.77, b: 0.45)
        case .functionName: Color(r: 0.42, g: 0.77, b: 0.94)
        }
    }
}
