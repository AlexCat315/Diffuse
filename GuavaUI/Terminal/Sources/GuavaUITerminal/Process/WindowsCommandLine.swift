/// Windows process-launch encodings. Pure string work, kept outside the
/// ConPTY backend so it is tested on every platform.
enum WindowsCommandLine {
    /// Joins arguments the way `CommandLineToArgvW` splits them.
    static func commandLineString(_ arguments: [String]) -> String {
        arguments.map { argument -> String in
            guard argument.isEmpty || argument.contains(where: { " \t\n\u{0B}\"".contains($0) }) else { return argument }
            var quoted = "\""
            var backslashes = 0
            for character in argument {
                if character == "\\" { backslashes += 1; continue }
                if character == "\"" {
                    quoted += String(repeating: "\\", count: backslashes * 2 + 1) + "\""
                } else {
                    quoted += String(repeating: "\\", count: backslashes) + String(character)
                }
                backslashes = 0
            }
            return quoted + String(repeating: "\\", count: backslashes * 2) + "\""
        }.joined(separator: " ")
    }

    /// `NAME=value\0…\0\0`, sorted case-insensitively as Windows expects.
    static func environmentBlockUTF16(_ environment: [String: String]) -> [UInt16] {
        let entries = environment.sorted { $0.key.uppercased() < $1.key.uppercased() }
        var block: [UInt16] = []
        for (key, value) in entries { block += Array("\(key)=\(value)".utf16) + [0] }
        return block + [0]
    }
}
