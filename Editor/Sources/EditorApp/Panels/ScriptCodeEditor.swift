import GuavaUICompose
import GuavaUIRuntime

struct ScriptCodeEditor: View {
    let source: Binding<String>

    var body: some View {
        let highlighter = SwiftSyntaxHighlighter(source.wrappedValue)
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            TextField(
                "",
                text: source,
                axis: .vertical,
                maxVisibleLines: 48,
                showsLineNumbers: true,
                lineNumberColor: Color(r: 0.45, g: 0.49, b: 0.55),
                syntaxColorAtUTF8Offset: { _, offset in highlighter.color(atUTF8Offset: offset) },
                textColor: Color(r: 0.86, g: 0.89, b: 0.92)
            )
            .font(.mono)
            .frame(minHeight: 360, maxHeight: .infinity)
            .padding(horizontal: 8, vertical: 8)
            .background(Color(r: 0.105, g: 0.12, b: 0.145))
            .flex(1, shrink: 1)

            Divider()
            Row(alignment: .center, spacing: 12) {
                Text("Swift")
                Text("UTF-8")
                Text("\(lineCount) lines")
                Spacer(minLength: 0)
                Text("GameScript")
            }
            .font(.caption)
            .foregroundColor(.onSurfaceMuted)
            .padding(horizontal: 10, vertical: 5)
            .background(.surface)
        }
        .cornerRadius(4)
        .border(.divider, width: 1)
        .clipped()
    }

    private var lineCount: Int {
        max(1, source.wrappedValue.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        })
    }
}

enum SwiftSyntaxTokenKind: Equatable {
    case keyword
    case typeName
    case stringLiteral
    case comment
    case number
    case attribute
    case directive
    case functionName
}

struct SwiftSyntaxToken: Equatable {
    let range: Range<Int>
    let kind: SwiftSyntaxTokenKind
}

struct SwiftSyntaxHighlighter {
    private static let keywords: Set<String> = [
        "associatedtype", "async", "await", "as", "break", "case", "catch", "class",
        "continue", "convenience", "default", "defer", "deinit", "do", "else", "enum",
        "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard", "if",
        "import", "in", "indirect", "init", "inout", "internal", "is", "let", "mutating",
        "nil", "nonisolated", "open", "operator", "override", "private", "protocol", "public",
        "repeat", "required", "rethrows", "return", "self", "Self", "static", "struct",
        "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var",
        "where", "while"
    ]

    private static let directives: Set<String> = ["if", "else", "elseif", "endif", "available", "sourceLocation"]
    private let tokens: [SwiftSyntaxToken]

    init(_ source: String) {
        tokens = Self.tokenize(Array(source.utf8))
    }

    func color(atUTF8Offset offset: Int) -> Color? {
        var low = 0
        var high = tokens.count
        while low < high {
            let middle = (low + high) / 2
            let token = tokens[middle]
            if offset < token.range.lowerBound {
                high = middle
            } else if offset >= token.range.upperBound {
                low = middle + 1
            } else {
                return Self.color(for: token.kind)
            }
        }
        return nil
    }

    private static func tokenize(_ bytes: [UInt8]) -> [SwiftSyntaxToken] {
        var tokens: [SwiftSyntaxToken] = []
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if isWhitespace(byte) {
                index += 1
                continue
            }

            let start = index
            if byte == 47, peek(bytes, index + 1) == 47 {
                index += 2
                while index < bytes.count, bytes[index] != 10 { index += 1 }
                tokens.append(SwiftSyntaxToken(range: start..<index, kind: .comment))
                continue
            }
            if byte == 47, peek(bytes, index + 1) == 42 {
                index = consumeBlockComment(bytes, from: index)
                tokens.append(SwiftSyntaxToken(range: start..<index, kind: .comment))
                continue
            }
            if byte == 34 {
                index = consumeString(bytes, from: index)
                tokens.append(SwiftSyntaxToken(range: start..<index, kind: .stringLiteral))
                continue
            }
            if byte == 64 {
                index += 1
                index = consumeIdentifier(bytes, from: index)
                tokens.append(SwiftSyntaxToken(range: start..<index, kind: .attribute))
                continue
            }
            if byte == 35 {
                index += 1
                let wordStart = index
                index = consumeIdentifier(bytes, from: index)
                if wordStart < index {
                    let word = String(decoding: bytes[wordStart..<index], as: UTF8.self)
                    if directives.contains(word) {
                        tokens.append(SwiftSyntaxToken(range: start..<index, kind: .directive))
                    }
                }
                continue
            }
            if isDigit(byte) {
                index += 1
                while index < bytes.count,
                      isIdentifierContinuation(bytes[index]) || bytes[index] == 46 {
                    index += 1
                }
                tokens.append(SwiftSyntaxToken(range: start..<index, kind: .number))
                continue
            }
            if isIdentifierStart(byte) {
                index = consumeIdentifier(bytes, from: index)
                let word = String(decoding: bytes[start..<index], as: UTF8.self)
                if keywords.contains(word) {
                    tokens.append(SwiftSyntaxToken(range: start..<index, kind: .keyword))
                } else if startsUppercase(byte) {
                    tokens.append(SwiftSyntaxToken(range: start..<index, kind: .typeName))
                } else if nextNonWhitespaceByte(bytes, from: index) == 40 {
                    tokens.append(SwiftSyntaxToken(range: start..<index, kind: .functionName))
                }
                continue
            }
            index += 1
        }

        return tokens
    }

    private static func consumeString(_ bytes: [UInt8], from start: Int) -> Int {
        let multiline = peek(bytes, start + 1) == 34 && peek(bytes, start + 2) == 34
        var index = start + (multiline ? 3 : 1)
        while index < bytes.count {
            if bytes[index] == 92 {
                index = min(bytes.count, index + 2)
                continue
            }
            if bytes[index] == 34 {
                if !multiline { return index + 1 }
                if peek(bytes, index + 1) == 34 && peek(bytes, index + 2) == 34 {
                    return index + 3
                }
            }
            index += 1
        }
        return bytes.count
    }

    private static func consumeBlockComment(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start + 2
        var depth = 1
        while index + 1 < bytes.count, depth > 0 {
            if bytes[index] == 47, bytes[index + 1] == 42 {
                depth += 1
                index += 2
            } else if bytes[index] == 42, bytes[index + 1] == 47 {
                depth -= 1
                index += 2
            } else {
                index += 1
            }
        }
        return index
    }

    private static func consumeIdentifier(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count, isIdentifierContinuation(bytes[index]) { index += 1 }
        return index
    }

    private static func nextNonWhitespaceByte(_ bytes: [UInt8], from start: Int) -> UInt8? {
        var index = start
        while index < bytes.count, isWhitespace(bytes[index]) { index += 1 }
        return index < bytes.count ? bytes[index] : nil
    }

    private static func peek(_ bytes: [UInt8], _ index: Int) -> UInt8? {
        bytes.indices.contains(index) ? bytes[index] : nil
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    private static func isIdentifierStart(_ byte: UInt8) -> Bool {
        byte == 95 || (65...90).contains(byte) || (97...122).contains(byte) || byte >= 128
    }

    private static func isIdentifierContinuation(_ byte: UInt8) -> Bool {
        isIdentifierStart(byte) || isDigit(byte)
    }

    private static func startsUppercase(_ byte: UInt8) -> Bool {
        (65...90).contains(byte)
    }

    private static func color(for kind: SwiftSyntaxTokenKind) -> Color {
        switch kind {
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