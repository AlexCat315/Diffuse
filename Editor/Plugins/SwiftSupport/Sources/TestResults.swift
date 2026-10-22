import GuavaPluginKit

/// Test identifiers are `Module.Suite/test` or, from the language server's
/// index, `Suite/test`; `--filter` matches either. XCTest reports `-[Module.Suite test]`; Swift
/// Testing reports a function (`test()`) or its display name in quotes, which
/// resolves against the known identifiers when only one fits.
enum TestResults {
    private struct Result {
        let id: String
        var status: String
        var message: String?
    }

    static func read(_ output: String, known: [String]) -> JSON {
        var results: [Result] = []
        func record(_ name: String, status: String?, message: String?) {
            guard let id = identifier(name, known: known) else { return }
            var index = results.firstIndex { $0.id == id }
            if index == nil { results.append(Result(id: id, status: "running")); index = results.count - 1 }
            if let status { results[index!].status = status }
            if let message, results[index!].message == nil { results[index!].message = message }
        }
        for line in lines(output) {
            let line = trimmed(line[...])
            if starts(line, with: "Test Case '") {
                let body = line.dropFirst(11)
                guard let close = index(of: UInt8(ascii: "'"), in: body) else { continue }
                let rest = body[(close + 1)...]
                let status: String? = starts(rest, with: " passed") ? "passed" : starts(rest, with: " failed") ? "failed"
                    : starts(rest, with: " skipped") ? "skipped" : nil
                record(xcTest(body[body.startIndex..<close]), status: status, message: nil)
                continue
            }
            for (marker, status) in [("✔ Test " as StaticString, "passed"), ("✘ Test ", "failed"), ("➜ Test ", "skipped"), ("◇ Test ", "running")]
            where starts(line, with: marker) {
                let (name, rest) = name(line.dropFirst(marker.utf8CodeUnitCount))
                if starts(rest, with: " recorded an issue") {
                    var message = rest
                    if let colon = colonSpace(in: rest) { message = rest[(colon + 2)...] }
                    record(name, status: nil, message: text(message))
                } else if starts(rest, with: " passed") || starts(rest, with: " failed") || starts(rest, with: " skipped")
                            || starts(rest, with: " started") {
                    record(name, status: status, message: nil)
                }
                break
            }
        }
        var tests: [JSON] = []
        for result in results where result.status != "running" {
            tests.append(["id": .string(result.id), "status": .string(result.status), "message": JSON(result.message)])
        }
        return .array(tests)
    }

    /// A quoted display name, or the first word.
    private static func name(_ body: ArraySlice<UInt8>) -> (String, ArraySlice<UInt8>) {
        if body.first == UInt8(ascii: "\""), let close = index(of: UInt8(ascii: "\""), in: body, from: body.startIndex + 1) {
            return (text(body[(body.startIndex + 1)..<close]), body[(close + 1)...])
        }
        let end = index(of: UInt8(ascii: " "), in: body) ?? body.endIndex
        return (text(body[body.startIndex..<end]), body[end...])
    }

    /// The `: ` after `recorded an issue at File.swift:12:5`.
    private static func colonSpace(in bytes: ArraySlice<UInt8>) -> Int? {
        var index = bytes.startIndex
        while index + 1 < bytes.endIndex {
            if bytes[index] == UInt8(ascii: ":"), bytes[index + 1] == 0x20 { return index }
            index += 1
        }
        return nil
    }

    /// `-[Module.Suite test]` on Darwin, `Suite.test` elsewhere.
    private static func xcTest(_ raw: ArraySlice<UInt8>) -> String {
        if starts(raw, with: "-["), raw.last == UInt8(ascii: "]") {
            let body = raw[(raw.startIndex + 2)..<(raw.endIndex - 1)]
            if let space = index(of: 0x20, in: body) {
                return text(body[body.startIndex..<space]) + "/" + text(body[(space + 1)...])
            }
        }
        var dot = raw.endIndex
        var index = raw.startIndex
        while index < raw.endIndex { if raw[index] == UInt8(ascii: ".") { dot = index }; index += 1 }
        guard dot < raw.endIndex else { return text(raw) }
        return text(raw[raw.startIndex..<dot]) + "/" + text(raw[(dot + 1)...])
    }

    /// The known identifier `name` stands for: itself; the one whose test part
    /// (or `Suite/test` part) it is; or the one `name` ends with, when the index
    /// names tests without their module. Unlisted identifiers stand for themselves.
    /// XCTest prints `test` for the method the index lists as `test()`.
    private static func identifier(_ name: String, known: [String]) -> String? {
        for candidate in [name, name + "()"] {
            if known.contains(candidate) { return candidate }
        }
        for candidate in [name, name + "()"] {
            var match: String?
            for id in known where hasSuffix(id, "/" + candidate) || hasSuffix(id, "." + candidate) || hasSuffix(candidate, "." + id) {
                if match != nil, match != id { return nil }
                match = id
            }
            if let match { return match }
        }
        let bytes = Array(name.utf8)[...]
        if let slash = index(of: UInt8(ascii: "/"), in: bytes), index(of: UInt8(ascii: "."), in: bytes[bytes.startIndex..<slash]) != nil {
            return name
        }
        return nil
    }

    private static func hasSuffix(_ text: String, _ suffix: String) -> Bool {
        let bytes = Array(text.utf8), tail = Array(suffix.utf8)
        guard bytes.count >= tail.count else { return false }
        return Array(bytes[(bytes.count - tail.count)...]) == tail
    }
}
