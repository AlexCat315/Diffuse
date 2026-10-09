import EngineCore
import GuavaUICompose
import GuavaUIRuntime

/// Persistent per-editor parser. No document String or flattened token list is
/// built during editing or painting; TSInput asks the Rope for bounded chunks.
final class TreeSitterHighlighter {
    private let parser = try? TreeSitterSwiftParser()
    private(set) var buffer: TextBuffer?
    private(set) var tree: SyntaxTree?
    private(set) var parseCount = 0
    private(set) var failure: Error?
    private var lastToken: (range: Range<Int>, kind: SwiftSyntaxTokenKind)?

    var statistics: SyntaxParseStatistics { parser?.statistics ?? SyntaxParseStatistics() }

    @discardableResult
    func synchronize(_ next: TextBuffer) -> Bool {
        guard buffer != next else { return failure == nil }
        guard let parser else { failure = SyntaxParserError.incompatibleGrammar; return false }
        let delta = buffer.flatMap { next.editDelta(from: $0) }
        if buffer != nil, delta == nil, tree != nil { buffer = next; return true }
        let edit = delta.flatMap { delta in buffer.map { previous in
            SyntaxEdit(oldByteRange: delta.startUTF8Offset..<delta.oldEndUTF8Offset,
                       newEndByte: delta.newEndUTF8Offset,
                       start: point(previous.parserPoint(forUTF8Offset: delta.startUTF8Offset)),
                       oldEnd: point(previous.parserPoint(forUTF8Offset: delta.oldEndUTF8Offset)),
                       newEnd: point(next.parserPoint(forUTF8Offset: delta.newEndUTF8Offset)))
        } }
        do {
            tree = try parser.parse(previous: tree, edit: edit) { offset, count in
                guard let chunk = next.chunk(atUTF8Offset: offset) else { return [] }
                return Array(chunk.bytes.prefix(count))
            }
            buffer = next; lastToken = nil; failure = nil; parseCount += 1
            return true
        } catch { failure = error; return false }
    }

    func kind(atUTF8Offset offset: Int) -> SwiftSyntaxTokenKind? {
        if let lastToken, lastToken.range.contains(offset) { return lastToken.kind }
        guard let tree else { return nil }
        let path = tree.path(atUTF8Offset: offset)
        guard let token = SwiftSyntaxTokenMap.classify(path) else { lastToken = nil; return nil }
        lastToken = token
        return token.kind
    }
    func color(atUTF8Offset offset: Int, light: Bool = false) -> Color? {
        kind(atUTF8Offset: offset)?.color(light: light)
    }
    private func point(_ point: TextBufferPoint) -> SyntaxPoint {
        SyntaxPoint(row: point.row, byteColumn: point.columnUTF8)
    }
}

/// Maps grammar nodes, with their fields and ancestry, to palette categories.
/// This never scans source bytes or guesses tokens from surrounding whitespace.
enum SwiftSyntaxTokenMap {
    private static let numbers: Set<String> = ["integer_literal", "hex_literal", "oct_literal", "bin_literal", "real_literal"]
    private static let strings: Set<String> = ["line_str_text", "multi_line_str_text", "raw_str_part", "raw_str_end_part", "str_escaped_char", "\"", "\"\"\""]
    private static let namedKeywords: Set<String> = ["visibility_modifier", "member_modifier", "function_modifier", "property_modifier", "parameter_modifier", "inheritance_modifier", "mutation_modifier", "ownership_modifier", "throws", "where_keyword", "getter_specifier", "setter_specifier", "modify_specifier", "else", "as_operator", "try_operator", "throw_keyword", "catch_keyword", "default_keyword", "self_expression", "super_expression", "boolean_literal"]
    private static let keywords: Set<String> = [
        "associatedtype", "actor", "async", "await", "as", "break", "case", "catch", "class", "consume", "copy",
        "continue", "convenience", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
        "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "indirect", "init", "inout", "internal",
        "is", "let", "mutating", "nil", "nonisolated", "open", "operator", "override", "private", "protocol", "public",
        "repeat", "required", "rethrows", "return", "self", "Self", "static", "struct", "subscript", "super", "switch",
        "throw", "throws", "true", "try", "typealias", "var", "where", "while", "some", "any", "weak", "unowned"
    ]
    static func classify(_ path: [SyntaxNodeInfo]) -> (range: Range<Int>, kind: SwiftSyntaxTokenKind)? {
        for index in path.indices.reversed() {
            let node = path[index]
            let ancestors = path.prefix(index)
            let kind: SwiftSyntaxTokenKind?
            switch node.type {
            case "comment", "multiline_comment": kind = .comment
            case "directive", "shebang_line": kind = .directive
            case "type_identifier":
                kind = ancestors.last?.type == "user_type" && ancestors.dropLast().last?.type == "attribute" ? .attribute : .typeName
            case "@": kind = .attribute
            case "simple_identifier":
                let parent = ancestors.last
                if node.fieldName == "name", parent?.type == "function_declaration" || parent?.type == "protocol_function_declaration" {
                    kind = .functionName
                } else if parent?.type == "call_expression" || parent?.type == "prefix_expression" && ancestors.dropLast().last?.type == "call_expression" {
                    kind = .functionName
                } else if parent?.type == "navigation_suffix", ancestors.contains(where: { $0.type == "call_expression" }),
                          !ancestors.contains(where: { $0.type == "call_suffix" }) {
                    kind = .functionName
                } else { kind = nil }
            default:
                if numbers.contains(node.type) { kind = .number }
                else if strings.contains(node.type) { kind = .stringLiteral }
                else if namedKeywords.contains(node.type) || !node.isNamed && keywords.contains(node.type) { kind = .keyword }
                else { kind = nil }
            }
            if let kind { return (node.byteRange, kind) }
        }
        return nil
    }
}
