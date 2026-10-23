@testable import EditorUI
import EditorCore
import Testing

@Suite("Document syntax")
struct DocumentSyntaxTests {
    @Test("LaTeX rules run in order and keep earlier claims")
    func latexTokens() throws {
        let grammar = try #require(DocumentGrammar(rules: [
            LanguageSyntaxRule(pattern: #"%.*$"#, token: .comment),
            LanguageSyntaxRule(pattern: #"\\begin\{(?:verbatim|lstlisting|minted)\}[\s\S]*?\\end\{(?:verbatim|lstlisting|minted)\}"#,
                               token: .string),
            LanguageSyntaxRule(pattern: #"\$\$[\s\S]*?\$\$"#, token: .string),
            LanguageSyntaxRule(pattern: #"\$[^$\n]*\$"#, token: .string),
            LanguageSyntaxRule(pattern: #"\\(?:chapter|section|subsection|paragraph|title|begin|end)\*?"#,
                               token: .keyword),
            LanguageSyntaxRule(pattern: #"\\[A-Za-z@]+\*?"#, token: .function),
            LanguageSyntaxRule(pattern: #"\b\d+(?:\.\d+)?\b"#, token: .number),
        ]))
        let text = """
        % \\section{hidden}
        \\section{Intro}
        Value $x$ is 42.
        """
        let tokens = grammar.tokens(in: text)

        #expect(token(at: "%", in: text, tokens: tokens) == .comment)
        #expect(token(at: "\\section{hidden}", in: text, tokens: tokens) == .comment)
        #expect(token(at: "\\section{Intro}", in: text, tokens: tokens) == .keyword)
        #expect(token(at: "$x$", in: text, tokens: tokens) == .string)
        #expect(token(at: "42", in: text, tokens: tokens) == .number)
        #expect(token(at: "Value", in: text, tokens: tokens) == nil)
    }

    @Test("Offsets stay in UTF-8 after multi-byte text")
    func utf8Offsets() throws {
        let grammar = try #require(DocumentGrammar(rules: [
            LanguageSyntaxRule(pattern: #"%.*$"#, token: .comment),
        ]))
        let text = "😀 % note\nplain"
        let tokens = grammar.tokens(in: text)
        let comment = try #require(tokens.first)
        #expect(comment.token == .comment)
        #expect(comment.range == utf8Range(of: "% note", in: text))
    }

    @Test("No rules or an invalid rule produces no grammar")
    func unavailableGrammar() {
        #expect(DocumentGrammar(rules: []) == nil)
        #expect(DocumentGrammar(rules: [LanguageSyntaxRule(pattern: "(", token: .comment)]) == nil)
    }

    private func token(at needle: String,
                       in text: String,
                       tokens: [(range: Range<Int>, token: LanguageSyntaxRule.Token)])
    -> LanguageSyntaxRule.Token? {
        guard let offset = utf8Range(of: needle, in: text)?.lowerBound else { return nil }
        return tokens.first { $0.range.contains(offset) }?.token
    }

    private func utf8Range(of needle: String, in text: String) -> Range<Int>? {
        guard let range = text.range(of: needle),
              let lower = range.lowerBound.samePosition(in: text.utf8),
              let upper = range.upperBound.samePosition(in: text.utf8) else { return nil }
        return text.utf8.distance(from: text.utf8.startIndex, to: lower)
            ..< text.utf8.distance(from: text.utf8.startIndex, to: upper)
    }
}
