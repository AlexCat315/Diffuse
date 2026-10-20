import GuavaUIRuntime

/// How a completion's `insertText` is interpreted.
public enum TextInsertFormat: Sendable, Equatable {
    case plainText
    /// LSP snippet syntax: `$1`, `${1:placeholder}`, `${1|one,two|}` (the first
    /// choice is inserted) and `$0` for the final caret. `\$`, `\}` and `\\`
    /// escape. Variables such as `$TM_FILENAME` insert nothing.
    case snippet
}

/// Expanded snippet text and its tab stops in visiting order: `$1`, `$2`, …,
/// then `$0` (or the end of the insertion when `$0` is absent). Repeated
/// numbers visit only their first occurrence.
struct TextSnippet: Equatable {
    struct Stop: Equatable {
        let number: Int
        /// Character offsets inside `text`.
        let range: Range<Int>
    }
    let text: String
    let stops: [Stop]

    init(_ template: String) {
        var output = "", length = 0
        var found: [Int: Range<Int>] = [:]
        let characters = Array(template)
        var index = 0

        func append(_ string: String) { output += string; length += string.count }
        func readNumber() -> Int? {
            var digits = ""
            while index < characters.count, characters[index].isASCII, characters[index].isNumber {
                digits.append(characters[index]); index += 1
            }
            return Int(digits)
        }
        /// Placeholder text up to the matching `}`, honouring escapes and
        /// nested stops (whose own text is kept and recorded).
        func readPlaceholder() -> String {
            var text = ""
            while index < characters.count {
                let character = characters[index]
                if character == "\\", index + 1 < characters.count { text.append(characters[index + 1]); index += 2; continue }
                if character == "}" { index += 1; return text }
                if character == "$" {
                    let start = length + text.count
                    let saved = output, savedLength = length
                    output = ""; length = start
                    parseDollar()
                    text += output
                    output = saved; length = savedLength
                    continue
                }
                text.append(character); index += 1
            }
            return text
        }
        func record(_ number: Int, _ range: Range<Int>) { if found[number] == nil { found[number] = range } }
        func parseDollar() {
            index += 1 // `$`
            guard index < characters.count else { append("$"); return }
            if let number = readNumber() { record(number, length..<length); return }
            if characters[index] == "{" {
                index += 1
                if let number = readNumber() {
                    let start = length
                    if index < characters.count, characters[index] == ":" {
                        index += 1
                        let text = readPlaceholder()
                        append(text); record(number, start..<length)
                    } else if index < characters.count, characters[index] == "|" {
                        index += 1
                        var choice = "", first: String?
                        while index < characters.count, characters[index] != "|" {
                            if characters[index] == ",", first == nil { first = choice }
                            if characters[index] == "\\", index + 1 < characters.count { choice.append(characters[index + 1]); index += 2; continue }
                            choice.append(characters[index]); index += 1
                        }
                        index = min(characters.count, index + 2) // `|}`
                        append(first ?? choice); record(number, start..<length)
                    } else {
                        if index < characters.count, characters[index] == "}" { index += 1 }
                        record(number, start..<start)
                    }
                    return
                }
                // `${VARIABLE}` or `${VARIABLE:default}`: keep the default only.
                while index < characters.count, characters[index].isLetter || characters[index] == "_" { index += 1 }
                if index < characters.count, characters[index] == ":" { index += 1; append(readPlaceholder()) }
                else if index < characters.count, characters[index] == "}" { index += 1 }
                return
            }
            if characters[index].isLetter || characters[index] == "_" {
                while index < characters.count, characters[index].isLetter || characters[index] == "_" { index += 1 }
                return
            }
            append("$")
        }

        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, "$}\\".contains(characters[index + 1]) {
                append(String(characters[index + 1])); index += 2; continue
            }
            if character == "$" { parseDollar(); continue }
            append(String(character)); index += 1
        }
        let numbered = found.keys.filter { $0 > 0 }.sorted().map { Stop(number: $0, range: found[$0]!) }
        let final = Stop(number: 0, range: found[0] ?? (length..<length))
        text = output
        stops = numbered + [final]
    }
}

/// Active snippet tab stops in buffer character offsets. Edits inside the
/// current stop grow or shrink it and shift the later stops; any other edit,
/// Escape or leaving the final stop ends the session. Session-only state.
final class TextSnippetSession: NodeResource {
    private var stops: [Range<Int>] = []
    private var current = 0
    private var buffer: TextBuffer?

    var isActive: Bool { buffer != nil }
    func mount(node: Node) {}
    func unmount(node: Node) { end() }

    /// Starts after an insertion; returns the first stop to select.
    func start(_ snippet: TextSnippet, at offset: Int, in buffer: TextBuffer) -> Range<Int>? {
        stops = snippet.stops.map { ($0.range.lowerBound + offset)..<($0.range.upperBound + offset) }
        current = 0
        // A lone final stop is just a caret placement.
        guard stops.count > 1 else { let only = stops.first; end(); return only }
        self.buffer = buffer
        return stops[0]
    }

    func end() { stops = []; current = 0; buffer = nil }

    /// Tab moves forward, Shift+Tab back, Escape ends. Returns the stop to
    /// select, or `nil` when the key is not a snippet command.
    func command(for event: KeyEvent, buffer next: TextBuffer) -> Range<Int>?? {
        guard isActive, event.modifiers.isDisjoint(with: [.gui, .ctrl, .alt]) else { return nil }
        guard event.scancode == Scancode.tab || event.scancode == Scancode.escape else { return nil }
        guard synchronize(next) else { end(); return nil }
        if event.scancode == Scancode.escape { end(); return .some(nil) }
        if event.modifiers.contains(.shift) {
            current = max(0, current - 1)
        } else {
            current += 1
            if current >= stops.count - 1 {
                let final = stops.last
                end()
                return .some(final)
            }
        }
        return .some(stops[current])
    }

    private func synchronize(_ next: TextBuffer) -> Bool {
        guard let previous = buffer else { return false }
        defer { buffer = next }
        guard next != previous else { return true }
        guard let delta = next.editDelta(from: previous) else { return true }
        let stop = stops[current]
        guard delta.characterRange.lowerBound >= stop.lowerBound, delta.characterRange.upperBound <= stop.upperBound else { return false }
        let shift = delta.newText.count - delta.characterRange.count
        stops = stops.enumerated().map { index, range in
            if index == current { return range.lowerBound..<(range.upperBound + shift) }
            if range.lowerBound >= stop.upperBound { return (range.lowerBound + shift)..<(range.upperBound + shift) }
            return range
        }
        return true
    }
}
