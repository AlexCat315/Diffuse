import Foundation

enum Files {
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func remove(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    static func reset(_ url: URL) throws { try remove(url); try directory(url) }

    static func copy(_ source: URL, to destination: URL) throws {
        try directory(destination.deletingLastPathComponent())
        try remove(destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    static func text(_ value: String, to url: URL) throws {
        try directory(url.deletingLastPathComponent())
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    static func json<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try directory(url.deletingLastPathComponent())
        var data = try encoder.encode(value)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    static func children(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
    }

    static func files(_ url: URL) throws -> [URL] {
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
            errorHandler: { _, error in failure = error; return false }) else {
            throw ToolError.invalid("Cannot read \(url.path)")
        }
        var result: [URL] = []
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { result.append(file) }
        }
        if let failure { throw failure }
        return result.sorted { $0.path < $1.path }
    }

    static func relative(_ file: URL, to root: URL) -> String {
        let components = file.standardizedFileURL.pathComponents
        let base = root.standardizedFileURL.pathComponents
        var common = 0
        while common < min(components.count, base.count), components[common] == base[common] { common += 1 }
        return (Array(repeating: "..", count: base.count - common) + Array(components.dropFirst(common))).joined(separator: "/")
    }

    static func swiftLiteral(_ value: String) -> String {
        // Swift accepts JSON's usual escapes but uses \u{...} for control scalars.
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 0...31, 127: result += "\\u{\(String(scalar.value, radix: 16))}"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
