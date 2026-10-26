import CovePluginKit

/// Compiler and linker messages: `path:line:column: error: message`.
enum Problems {
    static func read(_ output: String) -> JSON {
        var problems: [JSON] = [], seen: [String] = []
        for line in lines(output) {
            guard let problem = problem(line[...]) else { continue }
            let key = problem.key
            if seen.contains(key) { continue }
            seen.append(key)
            problems.append(problem.json)
        }
        return .array(problems)
    }

    private struct Problem {
        let file: String
        let line: Int
        let column: Int
        let severity: String
        let message: String

        var key: String { file + ":" + String(line) + ":" + String(column) + ":" + message }

        var json: JSON {
            ["file": .string(file), "line": JSON(line), "column": JSON(column),
             "severity": .string(severity), "message": .string(message)]
        }
    }

    private static func problem(_ line: ArraySlice<UInt8>) -> Problem? {
        let colon = UInt8(ascii: ":")
        guard let first = index(of: colon, in: line), first > line.startIndex,
              let second = index(of: colon, in: line, from: first + 1),
              let third = index(of: colon, in: line, from: second + 1),
              let fourth = index(of: colon, in: line, from: third + 1),
              let number = integer(line[(first + 1)..<second]), let column = integer(line[(second + 1)..<third]) else { return nil }
        let severity = trimmed(line[(third + 1)..<fourth])
        guard starts(severity, with: "error") && severity.count == 5 || starts(severity, with: "warning") && severity.count == 7
                || starts(severity, with: "note") && severity.count == 4 else { return nil }
        return Problem(file: text(line[line.startIndex..<first]), line: number, column: column,
                       severity: text(severity), message: text(trimmed(line[(fourth + 1)...])))
    }
}
