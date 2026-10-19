import Foundation
import GuavaUI
import GuavaUIRuntime

/// A general multiline editor. The same `TextField` supports prose (soft wrap,
/// no chrome) and code (line numbers, diagnostics, completion) without
/// changing component.
private let textEditorSampleSource = "struct Greeting {\n    let name: String\n\n    func message() -> String {\n        return name\n    }\n}\n"

struct TextEditorStory: View {
    let options: GalleryOptions
    @State private var source: TextBuffer = TextBuffer(textEditorSampleSource)
    @State private var tokens = SwiftSyntax.tokens(in: textEditorSampleSource)
    @State private var syntaxRevision = 0
    @State private var history = TextEditHistory()
    @State private var navigationRequest = 0
    @State private var navigationIndex = 0
    @State private var showsDiagnostic = false
    @State private var codeMode = true
    @State private var caret = TextFieldCaretState.initial
    @State private var hover: TextFieldHoverAnchor?
    @State private var status = "Press Control-Space at the end of a line to request completion"
    @State private var breakpoints = [TextBreakpoint(line: 3)]
    @State private var foldRegions = [TextFoldRegion(lines: 0...6), TextFoldRegion(lines: 3...5)]
    @State private var bookmarked = true
    @State private var pausedPreview = false

    private var diagnostic: TextDiagnostic {
        let range = source.lineRange(forLine: 0)
        return TextDiagnostic(
            utf8Range: source.utf8Offset(forCharacterIndex: range.lowerBound)..<source.utf8Offset(forCharacterIndex: range.upperBound),
            severity: .warning, message: "Sample warning: this declaration is unused.")
    }

    var body: some View {
        StorySection(
            "Text editing",
            "A multiline editor for prose and code. Code mode adds line numbers, indentation, diagnostics and completion; plain mode soft-wraps and removes code chrome."
        ) {
            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 12) {
                Button("Go to beginning", isEnabled: options.isEnabled) { navigate(to: 0) }
                    .buttonStyle(.secondary)
                Button("Load 200,000 lines", isEnabled: options.isEnabled && codeMode) {
                    let loaded = TextBuffer((0..<200_000).map { "let value\($0) = \($0)" }.joined(separator: "\n"))
                    source = loaded
                    tokens = SwiftSyntax.tokens(in: loaded.stringValue)
                    syntaxRevision += 1
                    foldRegions = []; breakpoints = []
                    hover = nil; navigate(to: loaded.lineRange(forLine: 100_000).upperBound)
                    status = "200,000 lines · caret at line 100,001 · type, scroll, undo and redo"
                }.buttonStyle(.secondary)
                if codeMode {
                    Checkbox("Sample warning", isOn: $showsDiagnostic, isEnabled: options.isEnabled)
                    Checkbox("Paused line preview", isOn: $pausedPreview, isEnabled: options.isEnabled)
                }
                Box {}.flex(1)
            }

            ThemeReader { theme in
                SurfaceReader { surface in
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    documentHeader
                    ResizableEditor(initialHeight: 320, isResizable: options.isEnabled) {
                        editor(theme: theme, compact: surface.viewport.widthClass == .compact)
                    }
                    statusBar
                }
                .background(.surfaceSunken)
                .border(.border, width: 1)
                .cornerRadius(theme.radius.md)
                .clipped()
                }
            }

            Text(status).font(.caption).foregroundColor(.onSurfaceMuted)
            Text("F9 toggles a breakpoint · Primary-Alt-Left/Right folds or expands · gutter icons expose named actions · touch uses a line menu")
                .font(.caption).foregroundColor(.onSurfaceMuted)
            hoverTooltip
        }
    }

    private var documentHeader: some View {
        Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 8) {
            Icon(UIIcons.Editor.code, size: .small, color: .onSurfaceMuted)
            Text(codeMode ? "Greeting.swift" : "Notes.txt").truncated().font(.label)
                .flex(1, shrink: 1, basis: 0).frame(minWidth: 60)
            Box {}.flex(1)
            Checkbox("Code mode", isOn: $codeMode, isEnabled: options.isEnabled)
        }
        .padding(horizontal: 14, vertical: 8)
        .frame(minHeight: 40)
        .background(.surfaceRaised)
    }

    private var statusBar: some View {
        Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 12) {
            Text("Ln \(caretLine + 1), Col \(caretColumn)").font(.caption)
                .debugName("text-editor-caret")
            Box {}.flex(1)
            Text(codeMode ? "Spaces: 4" : "Soft wrap").font(.caption)
            Text("UTF-8").font(.caption)
            Text(codeMode ? "Swift" : "Plain text").font(.caption)
        }
        .foregroundColor(.onSurfaceMuted)
        .padding(horizontal: 14, vertical: 6)
        .frame(minHeight: 28)
        .background(.surfaceRaised)
    }

    private func editor(theme: Theme, compact: Bool) -> some View {
        TextField("", text: $source) { input in
            input.layout.axis = .vertical
            input.layout.wrapsLines = !codeMode || compact
            input.layout.maxVisibleLines = 24
            input.codeEditing.showsLineNumbers = codeMode
            input.codeEditing.gutter.breakpoints = $breakpoints
            input.codeEditing.gutter.markers = gutterMarkers
            input.codeEditing.gutter.executionLine = pausedPreview ? 4 : nil
            input.codeEditing.folding.regions = foldRegions
            input.codeEditing.indentationWidth = 4
            input.codeEditing.editHistory = history
            input.codeEditing.diagnostics = codeMode && showsDiagnostic ? TextDiagnostics([diagnostic]) : .empty
            input.codeEditing.syntaxRevision = syntaxRevision
            input.codeEditing.syntaxColorAtUTF8Offset = codeMode ? { _, offset in
                SwiftSyntax.color(at: offset, tokens: tokens, theme: theme)
            } : nil
            input.codeEditing.onRequestCompletion = codeMode ? { _, reply in
                var print = TextCompletionItem(id: "print", label: "print", insertText: "print(value)")
                print.detail = "Writes a value to standard output"
                var privateItem = TextCompletionItem(id: "private", label: "private", insertText: "private ")
                privateItem.detail = "Access control"
                let items = [print, privateItem]
                Task { @MainActor in reply(items) }
            } : nil
            input.codeEditing.onAcceptCompletion = { status = "Accepted \($0.label)" }
            input.behavior.disabled = !options.isEnabled
            input.events.onChange = { buffer in
                hover = nil
                tokens = SwiftSyntax.tokens(in: buffer.stringValue)
                foldRegions = SwiftSyntax.folds(in: buffer, tokens: tokens)
                syntaxRevision += 1
            }
            input.events.onCaretChange = { caret = $0 }
            input.events.onHoverChange = { hover = $0 }
            if navigationRequest > 0 {
                input.navigation.caretRequestID = navigationRequest
                input.navigation.caretRequestIndex = navigationIndex
            }
        }
        .font(codeMode ? .mono : .body)
        .font(codeMode ? .monospaced(size: 15) : theme.typography.body.font).lineHeight(codeMode ? 24 : 22)
        .textFieldStyle(.editor)
        .accessibilityLabel(codeMode ? "Swift source" : "Plain text document")
        .flex(1, shrink: 1)
        .frame(minHeight: 0)
        .debugName("gallery-text-editor")
    }

    private var hoverTooltip: AnyView {
        guard codeMode, showsDiagnostic, let hover,
              source.lineIndex(forCharacterIndex: hover.characterIndex) == 0 else { return AnyView(EmptyView()) }
        return AnyView(Tooltip(anchor: .point(CGPoint(x: CGFloat(hover.windowX), y: CGFloat(hover.windowY))), configure: { $0.maxWidth = 320 }) {
            Text(diagnostic.message).font(.caption).padding(10).background(.surfaceFloating).border(.border, width: 1).cornerRadius(6)
        })
    }

    private var caretLine: Int {
        source.lineIndex(forCharacterIndex: min(caret.caretIndex, source.characterCount))
    }

    private var gutterMarkers: [TextGutterMarker] {
        var result: [TextGutterMarker] = []
        if bookmarked, source.lineCount > 1 {
            result.append(TextGutterMarker("bookmark", line: 1, label: "Remove bookmark", icon: UIIcons.Status.bookmark) {
                bookmarked = false; status = "Bookmark removed"
            })
        }
        if let function = foldRegions.first(where: { $0.lines.lowerBound > 0 }) {
            result.append(TextGutterMarker("run", line: function.lines.lowerBound,
                label: "Preview Greeting.message", icon: UIIcons.Editor.play) {
                status = "Greeting.message preview: Hello, Guava"
            })
        }
        if showsDiagnostic {
            result.append(TextGutterMarker("warning", line: 0, label: diagnostic.message, icon: UIIcons.Status.alertTriangle) {
                status = diagnostic.message; navigate(to: 0)
            })
        }
        return result
    }

    private var caretColumn: Int {
        caret.caretIndex - source.lineRange(forLine: caretLine).lowerBound + 1
    }

    private func navigate(to index: Int) {
        navigationIndex = index
        navigationRequest += 1
    }
}

/// Small Swift lexer for the Gallery. Production Script editing uses
/// Tree-sitter and LSP; this demo keeps the same `syntaxColorAtUTF8Offset`
/// contract without pulling a parser into the component showcase.
private enum SwiftSyntax {
    enum Kind { case keyword, string, comment, number, type }

    struct Token {
        let range: Range<Int>
        let kind: Kind
    }

    static func folds(in buffer: TextBuffer, tokens: [Token]) -> [TextFoldRegion] {
        guard buffer.utf8Length <= 300_000 else { return [] }
        let bytes = Array(buffer.stringValue.utf8)
        var stack: [Int] = [], regions: [TextFoldRegion] = [], token = 0
        for offset in bytes.indices {
            while token < tokens.count && tokens[token].range.upperBound <= offset { token += 1 }
            if token < tokens.count, tokens[token].range.contains(offset),
               tokens[token].kind == .string || tokens[token].kind == .comment { continue }
            if bytes[offset] == 123 { stack.append(offset) }
            else if bytes[offset] == 125, let start = stack.popLast() {
                let first = buffer.lineIndex(forCharacterIndex: buffer.characterIndex(forUTF8Offset: start))
                let last = buffer.lineIndex(forCharacterIndex: buffer.characterIndex(forUTF8Offset: offset))
                if first < last { regions.append(TextFoldRegion(lines: first...last)) }
            }
        }
        return regions.sorted { $0.lines.lowerBound < $1.lines.lowerBound }
    }

    static let keywords: Set<String> = [
        "actor", "any", "as", "async", "await", "break", "case", "catch", "class",
        "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
        "fallthrough", "false", "fileprivate", "final", "for", "func", "guard", "if",
        "import", "in", "init", "inout", "internal", "is", "lazy", "let", "nil",
        "open", "operator", "override", "private", "protocol", "public", "repeat",
        "required", "return", "self", "Self", "some", "static", "struct", "switch",
        "throw", "throws", "true", "try", "typealias", "unowned", "var", "weak",
        "where", "while"
    ]

    static func tokens(in text: String) -> [Token] {
        let bytes = Array(text.utf8)
        // The 200k-line stress sample must not walk the whole document on
        // every edit; syntax colouring is intentionally a demo-scale feature.
        guard bytes.count <= 300_000 else { return [] }
        var result: [Token] = []
        var index = 0

        func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
        func isWordStart(_ byte: UInt8) -> Bool {
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95
        }
        func isWord(_ byte: UInt8) -> Bool { isWordStart(byte) || isDigit(byte) }
        func append(_ range: Range<Int>, _ kind: Kind) {
            if !range.isEmpty { result.append(Token(range: range, kind: kind)) }
        }

        while index < bytes.count {
            let byte = bytes[index]
            if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 47 {
                let start = index
                while index < bytes.count, bytes[index] != 10 { index += 1 }
                append(start..<index, .comment)
                continue
            }
            if byte == 34 {
                let start = index
                index += 1
                while index < bytes.count {
                    if bytes[index] == 92 {
                        index = min(bytes.count, index + 2)
                    } else if bytes[index] == 34 {
                        index += 1
                        break
                    } else {
                        index += 1
                    }
                }
                append(start..<index, .string)
                continue
            }
            if isDigit(byte) {
                let start = index
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
                append(start..<index, .number)
                continue
            }
            if isWordStart(byte) {
                let start = index
                while index < bytes.count, isWord(bytes[index]) { index += 1 }
                let word = String(decoding: bytes[start..<index], as: UTF8.self)
                if keywords.contains(word) {
                    append(start..<index, .keyword)
                } else if let first = bytes[start...].first, first >= 65, first <= 90 {
                    append(start..<index, .type)
                }
                continue
            }
            index += 1
        }
        return result
    }

    static func color(at offset: Int, tokens: [Token], theme: Theme) -> Color? {
        var low = 0, high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            let token = tokens[mid]
            if offset < token.range.lowerBound {
                high = mid
            } else if offset >= token.range.upperBound {
                low = mid + 1
            } else {
                let light = theme.colors.surfaceSunken.r > 0.5
                switch token.kind {
                case .keyword: return light ? Color(red: 0x86, green: 0x3D, blue: 0xA0) : Color(red: 0xC6, green: 0x91, blue: 0xDD)
                case .string: return light ? Color(red: 0x36, green: 0x73, blue: 0x3B) : Color(red: 0xA0, green: 0xC9, blue: 0x85)
                case .comment: return light ? Color(red: 0x6C, green: 0x75, blue: 0x80) : Color(red: 0x8B, green: 0x94, blue: 0xA1)
                case .number: return light ? Color(red: 0x9B, green: 0x64, blue: 0x20) : Color(red: 0xDC, green: 0xAC, blue: 0x77)
                case .type: return light ? Color(red: 0x2D, green: 0x73, blue: 0x9D) : Color(red: 0x78, green: 0xB9, blue: 0xE8)
                }
            }
        }
        return nil
    }
}
